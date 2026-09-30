#!/bin/sh
# grok2api + Litestream 启动控制脚本
#
# 适用于任何无持久存储的容器平台（Render / Koyeb / Fly / Railway 等）。
# 通过 S3 兼容对象存储持久化 SQLite。
#
# 必需环境变量：
#   LITESTREAM_REPLICA_URL        s3://bucket/prefix
#   LITESTREAM_ACCESS_KEY_ID      访问密钥
#   LITESTREAM_SECRET_ACCESS_KEY  密钥
#   AWS_ENDPOINT_URL              S3 端点（AWS 官方可省略）
#
# 可选：
#   PORT                默认 8000，多数 PaaS 会自动注入
#   ADMIN_PASSWORD      初始管理员密码，不设则随机生成并打印
#   CONFIG_CONTENT      完整 config.yaml 内容，设置后覆盖自动生成
set -e

APP_DIR=/app
# 配置与数据库同放 data/ —— 该目录会被 Litestream 覆盖，
# 使 credentialEncryptionKey 在重启后保持不变。
DATA_DIR="${DATA_DIR:-/app/data}"
DB_PATH="${DB_PATH:-$DATA_DIR/backend.db}"
CONFIG_PATH="$DATA_DIR/config.yaml"
LS_CONFIG=/tmp/litestream.yml
PORT="${PORT:-8000}"

log() { echo "[wrapper] $*"; }
die() { echo "[wrapper] 错误: $*" >&2; exit 1; }

# ---------------------------------------------------------------
# 0. 前置检查
# ---------------------------------------------------------------
[ -n "$LITESTREAM_REPLICA_URL" ] || die "未设置 LITESTREAM_REPLICA_URL，数据将在重启后丢失。
  如确实只想临时试用，设 ALLOW_EPHEMERAL=1 跳过此检查。"

if [ -n "$GROK2API_DATABASE_URL" ]; then
  die "检测到 GROK2API_DATABASE_URL。该变量会把驱动切到 PostgreSQL，
  使 Litestream 失去意义。请删除它，或改用纯 PostgreSQL 部署（不需要本镜像）。"
fi

mkdir -p "$DATA_DIR" "$DATA_DIR/media"

# ---------------------------------------------------------------
# 1. 生成 Litestream 配置
# ---------------------------------------------------------------
{
  echo "dbs:"
  echo "  - path: \"$DB_PATH\""
  echo "    replicas:"
  echo "      - type: s3"
  echo "        url: \"$LITESTREAM_REPLICA_URL\""
  [ -n "$AWS_ENDPOINT_URL" ] && echo "        endpoint: \"$AWS_ENDPOINT_URL\""
  # 关机时把剩余帧刷到对象存储，避免丢失最后几秒的写入
  echo "        sync-interval: 1s"
} > "$LS_CONFIG"

# ---------------------------------------------------------------
# 2. 从对象存储恢复
# ---------------------------------------------------------------
if [ -f "$DB_PATH" ]; then
  log "本地已存在数据库，跳过恢复"
else
  log "尝试从对象存储恢复 $DB_PATH ..."
  if litestream restore -if-replica-exists -config "$LS_CONFIG" "$DB_PATH"; then
    if [ -f "$DB_PATH" ]; then
      log "恢复完成，大小 $(wc -c < "$DB_PATH") 字节"
    else
      log "副本为空（首次部署），将创建全新数据库"
    fi
  else
    # 凭据错误时若放行，会用空库覆盖云端备份，故必须中止
    die "恢复失败。请检查 LITESTREAM_REPLICA_URL、密钥与端点是否正确。
  （已中止启动，以免空数据库覆盖云端备份。）"
  fi
fi

# ---------------------------------------------------------------
# 3. 生成 config.yaml
# ---------------------------------------------------------------
if [ -n "$CONFIG_CONTENT" ]; then
  log "使用 CONFIG_CONTENT 提供的配置"
  printf '%s\n' "$CONFIG_CONTENT" > "$CONFIG_PATH"

