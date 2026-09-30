#!/bin/sh
set -e

cd /app

DB_PATH="${DB_PATH:-/app/data/backend.db}"
APP_CONFIG_PATH="/run/grok2api/config.yaml"
LITESTREAM_CONFIG_PATH="/tmp/litestream.yml"

mkdir -p /run/grok2api /app/data /tmp
mkdir -p "$(dirname "$DB_PATH")"
touch "$DB_PATH"

# -------------------------------------------------------------
# 1. 生成严格遵循官方规范的 config.yaml
# -------------------------------------------------------------
if [ -n "$CONFIG_CONTENT" ]; then
    echo "$CONFIG_CONTENT" > "$APP_CONFIG_PATH"
elif [ ! -f "$APP_CONFIG_PATH" ]; then
    echo "正在生成符合官方规范的 config.yaml..."
    
    JWT_SECRET=$(head -c 32 /dev/urandom | hexxdump -e '16/1 "%02x"' 2>/dev/null || echo "default-jwt-secret-key-32bytes-long-sec!")
    ENCRYPT_KEY=$(head -c 32 /dev/urandom | base64 2>/dev/null || echo "default-encryption-key-base64-random==")

    cat <<EOF > "$APP_CONFIG_PATH"
server:
  host: "0.0.0.0"
  port: 8000

secrets:
  jwtSecret: "${JWT_SECRET}"
  credentialEncryptionKey: "${ENCRYPT_KEY}"

bootstrapAdmin:
  username: "admin"
  password: "admin_password123"

database:
  type: "sqlite"
  sqlite:
    path: "${DB_PATH}"
EOF
    echo "配置文件生成成功！"
fi

# -------------------------------------------------------------
# 2. 生成 Litestream 配置
# -------------------------------------------------------------
cat <<EOF > "$LITESTREAM_CONFIG_PATH"
dbs:
  - path: "${DB_PATH}"
    replicas:
      - type: s3
        url: "${LITESTREAM_REPLICA_URL}"
        endpoint: "${AWS_ENDPOINT_URL}"
EOF

# -------------------------------------------------------------
# 3. 从 Backblaze B2 还原数据库
# -------------------------------------------------------------
litestream restore -if-replica-exists -config "$LITESTREAM_CONFIG_PATH" "$DB_PATH" || true

# -------------------------------------------------------------
# 4. 启动后台备份 & 启动主程序
# -------------------------------------------------------------
litestream replicate -config "$LITESTREAM_CONFIG_PATH" &

exec /usr/local/bin/grok2api-entrypoint /app/grok2api --config "$APP_CONFIG_PATH"
