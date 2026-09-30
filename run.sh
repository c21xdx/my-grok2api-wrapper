#!/bin/sh
set -e

# 1. 设置路径（grok2api 默认从 /run/grok2api/config.yaml 读取）
DB_PATH="${DB_PATH:-/app/data/backend.db}"
CONFIG_PATH="/run/grok2api/config.yaml"

# 确保目标文件夹存在
mkdir -p /run/grok2api /app/data

# 2. 拼接 Endpoint 到 S3 URL
if [ -n "$AWS_ENDPOINT_URL" ]; then
    TARGET_URL="${LITESTREAM_REPLICA_URL}?endpoint=${AWS_ENDPOINT_URL}"
else
    TARGET_URL="${LITESTREAM_REPLICA_URL}"
fi

# 3. 自动填充严格符合 grok2api 结构的 config.yaml
if [ -n "$CONFIG_CONTENT" ]; then
    echo "正在使用环境变量 CONFIG_CONTENT 写入配置文件..."
    echo "$CONFIG_CONTENT" > "$CONFIG_PATH"
elif [ ! -f "$CONFIG_PATH" ]; then
    echo "未检测到 config.yaml，正在生成符合格式的默认配置文件..."
    
    JWT_SECRET=$(head -c 32 /dev/urandom | hexxdump -e '16/1 "%02x"' 2>/dev/null || echo "default-jwt-secret-key-32bytes-long-sec!")
    ENCRYPT_KEY=$(head -c 32 /dev/urandom | base64 2>/dev/null || echo "default-encryption-key-base64-random==")

    cat <<EOF > "$CONFIG_PATH"
jwtSecret: "${JWT_SECRET}"
credentialEncryptionKey: "${ENCRYPT_KEY}"
EOF
    echo "默认配置已成功生成至 $CONFIG_PATH"
fi

# 4. 从 Backblaze B2 还原数据库（如果存在）
litestream restore -if-replica-exists "$DB_PATH" "$TARGET_URL" || true

# 5. 启动 Litestream，并挂载拉起原应用
exec litestream replicate \
  -exec "/usr/local/bin/grok2api-entrypoint /app/grok2api --config $CONFIG_PATH --listen 0.0.0.0:8000" \
  "$DB_PATH" \
  "$TARGET_URL"
