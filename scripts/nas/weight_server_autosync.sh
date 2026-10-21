#!/bin/sh
# weight-app 后端自动部署：从 GitHub Release 拉镜像 tar.gz → docker load → 重建容器。
#
# 为什么是「镜像 tar.gz」而不是 NAS 本地 build：
#   NAS 直连 Docker Hub（registry-1.docker.io）被墙，拉不到 node:20-slim 基础镜像，
#   本地 docker build 必失败。所以 CI 在 GitHub 云端构建镜像（能拉 node:20-slim），
#   docker save 导出 tar.gz 发到 Release，NAS 只下载 tar + docker load。
#
# 判断「是否有新版本」：不调 GitHub API（NAS 出口 IP 匿名调用会 403），
# 从 releases/latest/download/weight-server.tar.gz 的 Location 头解析 tag，变了才重新部署。
# 沿用旧 JWT_SECRET（从旧容器读），避免用户 token 因后端更新失效。
#
# 手动检查： sh /volume2/docker/ezbk/weight_server_autosync.sh && tail weight_server_autosync.log
#
set -u

# 群晖 docker 装在 /usr/local/bin（sudo 的 PATH 不含它），显式补上
export PATH="/usr/local/bin:/usr/local/sbin:/usr/syno/bin:$PATH"

REPO="${WEIGHT_REPO:-hhxxc/weight-app}"
APP_DIR="${WEIGHT_APP_DIR:-/volume2/docker/weight-server}"
CONTAINER_NAME="weight-server"
HOST_PORT="${WEIGHT_PORT:-18191}"
STATE_DIR="${WEIGHT_STATE_DIR:-/volume2/docker/ezbk}"
DIGEST_FILE="$STATE_DIR/.weight_server_last_tag"
LOG="$STATE_DIR/weight_server_autosync.log"
LOCK="$STATE_DIR/.weight_server.lock"
ASSET_URL="https://github.com/${REPO}/releases/latest/download/weight-server.tar.gz"

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

# 1. 取最新 tag：HEAD 不跟随重定向，从 Location 头解析
LOC=$(curl -sI -m 30 -H "User-Agent: weight-autosync" "$ASSET_URL" 2>/dev/null \
      | grep -i '^location:' | tr -d '\r' | sed 's/^[Ll]ocation: *//')
REMOTE_TAG=$(echo "$LOC" | sed -n 's#.*/releases/download/\([^/]*\)/.*#\1#p')

if [ -z "$REMOTE_TAG" ]; then
    log "WARN: 查询 weight-server.tar.gz 失败，跳过本次"
    exit 0
fi

# 2. 与基线比对（同 tag 且容器在跑则跳过）
LAST=""
[ -f "$DIGEST_FILE" ] && LAST=$(cat "$DIGEST_FILE" 2>/dev/null || echo "")
RUNNING=$(docker ps --filter name="$CONTAINER_NAME" --format '{{.Names}}' 2>/dev/null)
if [ "$REMOTE_TAG" = "$LAST" ] && [ -n "$RUNNING" ]; then
    exit 0
fi

[ -z "$LAST" ] && log "初始化：首次部署后端 $REMOTE_TAG" \
              || log "发现后端新版本：$REMOTE_TAG（旧：$LAST），开始部署"

# 3. 下载镜像 tar.gz（国内直连 release-assets 可能慢，给足超时并重试 3 次）
TMP="$APP_DIR/.weight-server.tar.gz.tmp"
dl_ok=0
for try in 1 2 3; do
    if curl -sL -m 600 -H "User-Agent: weight-autosync" -o "$TMP" "$ASSET_URL" 2>/dev/null; then
        if gzip -t "$TMP" 2>/dev/null; then
            dl_ok=1
            break
        fi
    fi
    log "WARN: 第 $try 次下载镜像失败，重试"
    sleep 5
done
if [ "$dl_ok" -ne 1 ]; then
    rm -f "$TMP"
    log "FAIL: weight-server.tar.gz 下载失败（3 次重试均未成功）"
    exit 1
fi

# 4. docker load + 沿用旧 JWT_SECRET
OLD_SECRET=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null \
             | grep '^JWT_SECRET=' | head -1 | cut -d= -f2-)
SECRET="${JWT_SECRET:-${OLD_SECRET:-change-me-in-production}}"

log "docker load 开始…"
if ! docker load -i "$TMP" >> "$LOG" 2>&1; then
    rm -f "$TMP"
    log "FAIL: docker load 失败"
    exit 1
fi
rm -f "$TMP"

docker rm -f "$CONTAINER_NAME" 2>/dev/null
docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
    -p "$HOST_PORT:3000" \
    -e "JWT_SECRET=$SECRET" \
    -v "$APP_DIR/data:/data" \
    "weight-server:latest" >> "$LOG" 2>&1 || { log "FAIL: docker run 失败"; exit 1; }

# 5. 记录
echo "$REMOTE_TAG" > "$DIGEST_FILE"
log "后端部署完成：$REMOTE_TAG → 端口 $HOST_PORT（secret 已沿用）"
docker ps --filter name="$CONTAINER_NAME" --format '{{.Names}} {{.Status}} {{.Ports}}' >> "$LOG" 2>&1

# 日志只留最近 500 行
tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
