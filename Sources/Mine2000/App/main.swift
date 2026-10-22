import AppKit

// 应用入口。
//
// 说明：使用 `NSApplicationMain` 的手动装配方式（而非 @main + SwiftUI App），
// 以便完全掌控菜单栏结构（对齐原版的日文菜单）。

// ── GUI 层端到端自检模式 ──
// `swift run Mine2000 --gui-selftest [输出目录]`
// 真实创建视图 + 真实鼠标事件 + 离屏渲染 + 像素分析，验证「点击→状态→画面」整条链路。
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--gui-selftest" {
    let output = CommandLine.arguments.count > 2
        ? URL(fileURLWithPath: CommandLine.arguments[2])
        : URL(fileURLWithPath: "/tmp/mine2000_gui_selftest")
    let ok = GuiSelfTest.run(outputDirectory: output)
    exit(ok ? 0 : 1)
}

// ── 界面文案清单模式 ──
// `swift run Mine2000 --dump-ui [输出文件路径]`
// 导出全部**用户可见**文案，用于核对本地化是否彻底（只列真正显示出来的，零噪声）。
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--dump-ui" {
    let output = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/mine2000_ui.txt"
    let clean = UIDump.dump(outputPath: output)
    exit(clean ? 0 : 1)
}

// ── 端到端自检模式 ──
// `swift run Mine2000 --selftest [输出文件路径]`
// 跑完整一局游戏（首点保护→flood fill→插旗→chording→失败→胜利→计时冻结→高分榜入榜），
// 逐项断言并把结果写入文件。
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--selftest" {
    let output = CommandLine.arguments.count > 2
        ? CommandLine.arguments[2]
        : "/tmp/mine2000_selftest.txt"
    let allPassed = EndToEndSelfTest.run(outputPath: output)
    exit(allPassed ? 0 : 1)
}

// ── 离屏渲染模式 ──
// `swift run Mine2000 --render-snapshots [输出目录]`
// 用于视觉验证：不弹窗，直接把各难度棋盘渲染成 PNG。
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--render-snapshots" {
    let output = CommandLine.arguments.count > 2
        ? URL(fileURLWithPath: CommandLine.arguments[2])
        : RenderSnapshots.defaultOutputDirectory
    do {
        try RenderSnapshots.renderAll(to: output)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("渲染失败：\(error)\n".utf8))
        exit(1)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
