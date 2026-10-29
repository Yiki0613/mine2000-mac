import AppKit

/// 应用主控制器：负责窗口、菜单、计时器与交互分发。
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // MARK: - 状态

    /// 主窗口。
    private var window: NSWindow!

    /// 图集渲染器。
    private var renderer: TileRenderer!

    /// 当前游戏会话（棋盘 + 计时 + 表情）。
    private var session: GameSession!

    /// 棋盘视图。
    private var boardView: BoardView!

    /// 顶部信息条。
    private var hudView: HUDView!

    /// 计时器（驱动 HUD 刷新）。
    private var timer: Timer?

    /// 当前难度。
    private var difficulty: Difficulty = .middle

    /// 高分榜。
    private var highScores = HighScoreTable()

    /// 高分榜窗口控制器。
    private var highScoreWindowController: HighScoreWindowController?

    /// 鼠标是否正按下（用于「惊讶」表情）。
    private var mousePressed = false

    /// 鼠标是否位于棋盘范围内（用于区分「惊讶」与「备用脸」）。
    private var mouseOnBoard = true

    /// 高分榜文件在用户目录中的路径。
    // MARK: - 生命周期

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            renderer = try TileRenderer()
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法加载图集资源"
            alert.informativeText = "\(error)"
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        session = GameSession(difficulty: difficulty)
        loadHighScores()

        buildWindow()
        NSApp.mainMenu = buildMenu()
        startTimer()
        refreshHUD()
        NSApp.activate(ignoringOtherApps: true)
        writeMenuBarDiagnostics()
    }

    /// 把系统**真实渲染**的菜单栏结构写入诊断文件。
    ///
    /// 为什么需要它：AppKit 会静默丢弃没有 `submenu` 的顶级菜单项，
    /// 而 `mainMenu.items` 数组**看不出**这个丢弃（数组内容不变）。
    /// 只有读 AX 树才知道系统到底渲染了什么。
    /// 详见 `MenuBarDiagnostics`。
    private func writeMenuBarDiagnostics() {
        // 延迟一拍：菜单栏要等 AppKit 完成一次布局后才是最终形态
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let titles = MenuBarDiagnostics.renderedMenuBarTitles() ?? []
            // ⚠️ 首项是系统自带的「Apple」菜单；我们的应用名紧随其后。
            // 故障态（占位项被丢弃）时会是 ["Apple", "游戏", "帮助"]。
            // ⚠️ 2026-10-22 起界面已本地化为中文，期望值同步更新。
            let expected: [String] = ["Apple", L10n.appName, "游戏", "帮助"]
            let verdict = titles == expected
                ? "OK:应用名正常显示在菜单栏（紧随 Apple 菜单）"
                : "FAIL:期望 \(expected)，实际 \(titles)"
            let text = """
            titles=\(titles)
            verdict=\(verdict)
            """
            try? text.write(toFile: "/tmp/mine2000_menubar.txt", atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("[菜单栏诊断] \(text)\n".utf8))
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        saveHighScores()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - 窗口

    private func buildWindow() {
        boardView = BoardView(board: session.board, renderer: renderer)
        hudView = HUDView(renderer: renderer)
        hudView.onFaceClicked = { [weak self] in self?.startNewGame() }

        // 交互回调
        boardView.callbacks.onReveal = { [weak self] row, column in
            guard let self else { return }
            self.session.reveal(row: row, column: column)
            self.afterMove()
        }
        boardView.callbacks.onToggleFlag = { [weak self] row, column in
            guard let self else { return }
            self.session.toggleFlag(row: row, column: column)
            self.afterMove()
        }
        boardView.callbacks.onChord = { [weak self] row, column in
            guard let self else { return }
            self.session.chord(row: row, column: column)
            self.afterMove()
        }
        // 鼠标按下 / 离开棋盘 → 切换「惊讶」表情
        boardView.callbacks.onMouseStateChanged = { [weak self] pressed, onBoard in
            guard let self else { return }
            self.mousePressed = pressed
            self.mouseOnBoard = onBoard
            self.refreshHUD()
        }

        let container = NSView()
        // 包边底色：开启 layer 支撑后填 HUD 同色，
        // 窗口圆角处切到的就是这层底色，而不是棋盘的格子。
        container.wantsLayer = true
        container.layer?.backgroundColor = Self.frameColor.cgColor
        container.addSubview(hudView)
        container.addSubview(boardView)

        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        // 初始尺寸按当前难度的棋盘 + HUD 计算（下方 fitWindowToContent 会再校正一次）
        let initial = contentSizeForCurrentBoard()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initial.width, height: initial.height),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = L10n.appName
        window.contentView = container
        // 用户手动缩放窗口时，让棋盘与 HUD 跟随重新布局（保持水平居中）
        window.delegate = self
        window.center()
        // ⚠️ 不要用 setFrameAutosaveName：它会记住上一次运行时的窗口尺寸，
        // 导致切换难度后窗口仍是旧尺寸（棋盘与窗口不匹配）。
        window.makeKeyAndOrderFront(nil)

        fitWindowToContent(recenter: true)
    }

    /// 内容四周的包边宽度（pt）。
    ///
    /// macOS 的窗口是圆角矩形，系统标准圆角半径 **10 pt**。若让棋盘直接铺满
    /// `contentView`，四个角上的格子会被圆角切掉（底部两角最明显，因为棋盘是浅灰；
    /// 顶部两角其实也切了，只是藏在 HUD 的深色里看不出来）。
    ///
    /// 留 12 pt = 10 pt 圆角 + 2 pt 余量，圆角就落在包边底色上，格子保持完整。
    /// 包边底色用 HUD 的 `#262626`，与顶栏连成一体，视觉上是「HUD 加厚了一圈」，
    /// 不会多出一道分层线。
    private static let contentInset: CGFloat = 12

    /// 包边底色，与 `HUDView` 的背景色一致（实测 `#262626`）。
    private static let frameColor = NSColor(
        srgbRed: 38.0 / 255.0,
        green: 38.0 / 255.0,
        blue: 38.0 / 255.0,
        alpha: 1.0
    )

    /// 当前棋盘 + HUD 所需的理想内容尺寸。
    private func contentSizeForCurrentBoard() -> NSSize {
        let scale = max(boardView.scale, 1)
        let boardWidth = CGFloat(session.board.columns * Difficulty.cellSize * scale)
        let boardHeight = CGFloat(session.board.rows * Difficulty.cellSize * scale)
        let hudHeight = CGFloat(HUDView.height * hudView.scale)
        let inset = Self.contentInset
        return NSSize(
            width: boardWidth + inset * 2,
            height: boardHeight + hudHeight + inset * 2
        )
    }

    /// 把窗口尺寸调整到恰好容纳棋盘 + HUD，并把棋盘在窗口内水平居中。
    ///
    /// - Parameter recenter: 是否把窗口移到屏幕中央。
    ///   仅在**尺寸真的变了**（切换难度）时才重定位窗口；
    ///   同一难度内重开一局（点笑脸）不应让窗口跳位。
    private func fitWindowToContent(recenter: Bool = false) {
        guard let container = window.contentView else { return }
        let size = contentSizeForCurrentBoard()
        let current = window.contentView?.frame.size ?? .zero
        let sizeChanged = abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5
        if sizeChanged {
            window.setContentSize(size)
        }
        container.frame = container.bounds
        layoutSubviews()
        if recenter && sizeChanged, let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            var origin = window.frame.origin
            origin.x = visible.midX - window.frame.width / 2
            origin.y = visible.midY - window.frame.height / 2
            window.setFrameOrigin(origin)
        }
    }

    private func layoutSubviews() {
        guard let container = window.contentView else { return }
        // 计时器位数按难度自适应（初級 3 位、其他 5 位，原版 0x403520 的 cmp 8 分支）
        hudView.timerColumns = session.board.columns
        let hudHeight = CGFloat(HUDView.height * hudView.scale)
        let boardWidth = CGFloat(session.board.columns * Difficulty.cellSize * boardView.scale)
        let boardHeight = CGFloat(session.board.rows * Difficulty.cellSize * boardView.scale)
        container.frame = container.bounds

        // 四周留出包边，让窗口圆角落在底色上而不是格子上
        let inset = Self.contentInset
        let innerWidth = max(0, container.bounds.width - inset * 2)
        let innerHeight = max(0, container.bounds.height - inset * 2)

        // HUD 贴顶（距窗口上沿 inset），横跨可用宽度
        hudView.frame = NSRect(
            x: inset,
            y: container.bounds.height - inset - hudHeight,
            width: innerWidth,
            height: hudHeight
        )

        // 棋盘在 HUD 下方、可用区域内居中
        let boardX = inset + max(0, (innerWidth - boardWidth) / 2)
        let boardY = inset + max(0, (innerHeight - hudHeight - boardHeight) / 2)
        boardView.frame = NSRect(x: boardX, y: boardY, width: boardWidth, height: boardHeight)
        boardView.setNeedsDisplay(boardView.bounds)
    }

    // MARK: - NSWindowDelegate

    /// 用户手动缩放窗口 → 重新布局，让棋盘保持居中。
    public func windowDidResize(_ notification: Notification) {
        layoutSubviews()
    }

    // MARK: - 菜单（照搬原版结构）

    /// 原版 MFC 菜单资源（`RT_MENU 128`）里的命令 ID。
    ///
    /// ────────────────────────────────────────────────────────────────────
    /// **[已确证]** 原始资源：文件偏移 `0xC928`，长 `0x18E` = 398 字节，
    /// 解析消费 398/398 = 100%。逐条可核对：
    ///
    /// | 原版 ID | 菜单文字 | 初始标志 |
    /// |---|---|---|
    /// | `32771` | `ゲーム(&G)` / `スタート(&S)     F2` | — |
    /// | `32773`–`32777` | `初級(&B)` … ` mania(&M)` | `32777` = `0x0080` 灰置 |
    /// | `32778` | `ハイスコアの表示(&V)` | — |
    /// | `57601` | `ハイスコアのインポート(&I)` | `0x0002` 禁用 |
    /// | `57604` | `ハイスコアのエクスポート(&E)` | `0x0082` 灰置+禁用 |
    /// | `57665` | `ゲームの終了(&X)` | `0x0080` 灰置 |
    /// | `57664` | `ﾊﾞｰｼﾞｮﾝ情報(&A)...` | `0x0080` 灰置 |
    ///
    /// macOS 的 `NSMenuItem` 用选择器而非数值 ID 派发命令，
    /// 因此把这些 ID 写进 `NSMenuItem.tag`，
    /// 让「菜单结构与原版 ID 一一对应」成为**可被测试断言**的事实，
    /// 而不只��靠人读代码核对。
    public enum MenuID {
        /// ゲームスタート（`スタート(&S)     F2`）。
        public static let start = 32771
        /// 初級（`初級(&B)`）。
        public static let difficultyBeginner = 32773
        /// 中級（`中級(&I)`）。
        public static let difficultyMiddle = 32774
        /// 上級（`上級(&E)`）。
        public static let difficultyExpert = 32775
        /// 超上級（`超上級(&H)`）。
        public static let difficultyHiper = 32776
        /// マニア（` mania(&M)`，原版初始灰置）。
        public static let difficultyMania = 32777
        /// ハイスコアの表示。
        public static let showHighScores = 32778
        /// ハイスコアのインポート（原版初始禁用）。
        public static let importHighScores = 57601
        /// ハイスコアのエクスポート。
        public static let exportHighScores = 57604
        /// ゲームの終了。
        public static let quit = 57665
        /// バージョン情報。
        public static let about = 57664

        // ── macOS App 菜单（系统槽位，原版 Windows 无对应物）──
        // 原版的「ゲームの終了」仍在「ゲーム」菜单里（tag = MenuID.quit = 57665），
        // 这里的三个 ID 是 macOS 惯用 App 菜单的补充入口，不参与原版 ID 映射。
        /// App メニュー → 「关于 扫雷 2000」。
        public static let appMenuAbout = 90001
        /// App メニュー → 「隐藏 扫雷 2000」。
        public static let appMenuHide = 90002
        /// App メニュー → 「退出 扫雷 2000」。
        public static let appMenuQuit = 90003

        /// 5 个难度项的 ID，按 `Difficulty.allCases` 顺序。
        public static let difficulties: [Int] = [
            difficultyBeginner, difficultyMiddle, difficultyExpert,
            difficultyHiper, difficultyMania,
        ]
    }

    /// 构建菜单栏。
    ///
    /// 结构对齐原版的日文菜单（反汇编确认的菜单 ID）：
    /// `ゲーム(&G)` / `ゲームスタート(&S)` F2 / `難易度(&D)` /
    /// `初級(&B) 中級(&I) 上級(&E) 超上級(&H) マニア(&M)` /
    /// `ハイスコア(&H)` / `ハイスコアの表示(&V)` /
    /// `ハイスコアのインポート(&I)` / `ハイスコアのエクスポート(&E)` /
    /// `ゲームの終了(&X)` / `ヘルプ(&H)` / `バージョン情報(&A)...`
    ///
    /// macOS 与 Windows 的加速键约定不同：原版的 `&X` 字母加速键
    /// 在 macOS 上对应 **⌘X**（修饰键为 Command）。
    /// 构建主菜单栏。
    ///
    /// 返回 `NSMenu` 以便**单元测试直接断言菜单结构**
    /// （顶级项标题、层级、菜单项文字、快捷键、tag）。
    @discardableResult
    func buildMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // ⚠️ macOS 规定 mainMenu 的**第一项是 App 菜单**（菜单栏最左侧那个加粗的应用名）。
        //
        // 【踩坑史】这个占位项先后试过三种写法，都失败：
        //   ① NSMenuItem() 无参构造 → title 变成字面量 "NSMenuItem"，菜单栏显示成 "NSMenuItem"
        //   ② title 留空            → AppKit 直接把该项移除，「ゲーム」升为第一项
        //   ③ title = 应用名、无 submenu → **同样被移除**（当前版本就是这一版）
        //
        // 【真正的根因】AppKit 判定「这是一个顶级菜单」的前提是**该项必须有 submenu**。
        // 没有 submenu 的顶级项会被静默丢弃 —— 于是「ゲーム」被提升为 items[0]，
        // 而 macOS 菜单栏最左侧的粗体槽位**永远显示 items[0]**，
        // 结果就是「ゲーム」被当成 App 菜单渲染（实测截图：Apple logo → ゲーム → ヘルプ，
        // 应用名完全不显示），而真正的应用菜单（含退出）根本不存在。
        //
        // 【正解】照 Xcode 模板的标准做法：占位项挂一个**标准 App 菜单 submenu**
        // （关于 / 隐藏 / 退出），并显式给它应用名作为 title。
        // 这样 AppKit 认得它、不会丢弃，菜单栏最左侧就会显示加粗的「扫雷 2000」。
        //
        // 注：原版 Windows 的「ゲームの終了」仍保留在「ゲーム」菜单里（行为还原要求），
        //     这里的退出是 macOS 惯用的第二个入口，两者并存不冲突。
        let appMenuItem = NSMenuItem(title: L10n.appName, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: L10n.appName)
        let appAboutItem = appMenu.addItem(
            withTitle: L10n.appMenuAbout,
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        appAboutItem.tag = MenuID.appMenuAbout
        appMenu.addItem(.separator())
        let appHideItem = appMenu.addItem(
            withTitle: L10n.appMenuHide,
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appHideItem.tag = MenuID.appMenuHide
        let appQuitItem = appMenu.addItem(
            withTitle: L10n.appMenuQuit,
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appQuitItem.tag = MenuID.appMenuQuit
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // ── 游戏（原版：ゲーム(&G)）──
        let gameMenu = NSMenu(title: L10n.gameMenu)
        // ⚠️ 必须显式给顶级菜单项设 title：NSMenuItem() 空构造出来的项
        // 标题为空时，macOS 菜单栏**不会显示它**（子菜单里的项不受影响）。
        // 这曾导致整个「ゲーム」菜单（含难度切换 / 高分榜 / 退出）在菜单栏里消失。
        let gameItem = NSMenuItem(title: L10n.gameMenu, action: nil, keyEquivalent: "")
        let startItem = gameMenu.addItem(
            withTitle: L10n.startNewGame,
            action: #selector(startNewGame),
            keyEquivalent: "f2"
        )
        startItem.keyEquivalentModifierMask = []
        startItem.tag = MenuID.start
        gameMenu.addItem(.separator())

        let difficultyMenu = NSMenu(title: L10n.difficultyMenu)
        let difficultyItem = NSMenuItem(title: L10n.difficultyMenu, action: nil, keyEquivalent: "")
        // 原版菜单 ID：初級 32773 / 中級 32774 / 上級 32775 / 超上級 32776 / マニア 32777
        // ⚠️ **tag 仍是原版 ID，一律不改** —— 界面文字本地化，行为标识保持原版。
        // 显示文字：初级 / 中级 / 专家 / 大师 / 宗师（译名依据见 Difficulty.menuTitle 注释）
        // 原版加速键：&B / &I / &E / &H / &M
        // 难度快捷键 = Cmd+Option+数字 1..5。
        //
        // 为什么不用原版的字母助记（&B/&I/&E/&H/&M）：
        // 直译到 macOS 是 Cmd+B/I/E/H/M，其中
        //   Cmd+H = 隐藏应用、Cmd+M = 最小化窗口（系统保留，实测会被拦截）
        //   Option+H = 长音符「ー」（输入法特殊字符，实测键不送达）
        // 全部踩过坑后改用 **Cmd+Option+1..5**：
        //   · 与系统快捷键零冲突（实测 5 档全部生效）
        //   · 数字直对应难度顺序，macOS 菜单里也直观
        //   · 仍保留 Cmd+Option 这一「次级操作」的 macOS 惯例
        let accelerators = ["1", "2", "3", "4", "5"]
        // ⚠️ 必须用 `enumerated()`，不能用 `zip` 自身的索引。
        // `ZipSequence` 的索引来自底层序列的 `Index`，对 `Array` 而言本应安全，
        // 但这里外层 `zip` 的第一个操作数是 `MenuID.difficulties`（`[Int]`），
        // 第二个是**嵌套** `zip`，Swift 6 下该嵌套组合的索引推断会退化为
        // 无界的 `Int` 序列，导致 `difficulties[index]` 越界崩溃
        // （表现为启动即 `EXC_BREAKPOINT / Index out of range`，
        //   栈在 `AppDelegate.buildMenu()`）。
        // 用 `enumerated()` 拿到确定从 0 开始的真实序号后不再有此问题。
        for (index, difficulty) in Difficulty.allCases.enumerated() {
            let accel = accelerators[index]
            let item = NSMenuItem(title: difficulty.menuTitleWithScale,
                                 action: #selector(selectDifficulty(_:)),
                                 keyEquivalent: accel)
            // ⚠️ 用 Cmd+Option（而非 Cmd）承载难度助记键。
            // 原版 Windows 菜单是 &B/&I/&E/&H/&M，直译到 macOS 就是 Cmd+B/I/E/H/M，
            // 但其中两个与系统快捷键**硬冲突**：
            //   Cmd+H = 隐藏应用（实测按了会把 app 藏起来，难度根本不切换）
            //   Cmd+M = 最小化窗口
            // 改用 Cmd+Option 后五个键都不再与系统冲突，
            // 同时保留原版的 B/I/E/H/M 字母助记，可读性不变。
            item.keyEquivalentModifierMask = [.command, .option]
            item.representedObject = difficulty
            item.target = self
            item.tag = MenuID.difficulties[index]
            difficultyMenu.addItem(item)
        }
        difficultyItem.submenu = difficultyMenu
        gameMenu.addItem(difficultyItem)
        gameMenu.addItem(.separator())

        let scoreMenu = NSMenu(title: L10n.highScoreMenu)
        let scoreItem = NSMenuItem(title: L10n.highScoreMenu, action: nil, keyEquivalent: "")
        // 原版加速键：表示 &V / インポート &I / エクスポート &E
        // ⚠️ tag 保持原版 ID（32778 / 57601 / 57604），仅显示文字本地化。
        let showItem = scoreMenu.addItem(
            withTitle: L10n.showHighScores,
            action: #selector(showHighScores),
            keyEquivalent: "v"
        )
        showItem.keyEquivalentModifierMask = [.command]
        showItem.tag = MenuID.showHighScores

        let importItem = scoreMenu.addItem(
            withTitle: L10n.importHighScores,
            action: #selector(importHighScores),
            keyEquivalent: "i"
        )
        importItem.keyEquivalentModifierMask = [.command, .shift]
        importItem.tag = MenuID.importHighScores

        let exportItem = scoreMenu.addItem(
            withTitle: L10n.exportHighScores,
            action: #selector(exportHighScores),
            keyEquivalent: "e"
        )
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        exportItem.tag = MenuID.exportHighScores

        scoreItem.submenu = scoreMenu
        gameMenu.addItem(scoreItem)

        gameMenu.addItem(.separator())
        let quitItem = gameMenu.addItem(
            withTitle: L10n.quitGame,
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "x"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.tag = MenuID.quit

        gameItem.submenu = gameMenu
        mainMenu.addItem(gameItem)

        // ── 帮助（原版：ヘルプ(&H)）──
        let helpMenu = NSMenu(title: L10n.helpMenu)
        let helpItem = NSMenuItem(title: L10n.helpMenu, action: nil, keyEquivalent: "")
        let aboutItem = helpMenu.addItem(
            withTitle: L10n.about,
            action: #selector(showAbout),
            keyEquivalent: "a"
        )
        aboutItem.keyEquivalentModifierMask = [.command]
        aboutItem.tag = MenuID.about
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        // 其余顶级项（ゲーム / ヘルプ）都在创建时显式给了 title，
        // 且都挂了 submenu —— 顶级项没有 submenu 会被 AppKit 静默丢弃（见上方说明）。

        return mainMenu
    }

    // MARK: - 动作

    /// 开始新游戏（对应菜单「ゲームスタート」/ F2 / 点击笑脸）。
    @objc private func startNewGame() {
        session.restart(difficulty: difficulty)
        boardView.setBoard(session.board)
        mousePressed = false
        refreshHUD()
        // ⚠️ **不要在这里调整窗口尺寸/位置**。
        //
        // 同一难度内重开一局（点笑脸 / F2）时棋盘尺寸没变，
        // 用户可能已经手动拉大窗口并挪到别处 —— 此时强行 setContentSize + 居中，
        // 会把窗口"啪"地缩回原始大小并弹回屏幕中央（用户实测反馈）。
        // 只重新排布视图，窗口保持用户当前的大小与位置。
        layoutSubviews()
    }

    /// 切换难度。
    ///
    /// 难度变了 → 棋盘尺寸真的变了 → 这里才需要重新适配窗口并居中。
    @objc private func selectDifficulty(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? Difficulty else { return }
        difficulty = d
        startNewGame()
        fitWindowToContent(recenter: true)
    }

    /// 关于对话框。
    ///
    /// ⚠️ **完整保留原作者信息**（用户 2026-10-22 拍板）：
    /// 既写明原版出处与作者，也**明确声明**本 .app 是独立重写、
    /// 并非原版程序本身 —— 避免让人误以为这就是原版。
    ///
    /// 原版 About 对话框（DIALOG 资源 100）原文为：
    /// `2000 Version 2.2.1` / `Copyright (C) 1999-2005` /
    /// `(C) 1999 Tomohiro Kumagai` / `Kazuhiro Toyama`
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "\(L10n.appName) 2.0"
        alert.informativeText = """
        原版：mine2000 Version 2.2.1
        Copyright (C) 1999-2005, Tomohiro Kumagai / Kazuhiro Toyama
        发行：AhoSoft

        本版本为独立重写的原生 macOS 版（Swift + AppKit，零第三方依赖），
        行为规格由原版二进制反汇编还原，非原版程序本身。
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// 显示高分榜窗口。
    @objc private func showHighScores() {
        if let controller = highScoreWindowController {
            controller.refresh()
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = HighScoreWindowController(table: highScores)
        highScoreWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// 导入 `.m2k` 成绩档。
    @objc private func importHighScores() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L10n.importFilePrompt
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            highScores = try M2KCodec.decode([UInt8](data))
            saveHighScores()
            showHighScores()
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.importFailed
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// 导出 `.m2k` 成绩档。
    @objc private func exportHighScores() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hiscore.m2k"
        panel.message = L10n.exportFilePrompt
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // ⚠️ 中文名无法用 Shift-JIS 编码 → 导出时降级为 Yiki，并提示用户
            let exported = try ScoreStore.exportM2K(highScores)
            try Data(exported.bytes).write(to: url)
            if exported.downgraded {
                let notice = NSAlert()
                notice.messageText = L10n.exportDowngradeNotice
                notice.alertStyle = .informational
                notice.addButton(withTitle: L10n.ok)
                notice.runModal()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.exportFailed
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - 高分榜持久化

    /// 读取成绩。
    ///
    /// ⚠️ 走 `ScoreStore`（UTF-8 `scores.json`），
    /// 内部会自动从旧版 Shift-JIS `hiscore.m2k` 迁移（且不删除旧文件）。
    private func loadHighScores() {
        highScores = ScoreStore.load()
    }

    /// 保存成绩（UTF-8 `scores.json`）。
    private func saveHighScores() {
        try? ScoreStore.save(highScores)
    }

    // MARK: - 计时与 HUD

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshHUD()
        }
    }

    /// 一次操作之后刷新 HUD（并在胜利时记录成绩）。
    private func afterMove() {
        refreshHUD()
        // ⚠️ 必须显式请求棋盘重绘：`Board` 是引用类型，格子的状态在别处被就地修改，
        // 视图不会自动感知。漏掉这一行会导致「翻牌/插旗/扫雷后画面不更新」。
        // （右键插旗曾因此完全不可见 —— 逻辑层已改对，但画面没刷新。）
        boardView.needsDisplay = true
        if session.board.state == .won {
            recordHighScore()
        }
    }

    /// 把当前成绩提交到高分榜。
    private func recordHighScore() {
        let score = session.scoreDeciseconds
        guard score < HighScoreEntry.noScoreSentinel else { return }

        // 先判断成绩能否入榜：入榜才需要问名字，避免无谓打扰。
        guard let rank = prospectiveRank(for: score) else { return }

        let name = requestPlayerName(rank: rank)
        guard let name else { return }   // 用户取消 → 不记录

        if highScores.submit(name: name, score: score, for: difficulty) != nil {
            saveHighScores()
            showHighScores()
        }
    }

    /// 预估成绩的名次（0 = 第一名）；不入榜返回 `nil`。
    ///
    /// 规则与 `HighScoreTable.submit` 一致：用时升序，
    /// 成绩必须优于当前第 5 名才入榜。
    private func prospectiveRank(for score: Int) -> Int? {
        let list = highScores.sortedScores(for: difficulty)
        var insertIndex = list.count
        for (i, entry) in list.enumerated() {
            if score < entry.score {
                insertIndex = i
                break
            }
        }
        return insertIndex < HighScoreTable.entriesPerDifficulty ? insertIndex : nil
    }

    /// 弹窗让玩家输入名字。
    ///
    /// - Parameter rank: 名次（0 = 第一名），用于显示提示语。
    /// - Returns: 玩家输入的名字；用户取消时返回 `nil`。
    ///
    /// - [推断] 原版在成绩入榜时弹窗让玩家输入名字，
    ///   提示语为 `%d位にランクイン！！`（`.rdata` `0x408F68`）。
    ///   对话框的具体布局未逐字节确证，此处按等价语义实现。
    private func requestPlayerName(rank: Int) -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.rankInMessage(rank: rank + 1)
        alert.informativeText = L10n.enterNamePrompt

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = lastPlayerName
        field.placeholderString = L10n.anonymousName
        alert.accessoryView = field

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L10n.cancel)

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 留空时用**界面语言**的默认名（「匿名」），而不是存档里的原版「名前なし」——
        // 后者是字节级一致的基准，只用于「新建空档」，不该出现在中文界面上。
        let name = typed.isEmpty ? L10n.anonymousName : typed
        lastPlayerName = name
        return name
    }

    /// 上次输入的名字（作为下次输入框的默认值）。
    ///
    /// ⚠️ 初值必须是**空字符串**：这样输入框显示的是占位符「匿名」。
    /// 早前这里用 `M2KCodec.defaultName`（日文「名前なし」）作为初值，
    /// 结果中文界面的入榜弹窗里预填了一串日文。
    private var lastPlayerName: String = ""

    /// 刷新 HUD 显示。
    private func refreshHUD() {
        hudView.remainingMines = session.remainingMines
        hudView.elapsedDeciseconds = session.elapsedDeciseconds
        // 表情 = 游戏状态 × 鼠标状态（原版 5 张脸的全部来源）
        let faceState = FaceState(
            gameState: session.board.state,
            mousePressed: mousePressed,
            mouseOnBoard: mouseOnBoard
        )
        hudView.expression = faceState.expression
    }
}
