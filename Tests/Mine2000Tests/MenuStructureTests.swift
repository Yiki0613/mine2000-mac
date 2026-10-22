import AppKit
import Testing
@testable import Mine2000

/// 菜单结构回归测试。
///
/// 这些断言对应原版 Windows 菜单（`RT_MENU 128`，反汇编逐字节解析确认），
/// 同时锁死三个在 macOS 上踩过的坑：
/// 1. 顶级菜单项 `title` 为空 → macOS 菜单栏**不显示**该项（「ゲーム」曾整体消失）；
/// 2. **顶级项没有 `submenu` → 被 AppKit 静默丢弃**，
///    「ゲーム」被提升为 `items[0]` 并占据了菜单栏最左的加粗槽位，
///    导致应用名完全不显示（须用 AXAPI 读系统真实渲染结果才能发现）；
/// 3. 难度快捷键与系统保留键冲突（`Cmd+H` 隐藏应用 / `Cmd+M` 最小化 / `Option+H` 输入法）。
///
/// ────────────────────────────────────────────────────────────────────
/// **本地化与还原度的平衡（2026-10-22 起）**
///
/// 界面文字已全部本地化为中文，但**原版的 menu ID 与日文原文必须仍然可查**：
/// * 显示文字 → 断言**中文**；
/// * `tag` 与结构 → 断言**原版 ID**，一个字节都不许改；
/// * 原版日文 → 由 `L10n.*Original` / `Difficulty.menuTitleOriginal` 承载并单独断言。
///
/// 这样「中文界面」与「原版还原」两件事互不牺牲。
/// ────────────────────────────────────────────────────────────────────
@Suite("菜单结构")
struct MenuStructureTests {

    /// 构建菜单需要一个 NSApplication 实例（不激活 GUI）。
    private func makeMenu() -> NSMenu {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        return AppDelegate().buildMenu()
    }

    // MARK: - 顶级结构

