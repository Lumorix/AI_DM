#!/bin/bash
# 编译并打包成 Mac 应用：build/AI 剧本杀.app
# 只需要 Xcode 命令行工具（xcode-select --install），不需要完整的 Xcode。
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/AI 剧本杀.app"

echo "▸ 编译（$CONFIG）……"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/AIDM"

echo "▸ 打包 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AIDM"
cp -R Resources/web Resources/Demo Resources/live2d "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AIDM</string>
  <key>CFBundleIdentifier</key><string>com.lumorix.aidm</string>
  <key>CFBundleName</key><string>AI 剧本杀</string>
  <key>CFBundleDisplayName</key><string>AI 剧本杀</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.board-games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>玩家的手机需要通过局域网连接到这台电脑；接本地或局域网里的 AI 模型也需要。</string>
</dict>
</plist>
PLIST

# 本机自签名（不需要开发者账号）
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ 完成：$APP"
echo "  打开：open \"$APP\"    或者拖进“应用程序”文件夹"
