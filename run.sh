#!/bin/sh
set -e

# 设置数据库文件与配置文件路径
DB_PATH="${DB_PATH:-/app/data/data.db}"
CONFIG_PATH="/app/config.yaml"

# -------------------------------------------------------------
# 1. 拼接带 endpoint 的完整 S3 目标 URL
# -------------------------------------------------------------
# 如果 LITESTREAM_REPLICA_URL 里还没有带 ?endpoint，自动拼接上去
if [ -n "$AWS_ENDPOINT_URL" ]; then
    TARGET_URL="${LITESTREAM_REPLICA_URL}?endpoint=${AWS_ENDPOINT_URL}"
else
    TARGET_URL="${LITESTREAM_REPLICA_URL}"
fi

# -------------------------------------------------------------
# 2. 防错逻辑：确保 config.yaml 存在
# -------------------------------------------------------------
if [ -n "$CONFIG_CONTENT" ]; then
    echo "正在使用环境变量 CONFIG_CONTENT 写入配置文件..."
    echo "$CONFIG_CONTENT" > "$CONFIG_PATH"
elif [ ! -f "$CONFIG_PATH" ]; then
    echo "未检测到 config.yaml，正在自动生成默认安全配置..."
    
    JWT_SECRET=$(head -c 32 /dev/urandom | hexxdump -e '16/1 "%02x"' 2>/dev/null || echo "default-jwt-secret-key-32bytes-long-sec!")
    ENCRYPT_KEY=$(head -c 32 /dev/urandom | base64 2>/dev/null || echo "default-encryption-key-base64-random==")

    cat <<EOF > "$CONFIG_PATH"
secrets:
  jwtSecret: "${JWT_SECRET}"
  credentialEncryptionKey: "${ENCRYPT_KEY}"
  bootstrapAdmin:
    username: "admin"
    password: "admin_password123"
EOF
    echo "默认 config.yaml 生成成功 (默认管理员账号: admin，密码: admin_password123)"
fi

# -------------------------------------------------------------
# 3. Litestream 还原与实时同步（语法修正版）
# -------------------------------------------------------------
# 启动时如果 Backblaze B2 里有旧备份，自动拉取还原
litestream restore -if-replica-exists "$DB_PATH" "$TARGET_URL" || true

# 启动 Litestream 监控，并接管拉起原程序
exec litestream replicate -exec "/usr/local/bin/grok2api-entrypoint /app/grok2api --config $CONFIG_PATH --listen 0.0.0.0:8000" "$DB_PATH" "$TARGET_URL"
