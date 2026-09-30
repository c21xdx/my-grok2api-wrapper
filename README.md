# grok2api + Litestream

在**没有持久存储**的容器平台上运行 [grok2api](https://github.com/chenyme/grok2api)。
SQLite 数据库通过 Litestream 持续复制到 S3 兼容对象存储，实例重建后自动恢复。

已在 Render 验证；同样适用于 Koyeb、Fly.io、Railway 等任何支持
Dockerfile + 环境变量的平台。

---

## 快速开始

### 1. 准备对象存储

任选其一，建一个**私有** bucket：

| 服务 | 免费额度 | 端点格式 |
|---|---|---|
| Backblaze B2 | 10GB 存储，API 调用免费 | `https://s3.<region>.backblazeb2.com` |
| Cloudflare R2 | 10GB 存储，出站免费 | `https://<account>.r2.cloudflarestorage.com` |
| 其他 S3 兼容 | — | 自填 |

> B2 建桶时 **Object Lock 必须禁用**，否则 Litestream 无法清理过期文件。

创建一个限定该 bucket 的 Access Key，记下 keyID 与 secret。

### 2. 生成 MASTER_KEY

```bash
head -c 32 /dev/urandom | base64 | tr -d '/+='
```

**这是最重要的一个值。** 所有密钥都由它派生，丢了等于所有已存账号凭据报废。
存进密码管理器。

### 3. 填写 .env

```bash
cp .env.example .env
```

必填 5 项：`MASTER_KEY`、`LITESTREAM_REPLICA_URL`、两个密钥、`AWS_ENDPOINT_URL`。
其余都有默认值，可以不管。

> `.env` 已在 `.gitignore` 中，不要提交。

### 4. 部署

把仓库推到 GitHub，在平台创建 Docker 服务，然后用以下**任一**方式提供配置：

**方式 A — 单个环境变量**（推荐，Render / Koyeb 等都适用）

新建变量 `ENV_FILE_CONTENT`，把整个 `.env` 内容**原样粘贴**进去。
只需配这一个变量。

**方式 B — Secret File**

把 `.env` 挂到 `/etc/secrets/.env`。
Render 的 Secret Files、Koyeb 的 File Mounts 都支持。
也可用 `ENV_FILE` 指定其他路径。

**方式 C — 逐个设置**

按 `.env.example` 里的键名一个个填环境变量。

**本地**

```bash
docker run --env-file .env -p 8000:8000 <镜像>
```

> 优先级：环境变量 > `.env` 文件。平台注入的 `PORT` 始终生效，
> 不会被文件里的值覆盖。

首次启动日志会打印管理员密码。


### 5. 验证持久化

**务必做这一步**，否则不知道复制是否真的生效：

1. 登录后台建一个 client key
2. 在平台上重启/重新部署服务
3. key 还在 = 成功

日志应显示 `恢复完成，大小 NNNNN 字节` 而非「副本为空」。

---

## 平台差异

| 平台 | 注意事项 |
|---|---|
| **Render** | 免费实例 15 分钟无流量休眠，需外部定时 ping `/healthz`。关闭 Auto-Deploy 以免重叠部署。 |
| **Koyeb** | 免费实例不休眠。Scale 必须保持 1。 |
| **Fly.io** | 设 `auto_stop_machines = false`，或接受冷启动。`min_machines_running = 1`。 |
| **Railway** | 按用量计费，注意额度。 |

**所有平台的共同铁律：实例数必须为 1。** Litestream 是单写者模型，
多实例同时写同一前缀会损坏备份。

---

## 已知限制

- **媒体文件不持久**。Litestream 只复制 SQLite，`data/media/` 下的图片视频
  在实例重建后丢失，数据库里会留下死链。要彻底解决需改用 S3 媒体驱动。
- **重新部署有短暂双写窗口**。平台若先起新实例再停旧实例，两者会同时
  写同一前缀。窗口很小，但要绝对安全应先停服务再部署。
- **RPO 约 1 秒**。`sync-interval: 1s`，崩溃最多丢最后 1 秒的写入。

---

## 实现说明

### 为什么从源码构建 Litestream

官方 v0.5.17 二进制在 `db.go:1276` 把 `time.Since()` 直接喂给 Prometheus
counter。时钟回退时该值为负，counter 拒绝减少并 panic
（upstream [#1488](https://github.com/benbjohnson/litestream/issues/1488)、
[#1489](https://github.com/benbjohnson/litestream/issues/1489)，
PR [#1494](https://github.com/benbjohnson/litestream/pull/1494) 未合并）。
部分 KVM 宿主上会触发，导致复制**静默停止**——而复制是这里唯一的持久化
手段，故构建时打了补丁。

### 为什么密钥要从 MASTER_KEY 派生

Litestream 只复制数据库文件，**不复制配置文件**。若每次启动随机生成
`credentialEncryptionKey`，重启后数据库虽然恢复了，但里面加密存储的
账号凭据再也解不开。用固定的 MASTER_KEY 确定性派生可避免这一点。

### 为什么用绝对路径

grok2api 的相对路径以**配置文件所在目录**为基准解析
（`config.go:432` `resolveRelativePaths`）。配置若不在 `/app`，
`staticPath: "./frontend/dist"` 就会指向不存在的位置，前端全部 404。
本脚本一律写绝对路径。

---

## 本地测试

```bash
docker build -t g2a .
mkdir -p /tmp/rep

cat > .env.local <<'EOF'
MASTER_KEY=local-test-key
LITESTREAM_REPLICA_URL=file:///replica/db
SECURE_COOKIES=false
EOF

docker run --rm -p 8000:8000 -v /tmp/rep:/replica --env-file .env.local g2a
```

`file://` 副本便于快速验证，无需真实对象存储。
本地必须设 `SECURE_COOKIES=false`，否则 HTTP 下浏览器不回传 cookie。
