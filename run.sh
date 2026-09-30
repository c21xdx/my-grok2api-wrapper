#!/bin/sh
set -e

# 1. 设置路径与工作目录
cd /app
DB_PATH="${DB_PATH:-/app/data/backend.db}"
APP_CONFIG_PATH="/run/grok2api/config.yaml"
LITESTREAM_CONFIG_PATH="/tmp/litestream.yml"

# 确保所有目录存在，并预先创建数据库文件
mkdir -p /run/grok2api /app/data /tmp
mkdir -p "$(dirname "$DB_PATH")"
touch "$DB_PATH"

# -------------------------------------------------------------
# 2. 生成 grok2api 配置文件（确保静态资源与管理员账户配置正确）
# -------------------------------------------------------------
if [ -n "$CONFIG_CONTENT" ]; then
    echo "正在使用环境变量 CONFIG_CONTENT 写入配置文件..."
    echo "$CONFIG_CONTENT" > "$APP_CONFIG_PATH"
elif [ ! -f "$APP_CONFIG_PATH" ]; then
    echo "未检测到 config.yaml，正在生成默认配置..."
    
    JWT_SECRET=$(head -c 32 /dev/urandom | hexxdump -e '16/1 "%02x"' 2>/dev/null || echo "default-jwt-secret-key-32bytes-long-sec!")
    ENCRYPT_KEY=$(head -c 32 /dev/urandom | base64 2>/dev/null || echo "default-encryption-key-base64-random==")

    cat <<EOF > "$APP_CONFIG_PATH"
secrets:
  jwtSecret: "${JWT_SECRET}"
  credentialEncryptionKey: "${ENCRYPT_KEY}"
bootstrapAdmin:
  username: "admin"
  password: "admin_password123"
EOF
    echo "grok2api 配置文件生成成功 (默认管理员: admin / admin_password123)"
fi

# -------------------------------------------------------------
# 3. 生成 Litestream 配置文件
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
# 4. 尝试从 Backblaze B2 恢复数据库
# -------------------------------------------------------------
litestream restore -if-replica-exists -config "$LITESTREAM_CONFIG_PATH" "$DB_PATH" || true

# -------------------------------------------------------------
# 5. 启动 Litestream 后台备份 + 启动 grok2api 主应用
# -------------------------------------------------------------
echo "正在启动 Litestream 实时备份守护进程..."
litestream replicate -config "$LITESTREAM_CONFIG_PATH" &

echo "正在启动 grok2api 应用..."
exec /usr/local/bin/grok2api-entrypoint /app/grok2api --config "$APP_CONFIG_PATH" --listen 0.0.0.0:8000