    @Test("顶级菜单含 App 菜单 +「游戏」+「帮助」")
    func topLevelMenus() {
        let menu = makeMenu()
        let titles = menu.items.map(\.title)
        // ⚠️ 第一项必须是 App 菜单（macOS 约定）：
        // 菜单栏最左侧的加粗槽位**永远渲染 items[0]**。
        // 若 items[0] 不是 App 菜单（比如「ゲーム」被提升为第一项），
        // 菜单栏就会显示成「ゲーム | ヘルプ」，应用名彻底不显示。
        #expect(titles.first == L10n.appName,
                "第一项应为 App 菜单（标题=应用名），实际：\(titles)")
        #expect(titles.dropFirst() == ["游戏", "帮助"],
                "顶级菜单应与原版一一对应（本地化后），实际：\(titles)")

        // 回归点：所有顶级项标题都不能为空
        for item in menu.items {
            #expect(!item.title.isEmpty,
                    "顶级菜单项标题不能为空：\(item)")
        }

        // ⚠️⚠️ 关键回归点（曾导致整个应用名不显示）：
        // 顶级项**必须挂 submenu**。没有 submenu 的顶级项会被 AppKit **静默丢弃**，
        // 于是「ゲーム」升为 items[0] 并占据了 App 菜单槽位。
        // （实测截图：Apple logo → ゲーム → ヘルプ，应用名缺失。）
        for item in menu.items {
            #expect(item.submenu != nil,
                    "顶级菜单项「\(item.title)」缺少 submenu，会被 AppKit 丢弃并导致菜单栏错位")
        }
    }

    @Test("App 菜单含关于 / 隐藏 / 退出")
    func appMenu() {
        let menu = makeMenu()
        let appSub = try! #require(menu.items.first?.submenu)
        let appTitles = appSub.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(appTitles == ["关于 扫雷 2000",
                              "隐藏 扫雷 2000",
                              "退出 扫雷 2000"],
                "App 菜单内容不符：\(appTitles)")

        // 分隔符项的 tag 恒为 0，需先过滤再比对
        let appTagList = appSub.items.filter { !$0.isSeparatorItem }.map(\.tag)
        #expect(appTagList == [AppDelegate.MenuID.appMenuAbout,
                               AppDelegate.MenuID.appMenuHide,
                               AppDelegate.MenuID.appMenuQuit],
                "App 菜单 tag 不符：\(appTagList)")
    }

    // MARK: - 「ゲーム」→ 游戏

    @Test("「游戏」子菜单结构与原版一致")
    func gameMenu() {
        let menu = makeMenu()
        let game = menu.items.first { $0.title == "游戏" }
        let sub = try! #require(game?.submenu)

        // 直接子项：开始新局 / 难度 / 最高分 / 退出游戏（+ 分隔符）
        let direct = sub.items.filter { $0.isSeparatorItem == false }.map(\.title)
        #expect(direct == ["开始新局", "难度", "最高分", "退出游戏"],
                "「游戏」直接子项不符：\(direct)")

        // ⚠️ 还原度回归：原版日文原文仍可查
        #expect(L10n.gameMenuOriginal == "ゲーム")
        #expect(L10n.startNewGameOriginal == "ゲームスタート")
        #expect(L10n.highScoreMenuOriginal == "ハイスコア")
        #expect(L10n.quitGameOriginal == "ゲームの終了")
    }

    // MARK: - 難易度 → 难度

    @Test("「难度」子菜单含 5 档，且 tag 与原版菜单 ID 一致")
    func difficultyMenu() {
        let menu = makeMenu()
        let game = menu.items.first { $0.title == "游戏" }
        let gameSub = try! #require(game?.submenu)
        let diff = gameSub.items.first { $0.title == "难度" }
        let diffSub = try! #require(diff?.submenu)

        // 显示文字为中文难度名 + 规模信息
        let titles = diffSub.items.map(\.title)
        #expect(titles == ["初级（8×8，10 雷）",
                           "中级（16×16，40 雷）",
                           "专家（30×16，99 雷）",
                           "大师（48×24，256 雷）",
                           "宗师（64×48，777 雷）"],
                "难度项不符：\(titles)")

        // 原版菜单 ID：初級 32773 / 中級 32774 / 上級 32775 / 超上級 32776 / マニア 32777
        // ⚠️ **tag 必须是原版 ID，一个字节都不许改**
        let expectedTags: [Int] = [32773, 32774, 32775, 32776, 32777]
        #expect(diffSub.items.map(\.tag) == expectedTags,
                "难度菜单 tag 应等于原版菜单 ID")

        // 每个难度项都要能选中难度
        for (item, difficulty) in zip(diffSub.items, Difficulty.allCases) {
            #expect(item.representedObject as? Difficulty == difficulty,
                    "难度项 \(item.title) 未正确绑定 representedObject")
        }
    }

    // MARK: - ハイスコア → 最高分

    @Test("「最高分」子菜单含显示/导入/导出")
    func highScoreMenu() {
        let menu = makeMenu()
        let game = menu.items.first { $0.title == "游戏" }
        let gameSub = try! #require(game?.submenu)
        let score = gameSub.items.first { $0.title == "最高分" }
        let scoreSub = try! #require(score?.submenu)

        let titles = scoreSub.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["查看最高分", "导入最高分", "导出最高分"],
                "最高分子菜单不符：\(titles)")

        // 原版 ID：表示 32778 / 导入 57601 / 导出 57604
        #expect(scoreSub.items.map(\.tag) == [32778, 57601, 57604],
                "最高分菜单 tag 应为原版菜单 ID")

        // 还原度：原版日文原文仍可查
        #expect(L10n.showHighScoresOriginal == "ハイスコアの表示")
        #expect(L10n.importHighScoresOriginal == "ハイスコアのインポート")
        #expect(L10n.exportHighScoresOriginal == "ハイスコアのエクスポート")
    }

    // MARK: - ヘルプ → 帮助

    @Test("「帮助」子菜单含版本信息，tag 为原版 ID 57664")
    func helpMenu() {
        let menu = makeMenu()
        let help = menu.items.first { $0.title == "帮助" }
        let helpSub = try! #require(help?.submenu)

        let titles = helpSub.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["版本信息..."], "帮助子菜单不符：\(titles)")
        #expect(helpSub.items.first?.tag == 57664, "版本信息 tag 应为 57664")

        // 还原度
        #expect(L10n.helpMenuOriginal == "ヘルプ")
        #expect(L10n.aboutOriginal == "バージョン情報...")
    }

    // MARK: - 快捷键

    @Test("难度快捷键不与 macOS 系统保留键冲突")
    func difficultyShortcutsAvoidSystemConflicts() {
        let menu = makeMenu()
        let game = menu.items.first { $0.title == "游戏" }
        let gameSub = try! #require(game?.submenu)
        let diff = gameSub.items.first { $0.title == "难度" }
        let diffSub = try! #require(diff?.submenu)

        // macOS 系统保留：Cmd+H(隐藏应用) / Cmd+M(最小化) / Option+H(输入法长音符)
        let forbidden: Set<String> = ["h", "m"]

        for item in diffSub.items {
            let key = item.keyEquivalent.lowercased()
            #expect(!forbidden.contains(key),
                    "难度「\(item.title)」的快捷键 \(item.keyEquivalent) 与系统保留键冲突")
            #expect(item.keyEquivalentModifierMask.contains(.command),
                    "难度快捷键应带 Command 修饰")
            #expect(item.keyEquivalentModifierMask.contains(.option),
                    "难度快捷键应带 Option 修饰（避免与系统单键快捷键冲突）")
        }

        // 5 个难度必须用互不相同的键
        let keys = diffSub.items.map(\.keyEquivalent)
        #expect(Set(keys).count == keys.count, "难度快捷键必须互不相同：\(keys)")
    }

    @Test("「开始新局」的 F2 快捷键存在（原版菜单文字「ゲームスタート(&S) F2」）")
    func startItemShortcut() {
        let menu = makeMenu()
        let game = menu.items.first { $0.title == "游戏" }
        let gameSub = try! #require(game?.submenu)
        let start = gameSub.items.first { $0.title == "开始新局" }
        #expect(start?.keyEquivalent.lowercased() == "f2",
                "开始项应绑定 F2（原版菜单即如此）")
        #expect(start?.tag == 32771, "开始项 tag 应为 32771")
    }
}
