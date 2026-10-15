#!/usr/bin/env bash
#
# 清理 macOS TCC（Transparency, Consent, and Control / 隐私数据库）里
# 存放的 WhisperCaption 旧权限条目。
#
# 为什么需要这个脚本？
# -------------------------------------------------------------------
# macOS 把"你同意过的权限"按 (bundle_id + cdhash) 的组合记录在 TCC 里。
# 每次重新构建、重新签名 app，cdhash 都会变。于是「系统设置 → 隐私与安全
# → 屏幕录制 / 麦克风」里虽然还勾着一条 WhisperCaption，但那条绑定的是
# 旧 cdhash；新构建的 app 对不上，就表现为「我已经授权了，但是打开 app
# 还让我去授权」的死循环。
#
# 这个脚本做的事情非常简单：把 TCC 里关于 albond.WhisperCaption 的
# 所有历史条目一次性清掉。下次启动 app 时，macOS 会弹出全新的授权请求，
# 新 cdhash 被记入 TCC，权限就能真正生效了。
#
# 用法：
#   ./scripts/reset-permissions.sh
#
# 执行后，请按下列顺序操作：
#   1. 完全退出 app（⌘Q 或 Dock 右键 → 退出）
#   2. 重新启动 app
#   3. 点 Start，弹出的新权限请求选"允许"
#   4. 如果提示要重启 app，退出后再启动一次

set -euo pipefail

BUNDLE_ID="albond.WhisperCaption"

echo "==> 正在清理 TCC 里关于 $BUNDLE_ID 的权限条目 …"
echo

# 屏幕录制（含系统音频捕获，macOS 15+ 把两者合并到同一个 pane）
echo "[1/2] 清理 Screen Recording …"
tccutil reset ScreenCapture "$BUNDLE_ID" || true

# 麦克风
echo "[2/2] 清理 Microphone …"
tccutil reset Microphone "$BUNDLE_ID" || true

echo
echo "==> 完成。接下来请手动做下面这些事："
echo
echo "    1. 彻底退出 WhisperCaption（⌘Q）"
echo "    2. 重新从 Launchpad / Spotlight 启动 app"
echo "    3. 点 Start，弹出的新权限对话框选【允许】"
echo "    4. 如果系统提示需要重启 app 才能生效，照做"
echo
echo "小贴士：如果你同时装了多份不同后缀的 WhisperCaption-xxx.app，"
echo "       它们共用同一个 bundle id (albond.WhisperCaption)，这次"
echo "       清理会影响到所有版本——重新授权一次即可。"
