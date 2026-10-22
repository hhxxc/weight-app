#!/bin/sh
# weight-app 后端自动部署：从 GitHub Release 下载镜像 tar.gz → docker load → 重建容器。
#
# 为什么走「镜像 tar.gz 发 Release」而不是 ghcr.io / NAS 本地 build：
#   - NAS 直连 Docker Hub（registry-1.docker.io）被墙，拉不到 node:20-slim，本地 build 必失败。
#   - ghcr.io 包默认 private，匿名拉取 denied，设 public 的包命名空间又反复对不上。
#   - 而仓库是 public 的，Release 资产匿名可下载（NAS 实测 200）。
#   所以：CI 在云端 build 镜像（能拉 node:20-slim）→ docker save 成 tar.gz → 发 Release，
#   NAS 匿名下载 tar.gz → docker load。全链路无认证、无包可见性依赖。
#
# 判断「是否有新版本」：下载前先用 HTTP HEAD 看 remote 的 Content-Length / ETag，
# 与本地记录对比，变了才完整下载。沿用旧 JWT_SECRET（从旧容器读）。
#
# 手动检查： sh /volume2/docker/ezbk/weight_server_autosync.sh && tail weight_server_autosync.log
#
set -u

# 群晖 docker 装在 /usr/local/bin（sudo 的 PATH 不含它），显式补上
export PATH="/usr/local/bin:/usr/local/sbin:/usr/syno/bin:$PATH"

IMAGE_NAME="weight-server:latest"
ASSET_URL="https://github.com/hhxxc/weight-app/releases/latest/download/weight-server.tar.gz"
APP_DIR="${WEIGHT_APP_DIR:-/volume2/docker/weight-server}"
CONTAINER_NAME="weight-server"
HOST_PORT="${WEIGHT_PORT:-18191}"
STATE_DIR="${WEIGHT_STATE_DIR:-/volume2/docker/ezbk}"
ETAG_FILE="$STATE_DIR/.weight_server_last_etag"
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

# 1. 先 HEAD 探测远程是否更新（拿 ETag/Content-Length，不下载大文件）
REMOTE_TAG=$(curl -sI -L -m 60 "$ASSET_URL" 2>/dev/null | grep -iE '^(etag|content-length):' | tr '\n' ' ' | tr -d '\r')
if [ -z "$REMOTE_TAG" ]; then
    log "WARN: 探测 Release 资产失败（网络/URL 问题），跳过本次"
    exit 0
fi

LAST=""
[ -f "$ETAG_FILE" ] && LAST=$(cat "$ETAG_FILE" 2>/dev/null || echo "")

RUNNING=$(docker ps --filter name="$CONTAINER_NAME" --format '{{.Names}}' 2>/dev/null)
if [ "$REMOTE_TAG" = "$LAST" ] && [ -n "$RUNNING" ]; then
    exit 0   # 已是最新，静默
fi

[ -z "$LAST" ] && log "初始化：首次下载后端镜像（$REMOTE_TAG）" \
              || log "发现后端更新：$REMOTE_TAG（旧：$LAST），重新部署"

# 2. 下载 tar.gz
TMP_TAR="/tmp/weight-server.tar.gz"
if ! curl -sL -m 1800 -o "$TMP_TAR" "$ASSET_URL" >> "$LOG" 2>&1; then
    log "FAIL: 下载镜像 tar.gz 失败"
    exit 0
fi

# 3. 校验是 gzip，再 docker load
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

# 4. 沿用旧 JWT_SECRET：环境变量 → 旧容器环境 → 默认值
OLD_SECRET=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null \
             | grep '^JWT_SECRET=' | head -1 | cut -d= -f2-)
SECRET="${JWT_SECRET:-${OLD_SECRET:-change-me-in-production}}"

# 5. 重建容器
mkdir -p "$APP_DIR"
docker rm -f "$CONTAINER_NAME" 2>/dev/null
docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
    -p "$HOST_PORT:3000" \
    -e "JWT_SECRET=$SECRET" \
    -v "$APP_DIR/data:/data" \
    -v /volume2/docker/giliconcloude_key.txt:/data/giliconcloude_key.txt:ro \
    "$IMAGE_NAME" >> "$LOG" 2>&1 || { log "FAIL: docker run 失败"; exit 1; }

# 6. 记录
echo "$REMOTE_TAG" > "$ETAG_FILE"
log "后端部署完成：$REMOTE_TAG → 端口 $HOST_PORT（secret 已沿用）"
docker ps --filter name="$CONTAINER_NAME" --format '{{.Names}} {{.Status}} {{.Ports}}' >> "$LOG" 2>&1

# 日志只留最近 500 行
tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
