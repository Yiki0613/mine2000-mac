import AppKit
import Foundation

/// 界面文案清单导出（诊断工具）。
///
/// ## 用途
///
/// 1. **核对本地化是否彻底**：一键列出**所有用户可见的文案**，
///    人工扫一眼就知道还有没有漏改的日文/英文残留。
/// 2. **改文案后 diff**：改前改后各跑一次，输出即可对比。
///
/// ## 为什么不用「扫源码里的字符串字面量」
///
/// 因为源码里**故意保留**了大量原版日文（`L10n.*Original`、
/// `Difficulty.menuTitleOriginal`、测试里的还原度断言），
/// 扫字面量必然有噪声，无法区分「漏改」与「有意保留」。
///
/// 本工具只导出**真正会被显示出来**的文案，噪声为零。
///
/// ## 用法
///
/// ```
/// swift run Mine2000 --dump-ui [输出文件路径]
/// ```
///
/// 默认输出到 `/tmp/mine2000_ui.txt`。
public enum UIDump {

    /// 导出全部用户可见文案。
    ///
    /// - Parameter outputPath: 输出文件路径。
    /// - Returns: 是否成功。
    @discardableResult
    static func dump(outputPath: String = "/tmp/mine2000_ui.txt") -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = AppDelegate()
        let menu = delegate.buildMenu()

        var lines: [String] = []
        lines.append("=== 用户可见文案清单 ===")
        lines.append("")

        // ── 菜单栏 ──
        lines.append("[菜单栏]")
        for (i, item) in menu.items.enumerated() {
            let isAppMenu = (i == 0)
            let tag = isAppMenu ? "App 菜单" : "顶级菜单"
            lines.append("  \(tag) 「\(item.title)」")
            if let sub = item.submenu {
                for child in sub.items {
                    if child.isSeparatorItem {
                        lines.append("      ────────")
                        continue
                    }
                    let accel = describeAccel(child)
                    let tagInfo = child.tag == 0 ? "" : "  [原版 tag \(child.tag)]"
                    lines.append("      • \(child.title)\(accel)\(tagInfo)")
                    if let subsub = child.submenu {
                        for grand in subsub.items {
                            if grand.isSeparatorItem {
                                lines.append("          ────────")
                                continue
                            }
                            let ga = describeAccel(grand)
                            let gt = grand.tag == 0 ? "" : "  [原版 tag \(grand.tag)]"
                            lines.append("          - \(grand.title)\(ga)\(gt)")
                        }
                    }
                }
            }
        }
        lines.append("")

        // ── 窗口标题 ──
        lines.append("[窗口标题]")
        lines.append("  主窗口：\(L10n.appName)")
        lines.append("  最高分窗口：\(L10n.highScoreMenu)")
        lines.append("")

        // ── 弹窗与对话框 ──
        lines.append("[弹窗 / 对话框]")
        lines.append("  入榜提示：\(L10n.rankInMessage(rank: 1))")
        lines.append("  名字输入提示：\(L10n.enterNamePrompt)")
        lines.append("  名字占位符：\(L10n.anonymousName)")
        lines.append("  按钮：\(L10n.ok) / \(L10n.cancel)")
        lines.append("  导入对话框：\(L10n.importFilePrompt)")
        lines.append("  导出对话框：\(L10n.exportFilePrompt)")
        lines.append("  导入失败：\(L10n.importFailed)")
        lines.append("  导出失败：\(L10n.exportFailed)")
        lines.append("  导出降级提示：\(L10n.exportDowngradeNotice)")
        lines.append("")

        // ── 成绩显示 ──
        lines.append("[成绩显示]")
        lines.append("  计分格式：\(L10n.scoreFormat)   例：\(ScoreFormat.format(deciseconds: 1234))")
        lines.append("")

        // ── 最高分窗口正文 ──
        // ⚠️ 必须列出**完整正文**（含名字与成绩），不能只列节标题。
        //    早前只列了节标题，于是最高分窗口里漏出的日文默认名「名前なし」
        //    从未被这份清单抓到 —— 用户实测时才发现的。
        lines.append("[最高分窗口正文]")
        for line in HighScoreWindowController.renderText(HighScoreTable()).split(separator: "\n") {
            lines.append("  \(line)")
        }
        lines.append("")

        // ── 难度（用户看到的部分）──
        lines.append("[难度 · 用户看到]")
        for difficulty in Difficulty.allCases {
            lines.append("  \(difficulty.menuTitleWithScale)")
        }
        lines.append("")

        // ── 难度（原版对照 · **不显示给用户**）──
        // 单独列出并**排除在残留检查之外**：
        // 这里故意保留日文，是为了还原度可反查，不是界面文案。
        var reference: [String] = []
        reference.append("[难度 · 原版对照（不显示，仅供反查）]")
        for difficulty in Difficulty.allCases {
            reference.append("  \(difficulty.menuTitleOriginal)  →  \(difficulty.menuTitle)")
        }
        reference.append("")

        // ── 残留检查 ──
        let all = lines.joined(separator: "\n")
        // ⚠️ 残留检查**只针对「用户实际看到」的部分**（`lines`），
        //    不含上面的原版对照区（`reference`）——
        //    对照区故意保留日文（mania 等），算进去会误报。
        let visible = lines.joined(separator: "\n")
        // ⚠️ 判定口径：**只数假名**（平假名/片假名 U+3040–U+30FF）。
        // 汉字（U+4E00–U+9FFF）不能作为判据 —— 中文文案本身全是汉字，
        // 而原版日文里的「初級」「中級」等汉字与中文用字重合，
        // 靠汉字分不出来；假名则是日文独有的，一查一个准。
        func isKana(_ v: Unicode.Scalar) -> Bool {
            v.value >= 0x3040 && v.value <= 0x30FF
        }
        let kanaCount = visible.unicodeScalars.filter(isKana).count
        let kanjiCount = visible.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        lines.append("=== 残留检查 ===")
        lines.append("  假名（平假名/片假名）残留：\(kanaCount) 个  ← 判定依据")
        lines.append("  汉字：\(kanjiCount) 个（中文界面里**应该**有，来自中文文案本身）")
        lines.append("  判定：**假名残留为 0 即表示没有日文漏改**")

        lines.append("=== 对照区（不参与残留检查）===")
        lines.append(contentsOf: reference)
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print(text)
        return kanaCount == 0
    }

    /// 描述菜单项快捷键。
    private static func describeAccel(_ item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        var parts: [String] = []
        let mask = item.keyEquivalentModifierMask
        if mask.contains(.control) { parts.append("⌃") }
        if mask.contains(.option) { parts.append("⌥") }
        if mask.contains(.shift) { parts.append("⇧") }
        if mask.contains(.command) { parts.append("⌘") }
        let display = key.uppercased()
        return "  [\(parts.joined())\(display)]"
    }
}
