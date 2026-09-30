#!/bin/sh
set -e

cd /app

DB_PATH="${DB_PATH:-/app/data/backend.db}"
APP_CONFIG_PATH="/run/grok2api/config.yaml"
LITESTREAM_CONFIG_PATH="/tmp/litestream.yml"

# 1. 确保目录存在，并赋予完全读写权限 (777)
mkdir -p /run/grok2api /app/data /tmp /app/data/media
chmod -R 777 /app/data /run/grok2api /tmp

# -------------------------------------------------------------
# 2. 严格按官方规范生成 config.yaml
# -------------------------------------------------------------
if [ -n "$CONFIG_CONTENT" ]; then
    echo "$CONFIG_CONTENT" > "$APP_CONFIG_PATH"
elif [ ! -f "$APP_CONFIG_PATH" ]; then
    echo "正在根据官方规范生成 config.yaml..."
    
    JWT_SECRET=$(head -c 32 /dev/urandom | hexxdump -e '16/1 "%02x"' 2>/dev/null || echo "default-jwt-secret-key-32bytes-long-sec!")
    ENCRYPT_KEY=$(head -c 32 /dev/urandom | base64 2>/dev/null || echo "default-encryption-key-base64-random==")

    cat <<EOF > "$APP_CONFIG_PATH"
server:
  listen: "0.0.0.0:8000"
  maxBodyBytes: 33554432
  trustedProxies: []
  readTimeout: 15m
  requestTimeout: 2h
  swaggerEnabled: false

auth:
  accessTokenTTL: 15m
  refreshTokenTTL: 720h
  secureCookies: false

secrets:
  jwtSecret: "${JWT_SECRET}"
  credentialEncryptionKey: "${ENCRYPT_KEY}"

bootstrapAdmin:
  username: "admin"
  password: "admin_password123"

frontend:
  staticPath: "./frontend/dist"

database:
  driver: sqlite
  sqlite:
    path: "${DB_PATH}"

runtimeStore:
  driver: memory

deployment:
  replicas: 1
  clusterID: "grok2api"
  sharedMedia: false

media:
  driver: local
  local:
    path: "./data/media"

routing:
  reasoningReplayEnabled: true
  reasoningReplayTTL: 1h
  reasoningReplayMaxEntries: 10240
  accountIsolatedConnections: false
  segmentedSelectorEnabled: true
  segmentedSelectorMinCandidates: 3000
  segmentedSelectorWindowSize: 64
  autoAssignMaxNodeShare: 0
  autoAssignMaxMigrationShare: 0

audit:
  bufferSize: 16384
  batchSize: 256
  flushInterval: 250ms
  commitDelay: 5ms
  retentionDays: 7
  ledgerMode: enforce
  ledgerFailureThreshold: 1
  ledgerUnhealthyGrace: 10s
  ledgerQueueHighWatermarkPercent: 90

qualityGuard:
  enabled: false
EOF
    echo "配置文件生成完毕！"
fi

# -------------------------------------------------------------
# 3. 生成 Litestream 备份配置
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
# 4. 从 Backblaze B2 还原数据库（若存在）
# -------------------------------------------------------------
litestream restore -if-replica-exists -config "$LITESTREAM_CONFIG_PATH" "$DB_PATH" || true

# 再次确保恢复后的数据库文件具备写入权限
chmod -R 777 /app/data

# -------------------------------------------------------------
# 5. 启动后台 Litestream 同步与主程序
# -------------------------------------------------------------
litestream replicate -config "$LITESTREAM_CONFIG_PATH" &

exec /usr/local/bin/grok2api-entrypoint /app/grok2api --config "$APP_CONFIG_PATH"
