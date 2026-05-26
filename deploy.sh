#!/usr/bin/env bash
# 一键部署:自动 export → 提交 → 推送 → 服务器 pull → import → 重启
# 用法:./deploy.sh
#
# 智能跳过:如果 client/server/shared/assets/... 都没改过,跳过 export 步骤,
# 整个流程几秒钟。改了任何源文件就自动重新 export(约 30-60 秒)。

set -e

cd "$(dirname "$0")"

# ---- 配置(改服务器时改这里) ----
SERVER_HOST="${PVP_SERVER_HOST:-root@207.148.98.206}"
SERVER_PATH="${PVP_SERVER_PATH:-/opt/games/godot-pvp}"
SERVICE_NAME="godot-pvp-game"
PUBLIC_URL="https://game.boobank.com/godot-pvp/"

# ---- 1. 找 Godot 二进制 ----
if [ -n "$GODOT_BIN" ] && [ -x "$GODOT_BIN" ]; then
  : # 用环境变量
else
  CANDIDATES=(
    "/Applications/Godot.app/Contents/MacOS/Godot"
    "$HOME/Applications/Godot.app/Contents/MacOS/Godot"
    "$HOME/Downloads/Godot.app/Contents/MacOS/Godot"
    "$HOME/Desktop/Godot.app/Contents/MacOS/Godot"
  )
  GODOT_BIN=""
  for c in "${CANDIDATES[@]}"; do
    if [ -x "$c" ]; then GODOT_BIN="$c"; break; fi
  done
  if [ -z "$GODOT_BIN" ]; then
    APP=$(mdfind "kMDItemFSName == 'Godot.app'" 2>/dev/null | head -1)
    [ -n "$APP" ] && [ -x "$APP/Contents/MacOS/Godot" ] && GODOT_BIN="$APP/Contents/MacOS/Godot"
  fi
fi

if [ -z "$GODOT_BIN" ] || [ ! -x "$GODOT_BIN" ]; then
  echo "❌ Godot 找不到。请装到 /Applications 或 ~/Downloads,或 export GODOT_BIN=/path/to/Godot"
  exit 1
fi

# ---- 2. 判断需不需要重新 export ----
NEED_EXPORT=0
REASON=""
if [ ! -f docs/index.pck ] || [ ! -f docs/index.wasm ]; then
  NEED_EXPORT=1
  REASON="docs/ 不完整"
else
  # 找比 docs/index.pck 新的源文件(说明改过代码 / 资源)
  NEWER=$(find client server shared assets addons project.godot server.json \
    -newer docs/index.pck 2>/dev/null | head -3)
  if [ -n "$NEWER" ]; then
    NEED_EXPORT=1
    REASON="检测到源文件变更:"$'\n'"$NEWER"
  fi
fi

# ---- 3. 自动 export(如果需要) ----
if [ "$NEED_EXPORT" = "1" ]; then
  echo "📦 需要重新 export:$REASON"
  echo "→ 清理旧编译缓存..."
  # 清掉 .godot/exported,否则 Godot 可能复用旧的 .gdc 编译产物
  rm -rf .godot/exported

  echo "→ Godot 导出 Web 构建(约 30-60 秒)..."
  "$GODOT_BIN" --headless --path . --export-release "Web" docs/index.html 2>&1 | tail -5

  # 清掉 docs/ 里的 .import 编辑器残留(它们只是元数据,不该 commit)
  find docs -name "*.import" -delete 2>/dev/null || true
  # 同步 server.json 到 docs/(Caddy 同源 fetch 用)
  cp server.json docs/server.json
  echo "✓ Export 完成"
  echo ""
else
  echo "✓ docs/ 已是最新,跳过 export"
  echo ""
fi

# ---- 3.5 brotli 预压缩 pck 给 Caddy precompressed 用 ----
# Caddy 配的 file_server.precompressed 会在客户端 Accept-Encoding: br 时
# 优先 serve `<file>.br`,跳过现场压缩。pck 从 15MB → 2.5MB,首页下载量
# 直接腰斩。.br 文件 .gitignore 掉,VPS 那边在 import 后自己压(VPS 有
# brotli CLI)。本地这步是冗余但留着方便本地调试 web 包大小。
if command -v brotli >/dev/null 2>&1; then
  echo "→ 本地预压缩 docs/index.pck (brotli q8)..."
  brotli -q 8 -f docs/index.pck -o docs/index.pck.br
  ls -lh docs/index.pck docs/index.pck.br | awk '{printf "  %s  %s\n", $5, $9}'
fi

# ---- 4. git 检查 + commit ----
if [ ! -d .git ]; then
  echo "⚠️  这个项目还没用 git 初始化。"
  exit 1
fi

git add docs/ export_presets.cfg server.json .gitignore 2>/dev/null || true
if git diff --cached --quiet; then
  echo "(docs/ 没有变化,跳过 commit)"
else
  git commit -m "Build $(date '+%Y-%m-%d %H:%M')"
fi

# ---- 5. 推到 GitHub ----
echo ""
echo "→ 推送到 GitHub..."
git push

# ---- 6. 通知服务器:pull + import + restart ----
echo ""
echo "→ 通知服务器拉取、import、重启 ..."
ssh "$SERVER_HOST" "cd '$SERVER_PATH' \
  && git pull --rebase \
  && godot --headless --path . --import 2>&1 | tail -3 \
  && brotli -q 11 -f docs/index.pck -o docs/index.pck.br \
  && brotli -q 11 -f docs/index.wasm -o docs/index.wasm.br \
  && sudo systemctl restart $SERVICE_NAME"

# ---- 7. done ----
echo ""
echo "✅ 部署完成,立即生效:"
echo "   $PUBLIC_URL"
echo "   (玩家硬刷新 Cmd/Ctrl+Shift+R 看新版本)"
