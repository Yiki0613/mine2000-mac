// swift-tools-version:6.0
import PackageDescription
import Foundation

// 说明：
// 本机只有 CommandLineTools，没有完整 Xcode，**XCTest.framework 不可用**
// （`find /Library/Developer -name XCTest.framework` 无结果），
// 但 Swift 6.4 工具链自带 swift-testing（`Testing.framework`），
// 因此测试目标改用 `import Testing`（swift-testing）而非 XCTest。
//
// ⚠️ 关键约束（实测踩坑，勿改）：
// `.swiftLanguageMode(.v5)` 会把该 target 的部署目标降级到 macOS 12，
// 而 swift-testing 要求 macOS 14+。一旦低于 14，SwiftPM **不会**把
// `CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`
// 传给 swift-frontend，结果是：
//   error: external macro implementation type 'TestingMacros.TestDeclarationMacro'
//          could not be found for macro 'Test'
// 测试 target 必须使用 Swift 6 语言模式（.v6）。
//
// ⚠️ 第二个坑（更隐蔽，**间歇性**出现，务必保留下面的 -load-plugin-library）：
// 即便语言模式是 .v6、部署目标是 macOS 14，SwiftPM **仍然会间歇性地**
// 漏掉 `-load-resolved-plugin .../testing/libTestingMacros.dylib`，
// 导致同样的报错。实测：同一份代码、不改任何文件，连续 `swift test`
// 有时成功有时失败（与 .build 缓存状态、并发运行的 swift 进程均相关，
// 在完全隔离的副本树上也能复现）。
// 原因未查明（疑似 SwiftPM 6.4 的插件解析时序问题），但绕过办法稳定有效：
// 在测试 target 的 swiftSettings 里**显式**用 `-load-plugin-library`
// 把 swift-testing 的宏插件 dylib 直接挂上。实测加固后连续 5 次
// `rm -rf .build && swift test` 全部通过（加固前 4 次里 3 次失败）。
//
// 另：在受限沙箱环境下 `swift build` / `swift test` 会报
//   sandbox-exec: sandbox_apply: Operation not permitted
// 需加 `--disable-sandbox` 参数（见 README）。

// ── swift-testing 宏插件的显式注入（**按需生效，不写死绝对路径**）──
//
// 上面第二个坑的绕过办法是 `-load-plugin-library` 指向 swift-testing 的宏插件
// dylib。但不同机器上这个 dylib 的位置不同：
//   · 只有 Command Line Tools：/Library/Developer/CommandLineTools/usr/lib/...
//   · 装了完整 Xcode：          /Applications/Xcode.app/Contents/Developer/...
// 而且**不能写死**——写死会让别人 clone 下来直接编译失败（CI 上同样必挂）。
// 因此这里先探测文件是否存在，存在才注入；装了完整 Xcode 的机器本来就不需要它。
let cltTestingPlugin =
    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let needsTestingPluginOverride = FileManager.default.fileExists(atPath: cltTestingPlugin)

var testSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
if needsTestingPluginOverride {
    testSwiftSettings.append(
        .unsafeFlags(["-load-plugin-library", cltTestingPlugin])
    )
}

let package = Package(
    name: "Mine2000",
    platforms: [
        // swift-testing 的最低部署目标是 macOS 14
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Mine2000", targets: ["Mine2000"]),
    ],
    targets: [
        // 应用层：App/ + View/ + Model/ + Resources/
        // Model/ 内部不 import AppKit，因此可被测试目标直接引用做单测。
        .executableTarget(
            name: "Mine2000",
            path: "Sources/Mine2000",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "Mine2000Tests",
            dependencies: ["Mine2000"],
            path: "Tests/Mine2000Tests",
            // 必须 Swift 6 模式，否则 swift-testing 宏插件不会被加载（见文件头说明）
            // 宏插件按需注入（只有纯 CLT 环境才需要），见上方 needsTestingPluginOverride
            swiftSettings: testSwiftSettings
        ),
    ]
)
