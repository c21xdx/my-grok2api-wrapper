# grok2api + Litestream
# 面向无持久存储的容器平台（Render / Koyeb / Fly / Railway 等）
#
# Litestream 从源码构建：官方 0.5.17 二进制存在时钟回退导致的 panic
# （upstream #1488/#1489，PR #1494 未合并），在部分 KVM 宿主上会让复制
# 静默停止——而复制是这里唯一的持久化手段，故必须修掉。

FROM golang:1.25-alpine AS litestream

RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 --branch v0.5.17 \
      https://github.com/benbjohnson/litestream.git .

# db.go:1276 把 time.Since() 直接喂给 Prometheus counter；
# 时钟回退时该值为负，counter 拒绝减少 → panic，进程退出。
RUN sed -i 's|db.syncSecondsCounter.Add(float64(time.Since(t).Seconds()))|if _d := time.Since(t).Seconds(); _d > 0 { db.syncSecondsCounter.Add(_d) }|' db.go \
 && grep -q '_d > 0' db.go || (echo "补丁未命中，上游代码可能已变更" && exit 1)

RUN CGO_ENABLED=0 go build -ldflags '-s -w' -o /litestream ./cmd/litestream \
 && /litestream version


FROM ghcr.io/chenyme/grok2api:latest

USER root
COPY --from=litestream /litestream /usr/local/bin/litestream
COPY run.sh /run.sh
RUN chmod +x /run.sh

ENTRYPOINT ["/run.sh"]
