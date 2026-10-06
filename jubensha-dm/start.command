#!/bin/bash
# Double-click in Finder to build (when needed) and open the native Mac app.
set -euo pipefail
cd "$(dirname "$0")"

on_error() {
  local status="$?"
  echo
  echo "启动失败。请查看上方错误信息。"
  if [ -t 0 ]; then read -r -p "按回车关闭此窗口……" || true; fi
  exit "$status"
}
trap on_error ERR

APP="$PWD/build/AI 剧本杀.app"
BIN="$APP/Contents/MacOS/AIDM"
NEEDS_BUILD=false
if [ ! -x "$BIN" ] || [ ! -f "$APP/Contents/Info.plist" ]; then
  NEEDS_BUILD=true
else
  for input in build.sh Package.swift Package.resolved; do
    if [ "$input" -nt "$BIN" ]; then NEEDS_BUILD=true; fi
  done
  if [ -n "$(find Sources Resources -type f -newer "$BIN" -print -quit)" ]; then
    NEEDS_BUILD=true
  fi
fi

if [ "$NEEDS_BUILD" = true ]; then
  echo "正在编译 Mac 应用；首次编译需要网络下载依赖。"
  bash build.sh
fi

open "$APP"
echo "AI 剧本杀已打开。此终端窗口可以关闭。"
