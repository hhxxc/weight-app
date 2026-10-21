#!/bin/sh
# weight-app 后端自动部署：定时从 GitHub Releases 拉 server.tar.gz → 解压 → docker build → 重启
#
# 与 weight_autosync.sh 共用同一 Release（CI 每次发 vX.Y.Z，同时含 weight-app.ipa + server.tar.gz）。
# 这里只负责后端：拉 server.tar.gz，在 NAS 本地 docker build（基础镜像 node:20-slim 首次拉一次，
# 之后走缓存），重建容器并沿用旧 JWT_SECRET（避免用户 token 因后端更新失效）。
#
# ★ 不走 GitHub API，用永久地址：/releases/latest/download/server.tar.gz
#
# 手动检查： sh /volume2/docker/ezbk/weight_server_autosync.sh && tail weight_server_autosync.log
#
set -u

REPO="${WEIGHT_REPO:-hhxxc/weight-app}"
APP_DIR="${WEIGHT_APP_DIR:-/volume2/docker/weight-server}"
CONTAINER_NAME="weight-server"
HOST_PORT="${WEIGHT_PORT:-18191}"
STATE_DIR="${WEIGHT_STATE_DIR:-/volume2/docker/ezbk}"
DIGEST_FILE="$STATE_DIR/.weight_server_last_tag"
LOG="$STATE_DIR/weight_server_autosync.log"
LOCK="$STATE_DIR/.weight_server.lock"
ASSET_URL="https://github.com/${REPO}/releases/latest/download/server.tar.gz"

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

mkdir -p "$STATE_DIR" "$APP_DIR"

# 1. 取最新 tag
LOC=$(curl -sI -m 30 -H "User-Agent: weight-autosync" "$ASSET_URL" 2>/dev/null \
      | grep -i '^location:' | tr -d '\r' | sed 's/^[Ll]ocation: *//')
REMOTE_TAG=$(echo "$LOC" | sed -n 's#.*/releases/download/\([^/]*\)/.*#\1#p')

if [ -z "$REMOTE_TAG" ]; then
    log "WARN: 查询 server.tar.gz 失败，跳过本次"
    exit 0
fi

# 2. 与基线比对（同 tag 且已有 server 目录则跳过）
LAST=""
[ -f "$DIGEST_FILE" ] && LAST=$(cat "$DIGEST_FILE" 2>/dev/null || echo "")
if [ "$REMOTE_TAG" = "$LAST" ] && [ -f "$APP_DIR/server/package.json" ]; then
    exit 0
fi

[ -z "$LAST" ] && log "初始化：首次部署后端 $REMOTE_TAG" \
              || log "发现后端新版本：$REMOTE_TAG（旧：$LAST），开始部署"

# 3. 下载 server.tar.gz
TMP="$APP_DIR/.server.tar.gz.tmp"
dl_ok=0
for try in 1 2 3; do
    if curl -sL -m 240 -H "User-Agent: weight-autosync" -o "$TMP" "$ASSET_URL" 2>/dev/null; then
        if tar tzf "$TMP" >/dev/null 2>&1; then
            dl_ok=1
            break
        fi
    fi
    log "WARN: 第 $try 次下载 server.tar.gz 失败，重试"
    sleep 5
done
if [ "$dl_ok" -ne 1 ]; then
    rm -f "$TMP"
    log "FAIL: server.tar.gz 下载失败（3 次重试均未成功）"
    exit 1
fi

# 4. 解压（覆盖旧源码，data 目录在 tar 里已排除，不受影响）
cd "$APP_DIR" || exit 1
tar xzf "$TMP" && rm -f "$TMP"

# 5. 沿用旧 JWT_SECRET：优先环境变量 → 旧容器环境 → 默认值
OLD_SECRET=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null \
             | grep '^JWT_SECRET=' | head -1 | cut -d= -f2-)
SECRET="${JWT_SECRET:-${OLD_SECRET:-change-me-in-production}}"

# 6. build + 重启容器
cd "$APP_DIR/server" || exit 1
log "docker build 开始…"
docker build -t "$CONTAINER_NAME" . >> "$LOG" 2>&1 || { log "FAIL: docker build 失败"; exit 1; }
docker rm -f "$CONTAINER_NAME" 2>/dev/null
docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
    -p "$HOST_PORT:3000" \
    -e "JWT_SECRET=$SECRET" \
    -v "$APP_DIR/data:/data" \
    "$CONTAINER_NAME" >> "$LOG" 2>&1 || { log "FAIL: docker run 失败"; exit 1; }

# 7. 记录
echo "$REMOTE_TAG" > "$DIGEST_FILE"
log "后端部署完成：$REMOTE_TAG → 端口 $HOST_PORT（secret 已沿用）"
docker ps --filter name="$CONTAINER_NAME" --format '{{.Names}} {{.Status}} {{.Ports}}' >> "$LOG" 2>&1

# 日志只留最近 500 行
tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
