#!/usr/bin/env bash
#
# WhisperCaption 本地卸载脚本（与 install-local.sh 对称）
#
# 用法：
#   ./scripts/uninstall-local.sh                   # 默认仅删除 /Applications 下带默认后缀的 app
#   ./scripts/uninstall-local.sh <suffix>          # 指定后缀：如 dev 则卸载 WhisperCaption-dev.app
#   ./scripts/uninstall-local.sh <suffix> --build  # 同时清理项目下的 build-local/ 构建缓存
#   ./scripts/uninstall-local.sh <suffix> --data   # 同时清理用户数据（聊天历史 + 设置 + 日志）
#   ./scripts/uninstall-local.sh <suffix> --all    # 全清（app + 构建缓存 + 用户数据 + DerivedData）
#
# 示例：
#   ./scripts/uninstall-local.sh                   # 只删 /Applications/WhisperCaption-shea.app
#   ./scripts/uninstall-local.sh shea --build      # 顺带清 build-local/
#   ./scripts/uninstall-local.sh shea --all        # 彻底清干净（会二次确认）
#
# 注意：
#   - 删除 app 本身只会移除启动入口，聊天历史与设置仍然保留，下次安装自动恢复。
#   - --data / --all 会**不可逆**地删除所有聊天记录与截图，请谨慎使用。
#   - Keychain 中保存的 API Key（Deepgram / ElevenLabs）不会被自动删除，
#     如需清理请到「钥匙串访问.app」中搜索 WhisperCaption 手动移除。

set -euo pipefail

# ---- 解析参数 ----
# 第一个非选项参数视为后缀，默认 "shea"（与 install-local.sh 保持一致）
SUFFIX="shea"
CLEAN_BUILD=0   # 是否清理项目构建缓存
CLEAN_DATA=0    # 是否清理用户数据（聊天历史 + 偏好设置）
CLEAN_DERIVED=0 # 是否清理 Xcode DerivedData

for arg in "$@"; do
  case "$arg" in
    --build)   CLEAN_BUILD=1 ;;
    --data)    CLEAN_DATA=1 ;;
    --all)     CLEAN_BUILD=1; CLEAN_DATA=1; CLEAN_DERIVED=1 ;;
    --help|-h)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    -*)
      echo "未知参数：$arg" >&2
      exit 2
      ;;
    *)
      SUFFIX="$arg"
      ;;
  esac
done

# ---- 路径计算 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET_NAME="WhisperCaption-${SUFFIX}.app"
TARGET_APP="/Applications/$TARGET_NAME"
APP_DISPLAY_NAME="${TARGET_NAME%.app}"

BUILD_DIR="$ROOT/build-local"
# Bundle ID 来自 Xcode 项目配置，用于定位用户偏好和缓存
BUNDLE_ID="com.albond.WhisperCaption"
APP_SUPPORT_DIR="$HOME/Library/Application Support/WhisperCaption"
PREFS_PLIST="$HOME/Library/Preferences/${BUNDLE_ID}.plist"
CACHES_DIR="$HOME/Library/Caches/${BUNDLE_ID}"
LOGS_DIR="$HOME/Library/Logs/WhisperCaption"
DERIVED_DATA_PATTERN="$HOME/Library/Developer/Xcode/DerivedData/WhisperCaption-*"

# ---- 预览将执行的操作 ----
echo "==> 卸载计划"
echo "    删除 app:            $TARGET_APP"
[[ "$CLEAN_BUILD" == "1" ]]   && echo "    删除构建缓存:        $BUILD_DIR"
[[ "$CLEAN_DERIVED" == "1" ]] && echo "    删除 DerivedData:    $DERIVED_DATA_PATTERN"
if [[ "$CLEAN_DATA" == "1" ]]; then
  echo "    删除聊天历史与截图:  $APP_SUPPORT_DIR"
  echo "    删除偏好设置:        $PREFS_PLIST"
  echo "    删除缓存:            $CACHES_DIR"
  echo "    删除日志:            $LOGS_DIR"
