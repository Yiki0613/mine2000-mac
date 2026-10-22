#!/bin/bash
# 构建 / 测试 / 打包 便捷脚本
#
# 用法：bash build.sh {build|test|app|icon|selftest|guiselftest|dumpui|verify|clean|all}
#
# 说明：
#   --disable-sandbox 是给「只装了 Command Line Tools、没有完整 Xcode」的机器用的。
#   本机 SwiftPM 的 manifest 沙箱（sandbox-exec）在受限环境下无法启动，会报
#   "sandbox_apply: Operation not permitted"。装了完整 Xcode 的机器加这个参数也无副作用。

set -euo pipefail
cd "$(dirname "$0")"

COMMON=(--disable-sandbox)

# 纯 Command Line Tools 环境需要显式挂 swift-testing 宏插件（见 Package.swift 注释）。
# 装了完整 Xcode 的机器（含 CI runner）**不能**挂：CLT 目录依然存在，但里面是旧版
# 插件的 dylib，塞给 Xcode 的 swift 前端会版本错配。所以按 xcode-select 实测判断。
if [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ]; then
  export MINE2000_CLT_TESTING_PLUGIN=1
fi

case "${1:-all}" in
  build)
    swift build "${COMMON[@]}"
    ;;
  test)
    swift test "${COMMON[@]}"
    ;;
  clean)
    rm -rf .build
    echo "已清理 .build"
    ;;
  app)
    # 生成可双击运行的 .app 壳（无需签名 / 完整 Xcode）
    # ⚠️ CFBundleName / CFBundleDisplayName = 「扫雷 2000」（正式名，见 L10n.appName）
    #    CFBundleExecutable 保持 Mine2000（与 SwiftPM 产物名一致，改了会找不到二进制）
    swift build -c release "${COMMON[@]}"
    APP=".build/Mine2000.app"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp .build/release/Mine2000 "$APP/Contents/MacOS/Mine2000"
    cp -R .build/release/Mine2000_Mine2000.bundle \
          "$APP/Contents/Resources/" 2>/dev/null || true
    # 应用图标（由 Tools/图标生成.swift 从图集真实像素绘制，见 Resources/README.md）
    if [ -f Resources/AppIcon.icns ]; then
      cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    else
      echo "  ⚠️ 缺少 Resources/AppIcon.icns（图标将使用系统默认）" >&2
    fi
    cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Mine2000</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>io.github.yiki0613.mine2000</string>
  <key>CFBundleName</key><string>扫雷 2000</string>
  <key>CFBundleDisplayName</key><string>扫雷 2000</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
    echo "已生成 $APP"
    echo "运行： open $APP"
    ;;
  icon)
    # 从图集真实像素重新生成 AppIcon.icns（改配色/构图后跑这个）
    swiftc -O Tools/图标生成.swift -o /tmp/mine2000_icon_gen
    rm -rf /tmp/AppIcon.iconset && mkdir -p /tmp/AppIcon.iconset
    for pair in "icon_16x16.png 16" "icon_16x16@2x.png 32" \
                "icon_32x32.png 32" "icon_32x32@2x.png 64" \
                "icon_128x128.png 128" "icon_128x128@2x.png 256" \
                "icon_256x256.png 256" "icon_256x256@2x.png 512" \
                "icon_512x512.png 512" "icon_512x512@2x.png 1024"; do
      set -- $pair
      /tmp/mine2000_icon_gen "/tmp/AppIcon.iconset/$1" "$2" >/dev/null
    done
    iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
    echo "已生成 Resources/AppIcon.icns"
    ;;
  selftest)
    # 逻辑层端到端自检（46 项）
    swift build "${COMMON[@]}"
    ./.build/debug/Mine2000 --selftest /tmp/mine2000_selftest.txt
    ;;
  guiselftest)
    # GUI 层端到端自检（16 项）：真实鼠标事件 + 离屏渲染 + 逐像素比对
    swift build "${COMMON[@]}"
    ./.build/debug/Mine2000 --gui-selftest /tmp/mine2000_gui_selftest
    ;;
  dumpui)
    # 导出全部用户可见界面文案（核对本地化是否彻底）
    swift build "${COMMON[@]}"
    ./.build/debug/Mine2000 --dump-ui /tmp/mine2000_ui.txt
    ;;
  verify)
    # 全量验证：单元测试 + 逻辑自检 + GUI 自检
    swift build "${COMMON[@]}"
    swift test "${COMMON[@]}"
    ./.build/debug/Mine2000 --selftest /tmp/mine2000_selftest.txt
    ./.build/debug/Mine2000 --gui-selftest /tmp/mine2000_gui_selftest
    echo ""
    echo "✅ 全部验证通过：单元测试 + 逻辑自检 + GUI 自检"
    ;;
  all)
    swift build "${COMMON[@]}"
    swift test "${COMMON[@]}"
    ;;
  *)
    echo "用法: $0 {build|test|app|icon|selftest|guiselftest|dumpui|verify|clean|all}" >&2
    exit 1
    ;;
esac
