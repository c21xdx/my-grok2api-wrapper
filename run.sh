#!/bin/sh
set -e

# 1. 设置路径
DB_PATH="${DB_PATH:-/app/data/backend.db}"
APP_CONFIG_PATH="/run/grok2api/config.yaml"
LITESTREAM_CONFIG_PATH="/tmp/litestream.yml"

# 确保目录存在
mkdir -p /run/grok2api /app/data /tmp

# -------------------------------------------------------------
# 2. 生成 grok2api 配置文件（包含首次启动所需的管理员账号密码）
# -------------------------------------------------------------
if [ -n "$CONFIG_CONTENT" ]; then
    echo "正在使用环境变量 CONFIG_CONTENT 写入配置文件..."
    echo "$CONFIG_CONTENT" > "$APP_CONFIG_PATH"
elif [ ! -f "$APP_CONFIG_PATH" ]; then
    echo "未检测到 config.yaml，正在生成包含管理员账号的默认配置..."
    
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
# 3. 生成 Litestream 配置文件（避开命令行 -exec 解析 BUG）
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
# 4. 首次启动前尝试从 Backblaze B2 恢复数据库
# -------------------------------------------------------------
if [ -n "$AWS_ENDPOINT_URL" ]; then
    RESTORE_URL="${LITESTREAM_REPLICA_URL}?endpoint=${AWS_ENDPOINT_URL}"
else
    RESTORE_URL="${LITESTREAM_REPLICA_URL}"
fi

litestream restore -if-replica-exists "$DB_PATH" "$RESTORE_URL" || true

# -------------------------------------------------------------
# 5. 启动 Litestream 并拉起 grok2api 应用
# -------------------------------------------------------------
exec litestream replicate \
  -config "$LITESTREAM_CONFIG_PATH" \
  -exec "/usr/local/bin/grok2api-entrypoint /app/grok2api --config $APP_CONFIG_PATH --listen 0.0.0.0:8000"
