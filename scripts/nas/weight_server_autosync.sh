#!/bin/sh
# weight-app 后端自动部署：优先「只同步源码」（秒级），依赖变化时才换镜像。
#
# 为什么需要两条通道：
#   - 镜像 tar.gz 有 ~79MB，NAS 出口只有几十 KB/s，一次部署要 15~30 分钟。
#   - 而绝大多数后端改动只涉及 src/*.js（几十 KB），完全没必要重传整个镜像。
#   所以：
#     1) 快速通道：下载 server-src.tar.gz（几十 KB）→ docker cp 进容器 → restart。
#        package.json 与容器内的一致才走（依赖没变），否则回退。
#     2) 镜像通道：weight-server.tar.gz（79MB），用于首次部署、依赖变化、容器丢失。
#
# 判断「是否有新版本」：HTTP HEAD 看 Release 资产的 ETag/Content-Length。
#
# 手动检查： sh /volume2/docker/ezbk/weight_server_autosync.sh && tail weight_server_autosync.log
#
set -u

# 群晖 docker 装在 /usr/local/bin（sudo 的 PATH 不含它），显式补上
export PATH="/usr/local/bin:/usr/local/sbin:/usr/syno/bin:$PATH"

IMAGE_NAME="weight-server:latest"
ASSET_URL="https://github.com/hhxxc/weight-app/releases/latest/download/weight-server.tar.gz"
SRC_URL="https://github.com/hhxxc/weight-app/releases/latest/download/server-src.tar.gz"
APP_DIR="${WEIGHT_APP_DIR:-/volume2/docker/weight-server}"
CONTAINER_NAME="weight-server"
HOST_PORT="${WEIGHT_PORT:-18191}"
STATE_DIR="${WEIGHT_STATE_DIR:-/volume2/docker/ezbk}"
ETAG_FILE="$STATE_DIR/.weight_server_last_etag"
SRC_ETAG_FILE="$STATE_DIR/.weight_server_src_etag"
LOG="$STATE_DIR/weight_server_autosync.log"
LOCK="$STATE_DIR/.weight_server.lock"

# 显式指定 secret 时用环境变量；否则沿用旧容器里的（首次用默认值）
JWT_SECRET="${WEIGHT_JWT_SECRET:-}"

ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $1" >> "$LOG"; }

# 单实例
if [ -e "$LOCK" ]; then
    if [ -n "$(find "$LOCK" -mmin +10 2>/dev/null)" ]; then
        log "WARN: 发现陈旧锁，接管"
        rm -f "$LOCK"
    else
        exit 0
    fi
fi
: > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM

mkdir -p "$STATE_DIR"

RUNNING=$(docker ps --filter name="$CONTAINER_NAME" --format '{{.Names}}' 2>/dev/null)

# ---------- 通道一：只同步源码（秒级） ----------
# 源码包只有 ~12KB，直接下载后用 md5 判断是否变化（比 HEAD 的 ETag 可靠：
# GitHub 对刚上传的资产 HEAD 有时只返回 content-length: 0，标记会退化）。
TMP_SRC="/tmp/weight-src.tar.gz"
SRC_LAST=""
[ -f "$SRC_ETAG_FILE" ] && SRC_LAST=$(cat "$SRC_ETAG_FILE" 2>/dev/null || echo "")
SRC_TAG=""
SRC_OK=0   # 1 = 源码已是最新，本次无需动镜像

