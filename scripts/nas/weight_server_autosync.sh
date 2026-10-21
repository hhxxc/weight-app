#!/bin/sh
# weight-app 后端自动部署：从 ghcr.io 拉最新镜像 → 重建容器。
#
# 为什么走 ghcr.io 而不是 NAS 本地 build：
#   NAS 直连 Docker Hub（registry-1.docker.io）被墙，拉不到 node:20-slim 基础镜像，
#   本地 docker build 必失败。而 CI 在 GitHub 云端构建镜像（能拉 node:20-slim），
#   推送到 ghcr.io（GitHub 容器仓库，NAS 实测可达），NAS 只拉成品镜像。
#
# 判断「是否有新版本」：不调 GitHub API（NAS 出口 IP 匿名调用会 403），
# 而是直接 docker pull latest，比对 digest，变了才重建容器。
# 沿用旧 JWT_SECRET（从旧容器读），避免用户 token 因后端更新失效。
#
# 手动检查： sh /volume2/docker/ezbk/weight_server_autosync.sh && tail weight_server_autosync.log
#
set -u

# 群晖 docker 装在 /usr/local/bin（sudo 的 PATH 不含它），显式补上
export PATH="/usr/local/bin:/usr/local/sbin:/usr/syno/bin:$PATH"

IMAGE="ghcr.io/hhxxc/weight-server:latest"
APP_DIR="${WEIGHT_APP_DIR:-/volume2/docker/weight-server}"
CONTAINER_NAME="weight-server"
HOST_PORT="${WEIGHT_PORT:-18191}"
STATE_DIR="${WEIGHT_STATE_DIR:-/volume2/docker/ezbk}"
DIGEST_FILE="$STATE_DIR/.weight_server_last_digest"
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

# 1. 拉最新镜像（失败静默跳过，下轮重试）
if ! docker pull "$IMAGE" >> "$LOG" 2>&1; then
    log "WARN: 拉取 $IMAGE 失败，跳过本次"
    exit 0
fi

# 2. digest 对比：无变化且容器在跑则跳过
NEW_DIGEST=$(docker inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null)
if [ -z "$NEW_DIGEST" ]; then
    log "WARN: 无法读取镜像 digest，跳过本次"
    exit 0
fi

LAST=""
[ -f "$DIGEST_FILE" ] && LAST=$(cat "$DIGEST_FILE" 2>/dev/null || echo "")

RUNNING=$(docker ps --filter name="$CONTAINER_NAME" --format '{{.Names}}' 2>/dev/null)
if [ "$NEW_DIGEST" = "$LAST" ] && [ -n "$RUNNING" ]; then
    exit 0   # 已是最新，静默
fi

[ -z "$LAST" ] && log "初始化：首次部署镜像 $NEW_DIGEST" \
              || log "发现后端新镜像：$NEW_DIGEST（旧：$LAST），重建容器"

# 3. 沿用旧 JWT_SECRET：环境变量 → 旧容器环境 → 默认值
OLD_SECRET=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null \
             | grep '^JWT_SECRET=' | head -1 | cut -d= -f2-)
SECRET="${JWT_SECRET:-${OLD_SECRET:-change-me-in-production}}"

# 4. 重建容器
mkdir -p "$APP_DIR"
docker rm -f "$CONTAINER_NAME" 2>/dev/null
docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
    -p "$HOST_PORT:3000" \
    -e "JWT_SECRET=$SECRET" \
    -v "$APP_DIR/data:/data" \
    -v /volume2/docker/giliconcloude_key.txt:/data/giliconcloude_key.txt:ro \
    "$IMAGE" >> "$LOG" 2>&1 || { log "FAIL: docker run 失败"; exit 1; }

# 5. 记录
echo "$NEW_DIGEST" > "$DIGEST_FILE"
log "后端部署完成：$NEW_DIGEST → 端口 $HOST_PORT（secret 已沿用）"
docker ps --filter name="$CONTAINER_NAME" --format '{{.Names}} {{.Status}} {{.Ports}}' >> "$LOG" 2>&1

# 日志只留最近 500 行
tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
