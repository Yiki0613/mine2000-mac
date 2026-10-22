import AppKit

/// 高分榜显示窗口。
///
/// ────────────────────────────────────────────────────────────────────────
/// 原版把高分榜放在一个独立对话框里（5 个难度各 5 行），
/// 本实现复刻为独立的 `NSWindow`（非模态），可与游戏窗口同时存在。
/// ────────────────────────────────────────────────────────────────────────
public final class HighScoreWindowController: NSWindowController {

    /// 高分榜数据源。
    private let table: HighScoreTable

    /// 显示用文本视图。
    private let textView = NSTextView()

    /// 初始化。
    public init(table: HighScoreTable) {
        self.table = table

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.highScoreMenu
        window.center()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        scroll.autoresizingMask = [.width, .height]

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        window.contentView = scroll
        super.init(window: window)

        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 暂不支持")
    }

    /// 刷新显示内容。
    public func refresh() {
        textView.string = Self.renderText(table)
    }

    /// 把高分榜渲染为等宽文本。
    ///
    /// 布局：每个难度一个小节，5 行名次，格式为「名次. 名字 成绩」。
    /// 小节标题用**本地化难度名**（`Difficulty.menuTitle`）。
    /// 成绩格式为「用时.十分之一秒 秒」（`ScoreFormat.format`）——
    /// ⚠️ 单位是**十分之一秒**（原版计时函数 `0x401C46` = 毫秒差 / 100），
    ///    不是百分之一秒；早前注释写错已更正。
    static func renderText(_ table: HighScoreTable) -> String {
        var lines: [String] = []

        for difficulty in Difficulty.allCases {
            lines.append("【\(difficulty.menuTitle)】")
            let scores = table.sortedScores(for: difficulty)
            for (i, entry) in scores.enumerated() {
                let rank = i + 1
                // ⚠️ 存档里的默认名是原版「名前なし」（`M2KCodec.defaultName`），
                //    那是**字节级一致**的基准，不能改；但**界面上**必须显示中文
                //    `L10n.anonymousName`（「匿名」）—— 否则中文界面会漏出日文。
                let displayName: String = {
                    if entry.name.isEmpty { return "-----" }
                    if entry.name == M2KCodec.defaultName { return L10n.anonymousName }
                    return entry.name
                }()
                let name = displayName
                let value = entry.isEmpty
                    ? "-----"
                    : ScoreFormat.format(deciseconds: entry.score)
                lines.append(String(format: "%d. %-12@%@", rank, name as NSString, value))
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