if curl -sL -m 180 -o "$TMP_SRC" "$SRC_URL" 2>/dev/null && gzip -t "$TMP_SRC" 2>/dev/null; then
    rm -rf /tmp/weight-src
    mkdir -p /tmp/weight-src
    if tar -xzf "$TMP_SRC" -C /tmp/weight-src 2>/dev/null; then
        # 用「文件内容哈希」而不是 tar 的 md5：tar 带 mtime，纯 iOS 提交也会变
        SRC_TAG=$(cd /tmp/weight-src && find src -type f | sort | xargs md5sum 2>/dev/null | md5sum | cut -d' ' -f1)
        if [ -n "$SRC_TAG" ] && [ -n "$RUNNING" ]; then
            if [ "$SRC_TAG" = "$SRC_LAST" ]; then
                SRC_OK=1
            else
                log "发现源码更新：$SRC_TAG（旧：${SRC_LAST:-无}），尝试快速部署"
                LOCAL_PKG=$(md5sum /tmp/weight-src/package.json 2>/dev/null | cut -d' ' -f1)
                REMOTE_PKG=$(docker exec "$CONTAINER_NAME" md5sum /app/package.json 2>/dev/null | cut -d' ' -f1)
                if [ -n "$LOCAL_PKG" ] && [ "$LOCAL_PKG" = "$REMOTE_PKG" ]; then
                    OK=1
                    docker exec "$CONTAINER_NAME" rm -rf /app/src.new >> "$LOG" 2>&1 || OK=0
                    if [ "$OK" = "1" ]; then
                        docker cp /tmp/weight-src/src "$CONTAINER_NAME":/app/src.new >> "$LOG" 2>&1 || OK=0
                    fi
                    if [ "$OK" = "1" ]; then
                        docker exec "$CONTAINER_NAME" sh -c 'rm -rf /app/src && mv /app/src.new /app/src' >> "$LOG" 2>&1 || OK=0
                    fi
                    if [ "$OK" = "1" ]; then
                        docker restart "$CONTAINER_NAME" >> "$LOG" 2>&1 || OK=0
                    fi
                    if [ "$OK" = "1" ]; then
                        echo "$SRC_TAG" > "$SRC_ETAG_FILE"
                        log "快速部署完成（仅源码，秒级）：$SRC_TAG"
                        docker ps --filter name="$CONTAINER_NAME" --format '{{.Names}} {{.Status}}' >> "$LOG" 2>&1
                        rm -rf /tmp/weight-src "$TMP_SRC"
                        exit 0
                    fi
                    log "WARN: 快速部署失败，回退镜像通道"
                else
                    log "依赖有变化（package.json 不一致），回退镜像通道"
                fi
            fi
        fi
    fi
    rm -rf /tmp/weight-src
    rm -f "$TMP_SRC"
fi

# 源码已确认是最新的：直接结束。
# 否则「纯 iOS 发版」也会因为镜像 tar 重新打包（ETag 变）而白下 79MB。
if [ "$SRC_OK" = "1" ]; then
    exit 0
fi

# ---------- 通道二：整镜像部署（依赖变化 / 首次 / 容器丢失） ----------
REMOTE_TAG=$(curl -sI -L -m 60 "$ASSET_URL" 2>/dev/null | grep -iE '^(etag|content-length):' | tr '\n' ' ' | tr -d '\r')
if [ -z "$REMOTE_TAG" ]; then
    log "WARN: 探测 Release 资产失败（网络/URL 问题），跳过本次"
    exit 0
fi

LAST=""
[ -f "$ETAG_FILE" ] && LAST=$(cat "$ETAG_FILE" 2>/dev/null || echo "")

if [ "$REMOTE_TAG" = "$LAST" ] && [ -n "$RUNNING" ]; then
    exit 0   # 已是最新，静默
fi

[ -z "$LAST" ] && log "初始化：首次下载后端镜像（$REMOTE_TAG）" \
              || log "发现后端更新：$REMOTE_TAG（旧：$LAST），重新部署"

TMP_TAR="/tmp/weight-server.tar.gz"
if ! curl -sL -m 1800 -o "$TMP_TAR" "$ASSET_URL" >> "$LOG" 2>&1; then
    log "FAIL: 下载镜像 tar.gz 失败"
    exit 0
fi

if ! gzip -t "$TMP_TAR" 2>/dev/null; then
    log "WARN: 下载内容不是有效 gzip（可能是错误页），跳过"
    rm -f "$TMP_TAR"
    exit 0
fi

if ! docker load -i "$TMP_TAR" >> "$LOG" 2>&1; then
    log "FAIL: docker load 失败"
    rm -f "$TMP_TAR"
    exit 0
fi
rm -f "$TMP_TAR"

# 沿用旧 JWT_SECRET：环境变量 → 旧容器环境 → 默认值
OLD_SECRET=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null \
             | grep '^JWT_SECRET=' | head -1 | cut -d= -f2-)
SECRET="${JWT_SECRET:-${OLD_SECRET:-change-me-in-production}}"

mkdir -p "$APP_DIR"
docker rm -f "$CONTAINER_NAME" 2>/dev/null
docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
    -p "$HOST_PORT:3000" \
    -e "JWT_SECRET=$SECRET" \
    -e "ADMIN_USERNAME=${ADMIN_USERNAME:-hhxxc}" \
    -v "$APP_DIR/data:/data" \
    -v /volume2/docker/giliconcloude_key.txt:/data/giliconcloude_key.txt:ro \
    "$IMAGE_NAME" >> "$LOG" 2>&1 || { log "FAIL: docker run 失败"; exit 1; }

echo "$REMOTE_TAG" > "$ETAG_FILE"
[ -n "$SRC_TAG" ] && echo "$SRC_TAG" > "$SRC_ETAG_FILE"
log "后端部署完成：$REMOTE_TAG → 端口 $HOST_PORT（secret 已沿用）"
docker ps --filter name="$CONTAINER_NAME" --format '{{.Names}} {{.Status}} {{.Ports}}' >> "$LOG" 2>&1

# 日志只留最近 500 行
tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