else
  # 密钥从 MASTER_KEY 确定性派生。
  # Litestream 只复制数据库文件，配置文件不会被备份；若每次启动随机生成，
  # credentialEncryptionKey 就会改变，导致数据库中已加密的账号凭据全部失效。
  if [ -z "$MASTER_KEY" ]; then
    MASTER_KEY="$(head -c 32 /dev/urandom | base64 | tr -d '/+=')"
    GENERATED_MASTER=1
  fi

  derive() { printf '%s' "${MASTER_KEY}:$1" | sha256sum | cut -d' ' -f1; }

  JWT_SECRET="$(derive jwt)"
  # credentialEncryptionKey 需为 base64 编码的 32 字节
  ENCRYPT_KEY="$(derive cred | xxd -r -p | base64 | tr -d '\n')"
  [ ${#JWT_SECRET} -ge 32 ] || die "密钥派生失败"

  if [ -n "$ADMIN_PASSWORD" ]; then
    ADMIN_PW="$ADMIN_PASSWORD"
  else
    ADMIN_PW="$(derive pw | cut -c1-20)"
  fi

  # staticPath 与 media 用绝对路径：相对路径以配置文件所在目录为基准，
  # 而配置在 $DATA_DIR，前端却在 /app/frontend/dist。
  cat > "$CONFIG_PATH" <<EOF
server:
  listen: "0.0.0.0:${PORT}"
  maxBodyBytes: 33554432
  trustedProxies: []
  readTimeout: 15m
  requestTimeout: 2h
  swaggerEnabled: false

auth:
  accessTokenTTL: 15m
  refreshTokenTTL: 720h
  secureCookies: ${SECURE_COOKIES:-true}

secrets:
  jwtSecret: "${JWT_SECRET}"
  credentialEncryptionKey: "${ENCRYPT_KEY}"

bootstrapAdmin:
  username: "${ADMIN_USERNAME:-admin}"
  password: "${ADMIN_PW}"

frontend:
  staticPath: "${APP_DIR}/frontend/dist"

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
    path: "${DATA_DIR}/media"

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
  retentionDays: ${AUDIT_RETENTION_DAYS:-2}
  ledgerMode: enforce
  ledgerFailureThreshold: 1
  ledgerUnhealthyGrace: 10s
  ledgerQueueHighWatermarkPercent: 90

qualityGuard:
  enabled: false
EOF

  if [ -n "$GENERATED_MASTER" ]; then
    cat <<EOF

╔══════════════════════════════════════════════════════════╗
║  ⚠  未设置 MASTER_KEY，已自动生成                        ║
╚══════════════════════════════════════════════════════════╝

  MASTER_KEY=${MASTER_KEY}

  ⚠ 必须把它设为环境变量，否则下次重启会派生出不同的密钥，
    数据库中已保存的账号凭据将全部无法解密。

    立即操作：把上面这行加到平台的环境变量里，然后重启服务。

  管理员  ${ADMIN_USERNAME:-admin}  /  ${ADMIN_PW}

EOF
  else
    cat <<EOF

  管理员  ${ADMIN_USERNAME:-admin}  /  ${ADMIN_PW}
  （密码由 MASTER_KEY 派生，重启后不变；登录后请改密）

EOF
  fi
fi

chmod 600 "$CONFIG_PATH"

# 监听端口以环境变量为准（PaaS 每次分配的端口可能变化）
sed -i "s|^  listen: .*|  listen: \"0.0.0.0:${PORT}\"|" "$CONFIG_PATH"

# ---------------------------------------------------------------
# 4. 交出属主（镜像以 uid 10001 运行业务进程）
# ---------------------------------------------------------------
chown -R 10001:10001 "$DATA_DIR" 2>/dev/null || true

# ---------------------------------------------------------------
# 5. 启动 Litestream，再以非 root 启动主程序
# ---------------------------------------------------------------
litestream replicate -config "$LS_CONFIG" &
LS_PID=$!

# 转发停止信号：先停主程序，再让 Litestream 完成最后一次同步
term() {
  log "收到停止信号，正在收尾 ..."
  [ -n "$APP_PID" ] && kill -TERM "$APP_PID" 2>/dev/null || true
  [ -n "$APP_PID" ] && wait "$APP_PID" 2>/dev/null || true
  kill -TERM "$LS_PID" 2>/dev/null || true
  wait "$LS_PID" 2>/dev/null || true
  log "已完成最终同步"
  exit 0
}
trap term TERM INT

log "启动 grok2api，监听 0.0.0.0:${PORT}"
su-exec 10001:10001 "$APP_DIR/grok2api" --config "$CONFIG_PATH" --listen "0.0.0.0:${PORT}" &
APP_PID=$!

wait "$APP_PID"
RC=$?
kill -TERM "$LS_PID" 2>/dev/null || true
wait "$LS_PID" 2>/dev/null || true
exit $RC