fi
echo

# ---- 用户数据属于不可逆操作，二次确认 ----
if [[ "$CLEAN_DATA" == "1" ]]; then
  echo "⚠️  即将删除所有聊天记录、截图与设置，此操作不可恢复！"
  read -r -p "    确认继续？输入 YES 继续，其它任意键取消：" ANSWER
  if [[ "$ANSWER" != "YES" ]]; then
    echo "已取消。"
    exit 0
  fi
  echo
fi

# ---- 1. 先退出正在运行的实例，避免「文件被占用」问题 ----
echo "==> 退出正在运行的 $APP_DISPLAY_NAME …"
osascript -e "tell application \"$APP_DISPLAY_NAME\" to quit" 2>/dev/null || true
# 顺带退出无后缀的原版，防止并发冲突
osascript -e 'tell application "WhisperCaption" to quit' 2>/dev/null || true
sleep 1

# ---- 2. 删除 /Applications 下的 app ----
if [[ -d "$TARGET_APP" ]]; then
  echo "==> 删除 $TARGET_APP …"
  rm -rf "$TARGET_APP"
else
  echo "==> $TARGET_APP 不存在，跳过。"
fi

# ---- 3. 清理项目下的构建缓存 ----
if [[ "$CLEAN_BUILD" == "1" ]]; then
  if [[ -d "$BUILD_DIR" ]]; then
    echo "==> 删除构建缓存 $BUILD_DIR …"
    rm -rf "$BUILD_DIR"
  else
    echo "==> 构建缓存目录不存在，跳过。"
  fi
fi

# ---- 4. 清理 Xcode DerivedData（会强制下次用 Xcode 开时重新索引） ----
if [[ "$CLEAN_DERIVED" == "1" ]]; then
  # 用 glob 展开，可能匹配到 0 个或多个目录
  shopt -s nullglob
  derived_dirs=( $DERIVED_DATA_PATTERN )
  shopt -u nullglob
  if (( ${#derived_dirs[@]} > 0 )); then
    for d in "${derived_dirs[@]}"; do
      echo "==> 删除 DerivedData $d …"
      rm -rf "$d"
    done
  else
    echo "==> 没有找到 WhisperCaption 的 DerivedData，跳过。"
  fi
fi

# ---- 5. 清理用户数据（聊天历史、偏好、缓存、日志） ----
if [[ "$CLEAN_DATA" == "1" ]]; then
  # 聊天历史与截图
  if [[ -d "$APP_SUPPORT_DIR" ]]; then
    echo "==> 删除聊天历史 $APP_SUPPORT_DIR …"
    rm -rf "$APP_SUPPORT_DIR"
  fi

  # 偏好设置：先用 defaults delete 清掉内存中缓存，再删 plist 文件
  echo "==> 清理偏好设置 $BUNDLE_ID …"
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  rm -f "$PREFS_PLIST"

  # 缓存
  if [[ -d "$CACHES_DIR" ]]; then
    echo "==> 删除缓存 $CACHES_DIR …"
    rm -rf "$CACHES_DIR"
  fi

  # 日志
  if [[ -d "$LOGS_DIR" ]]; then
    echo "==> 删除日志 $LOGS_DIR …"
    rm -rf "$LOGS_DIR"
  fi

  echo
  echo "⚠️  Keychain 中可能仍保存着 Deepgram / ElevenLabs 的 API Key。"
  echo "    如需清理，请打开「钥匙串访问.app」，搜索 \"WhisperCaption\" 后手动删除。"
fi

echo
echo "==> 卸载完成。"
if [[ "$CLEAN_DATA" != "1" ]]; then
  echo "    聊天记录与设置仍然保留，重新安装后可继续使用。"
  echo "    若要彻底清理，请加 --data 或 --all 重新运行。"
fi
