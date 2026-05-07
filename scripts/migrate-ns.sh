#!/usr/bin/env bash
#
# 阿里云 ACR 命名空间镜像迁移脚本
#
# 用法:
#   ./migrate-ns.sh <源命名空间> <目标命名空间> [--all | 镜像列表...]
#
# 示例:
#   ./migrate-ns.sh songxuan songxuan-new --all                       # 迁移整个源命名空间
#   ./migrate-ns.sh songxuan songxuan-new redis:latest mysql:8.0      # 只迁指定 image:tag
#   ./migrate-ns.sh songxuan songxuan-new redis                       # 迁 redis 仓库的所有 tag
#   ./migrate-ns.sh songxuan songxuan-new -j 8 redis mysql            # 并行 8
#
# 环境变量（可写到 .env，脚本会自动加载）:
#   ALIYUN_REGISTRY        必填，例如 registry.cn-hangzhou.aliyuncs.com
#   ALIYUN_ACCESS_KEY      仅在使用 --all 或不带 :tag 时需要（要列 repo / tag）
#   ALIYUN_ACCESS_SECRET   同上
#
# 前置依赖（不需要 Docker）:
#   brew install skopeo jq
#   curl -sSL -o /tmp/aliyun.tgz https://aliyuncli.alicdn.com/aliyun-cli-macosx-latest-amd64.tgz \
#     && tar -xzf /tmp/aliyun.tgz -C /tmp && sudo mv /tmp/aliyun /usr/local/bin/
#
# 登录（一次即可）:
#   skopeo login $ALIYUN_REGISTRY

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && set -a && . "$SCRIPT_DIR/.env" && set +a
[ -f "$SCRIPT_DIR/../.env" ] && set -a && . "$SCRIPT_DIR/../.env" && set +a

PARALLELISM=4
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -j) PARALLELISM="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \?//' | head -n -1; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [ ${#ARGS[@]} -lt 3 ]; then
  echo "用法: $0 <源命名空间> <目标命名空间> [--all | 镜像列表...]" >&2
  exit 1
fi

SRC_NS="${ARGS[0]}"
DST_NS="${ARGS[1]}"
TARGETS=("${ARGS[@]:2}")

: "${ALIYUN_REGISTRY:?需要设置 ALIYUN_REGISTRY 环境变量}"

command -v skopeo >/dev/null || { echo "❌ 未安装 skopeo（brew install skopeo）" >&2; exit 1; }
command -v jq >/dev/null || { echo "❌ 未安装 jq（brew install jq）" >&2; exit 1; }

needs_aliyun_cli=false
for t in "${TARGETS[@]}"; do
  if [ "$t" = "--all" ] || [[ "$t" != *:* ]]; then
    needs_aliyun_cli=true; break
  fi
done

CR_HELPER="$SCRIPT_DIR/aliyun_cr.py"
VENV_DIR="$SCRIPT_DIR/.venv"
VENV_PY="$VENV_DIR/bin/python3"

if $needs_aliyun_cli; then
  command -v python3 >/dev/null || { echo "❌ 需要 python3" >&2; exit 1; }
  [ -f "$CR_HELPER" ] || { echo "❌ 缺少 $CR_HELPER" >&2; exit 1; }
  : "${ALIYUN_ACCESS_KEY:?需要 ALIYUN_ACCESS_KEY}"
  : "${ALIYUN_ACCESS_SECRET:?需要 ALIYUN_ACCESS_SECRET}"

  if [ ! -x "$VENV_PY" ]; then
    echo "🔧 首次运行，创建 Python venv: $VENV_DIR"
    python3 -m venv "$VENV_DIR"
  fi

  REGION=$(echo "$ALIYUN_REGISTRY" | sed -nE 's/.*\.(cn-[a-z0-9-]+|[a-z]{2}-[a-z]+-[0-9]+)\..*/\1/p')
  [ -z "$REGION" ] && REGION="cn-hangzhou"
  export ALIYUN_REGION="$REGION"
  export ALIYUN_ACCESS_KEY ALIYUN_ACCESS_SECRET
fi

cr_api() {
  "$VENV_PY" "$CR_HELPER" GET "$1"
}

list_tags() {
  local ns="$1" repo="$2"
  cr_api "/repos/${ns}/${repo}/tags?PageSize=100" 2>/dev/null \
    | jq -r '.data.tags[]?.tag'
}

LIST_FILE=$(mktemp)
trap 'rm -f "$LIST_FILE"' EXIT

build_full_namespace() {
  echo "🔍 列出命名空间 $SRC_NS 下所有 repo + tag..." >&2
  local page=1
  while :; do
    local resp
    resp=$(cr_api "/repos/${SRC_NS}?Page=${page}&PageSize=100" 2>/dev/null) || break
    local repos
    repos=$(echo "$resp" | jq -r '.data.repos[]?.repoName')
    [ -z "$repos" ] && break
    while IFS= read -r repo; do
      while IFS= read -r tag; do
        [ -n "$tag" ] && echo "${repo}:${tag}"
      done < <(list_tags "$SRC_NS" "$repo")
    done <<< "$repos"
    local total
    total=$(echo "$resp" | jq -r '.data.total // 0')
    [ $((page * 100)) -ge "$total" ] && break
    page=$((page + 1))
  done
}

if [ "${TARGETS[0]:-}" = "--all" ]; then
  build_full_namespace > "$LIST_FILE"
else
  for entry in "${TARGETS[@]}"; do
    if [[ "$entry" == *:* ]]; then
      echo "$entry" >> "$LIST_FILE"
    else
      echo "🔍 列出 $entry 的所有 tag..." >&2
      while IFS= read -r tag; do
        [ -n "$tag" ] && echo "${entry}:${tag}" >> "$LIST_FILE"
      done < <(list_tags "$SRC_NS" "$entry")
    fi
  done
fi

COUNT=$(wc -l < "$LIST_FILE" | tr -d ' ')
if [ "$COUNT" -eq 0 ]; then
  echo "⚠️  空列表，无需迁移"
  exit 0
fi

echo "📋 共 ${COUNT} 个 image:tag 待迁移（${SRC_NS} -> ${DST_NS}, 并行 ${PARALLELISM}）："
cat "$LIST_FILE"
echo

migrate_one() {
  local entry="$1"
  local src="docker://${ALIYUN_REGISTRY}/${SRC_NS}/${entry}"
  local dst="docker://${ALIYUN_REGISTRY}/${DST_NS}/${entry}"
  echo "🚀 [start] ${entry}"
  if skopeo copy --all --retry-times 1 "$src" "$dst" 2>&1 | sed "s|^|    [${entry}] |"; then
    echo "✅ [done]  ${entry}"
  else
    echo "❌ [fail]  ${entry}"
    return 1
  fi
}
export -f migrate_one
export ALIYUN_REGISTRY SRC_NS DST_NS

xargs -P "$PARALLELISM" -I {} bash -c 'migrate_one "$@"' _ {} < "$LIST_FILE"
EXIT=$?

if [ "$EXIT" -eq 0 ]; then
  echo "🎉 全部迁移完成"
else
  echo "⚠️  迁移过程出现错误（exit=${EXIT}），请翻看上方日志中的 ❌ 条目或 xargs 报错"
fi
exit "$EXIT"
