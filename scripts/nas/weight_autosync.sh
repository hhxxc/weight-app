#!/bin/sh
# weight-app 自动同步：定时从 GitHub Releases 拉最新 IPA → 刷新 nestkeep 清单
#
# 与同目录 trilium_autosync.sh 同一模式：CI 每次构建发 `gh release create vX.Y.Z weight-app.ipa`，
# 这里把它自动拉到 NAS 的 nestkeep 分发目录（与巢记共用，路由 *.ipa 通配放行，无需改后端）。
#
# ★ 刻意不走 GitHub API（NAS 出口 IP 匿名调 API 常年 403 限流），改用永久地址：
#     GET /releases/latest/download/weight-app.ipa → 直接下到最新资产（302 跟随）
#
# 手动检查： sh /volume2/docker/ezbk/weight_autosync.sh && tail weight_autosync.log
#
set -u

REPO="${WEIGHT_REPO:-hhxxc/weight-app}"
DATA_DIR="${WEIGHT_DATA_DIR:-/volume2/docker/ezbk/nestkeep}"
STATE_DIR="${WEIGHT_STATE_DIR:-/volume2/docker/ezbk}"
DIGEST_FILE="$STATE_DIR/.weight_autosync_last_tag"
LOG="$STATE_DIR/weight_autosync.log"
LOCK="$STATE_DIR/.weight_autosync.lock"
IPA_NAME="weight-app.ipa"
MANIFEST="manifest-weight.ipa"
ASSET_URL="https://github.com/${REPO}/releases/latest/download/${IPA_NAME}"
PUBLIC_BASE="${WEIGHT_PUBLIC_BASE:-https://ezbookx.x.ddnsto.com/api/nestkeep}"
KEEP_IPA="${WEIGHT_KEEP_IPA:-5}"

ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $1" >> "$LOG"; }

# 单实例：上一次没跑完就跳过本轮
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

mkdir -p "$DATA_DIR" "$STATE_DIR"

# 1. 取最新 tag：HEAD 不跟随重定向，从 Location 头解析
LOC=$(curl -sI -m 30 -H "User-Agent: weight-autosync" "$ASSET_URL" 2>/dev/null \
      | grep -i '^location:' | tr -d '\r' | sed 's/^[Ll]ocation: *//')

REMOTE_TAG=$(echo "$LOC" | sed -n 's#.*/releases/download/\([^/]*\)/.*#\1#p')
REMOTE_VER=$(echo "$REMOTE_TAG" | sed 's/^v//')

if [ -z "$REMOTE_TAG" ]; then
    log "WARN: 查询 GitHub Releases 失败，跳过本次"
    exit 0
fi

# 2. 与基线比对
LAST=""
[ -f "$DIGEST_FILE" ] && LAST=$(cat "$DIGEST_FILE" 2>/dev/null || echo "")

if [ "$REMOTE_TAG" = "$LAST" ] && [ -f "$DATA_DIR/$IPA_NAME" ]; then
    exit 0
fi

[ -z "$LAST" ] && log "初始化：最新 release $REMOTE_TAG，开始首次拉取" \
              || log "发现新版本：$REMOTE_TAG（旧：$LAST），开始同步"

# 3. 下载 IPA（国内直连 release-assets 可能慢，给足超时并重试 3 次）
TMP_IPA="$DATA_DIR/.${IPA_NAME}.tmp"
dl_ok=0
for try in 1 2 3; do
    if curl -sL -m 240 -H "User-Agent: weight-autosync" -o "$TMP_IPA" "$ASSET_URL" 2>/dev/null; then
        if head -c 2 "$TMP_IPA" 2>/dev/null | grep -q "PK"; then
            dl_ok=1
            break
        fi
    fi
    log "WARN: 第 $try 次下载失败，重试"
    sleep 5
done

if [ "$dl_ok" -ne 1 ]; then
    rm -f "$TMP_IPA"
    log "FAIL: IPA 下载失败（3 次重试均未成功）"
    exit 1
fi

# 4. 落地：IPA 就位 + 刷新清单（原子替换，避免半截文件被下载到）
mv -f "$TMP_IPA" "$DATA_DIR/$IPA_NAME"
chmod 644 "$DATA_DIR/$IPA_NAME" 2>/dev/null

# 留一份带版本号的副本，便于回滚与审计
cp -f "$DATA_DIR/$IPA_NAME" "$DATA_DIR/weight-app-${REMOTE_TAG}.ipa" 2>/dev/null

# manifest 用 .ipa 后缀（绕开后端对 application/json 的强制 JSON 解析坑），
# 内容仍是 JSON：App 端按字节解码
TMP_MAN="$DATA_DIR/.${MANIFEST}.tmp"
printf '{"version": "%s", "ipaUrl": "%s/%s", "releaseUrl": "https://github.com/%s/releases/tag/v%s"}\n' \
    "$REMOTE_VER" "$PUBLIC_BASE" "$IPA_NAME" "$REPO" "$REMOTE_VER" > "$TMP_MAN"
mv -f "$TMP_MAN" "$DATA_DIR/$MANIFEST"
chmod 644 "$DATA_DIR/$MANIFEST" 2>/dev/null

# 5. 清理：只保留最近 N 个带版本号的副本（weight-app.ipa 固定名不动）
ls -t "$DATA_DIR"/weight-app-v*.ipa 2>/dev/null | tail -n +$((KEEP_IPA + 1)) | xargs -r rm -f

# 6. 完成
echo "$REMOTE_TAG" > "$DIGEST_FILE"
log "同步完成：$REMOTE_TAG → $DATA_DIR/$IPA_NAME（$(wc -c < "$DATA_DIR/$IPA_NAME") 字节），清单 version=$REMOTE_VER"

# 日志只留最近 500 行
tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
