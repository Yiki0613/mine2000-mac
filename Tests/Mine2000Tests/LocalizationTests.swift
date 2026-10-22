import AppKit
import Foundation
import Testing
@testable import Mine2000

/// 界面本地化回归测试。
///
/// ────────────────────────────────────────────────────────────────────
/// **为什么需要这一层**
///
/// 单元测试只能断言「我写下的那几个字符串」。
/// 但本地化真正的风险是**漏改** —— 某个弹窗、某个窗口标题忘了改，
/// 没有任何既有测试会失败。
///
/// 所以这里做的是**穷举式**检查：
/// 把**所有用户实际能看到的文案**拉出来，逐条扫描假名（平假名/片假名）。
///
/// **为什么只数假名，不数汉字**
///
/// 中文文案本身全是汉字，而原版日文的「初級」「中級」等也用汉字，
/// 靠汉字分不出来；**假名是日文独有的**，一查一个准。
///
/// 同时，正文里**有意保留**的原版日文对照
/// （`L10n.*Original` / `Difficulty.menuTitleOriginal`）不算漏改 ——
/// 它们不显示给用户，是还原度可反查的依据。
/// ────────────────────────────────────────────────────────────────────
@Suite("界面本地化")
struct LocalizationTests {

    /// 判定一个 Unicode 标量是否为日文假名（平假名/片假名）。
    private func isKana(_ v: Unicode.Scalar) -> Bool {
        v.value >= 0x3040 && v.value <= 0x30FF
    }

    /// 取出所有用户可见的界面文案。
    private func visibleTexts() -> [String] {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let menu = AppDelegate().buildMenu()

        var texts: [String] = []
        // 菜单栏全部项
        for item in menu.items {
            texts.append(item.title)
            if let sub = item.submenu {
                for child in sub.items {
                    if !child.isSeparatorItem { texts.append(child.title) }
                    if let subsub = child.submenu {
                        for grand in subsub.items where !grand.isSeparatorItem {
                            texts.append(grand.title)
                        }
                    }
                }
            }
        }
        // 窗口 / 弹窗 / 对话框
        texts.append(L10n.highScoreMenu)
        texts.append(L10n.rankInMessage(rank: 1))
        texts.append(L10n.enterNamePrompt)
        texts.append(L10n.anonymousName)
        texts.append(L10n.ok)
        texts.append(L10n.cancel)
        texts.append(L10n.importFilePrompt)
        texts.append(L10n.exportFilePrompt)
        texts.append(L10n.importFailed)
        texts.append(L10n.exportFailed)
        texts.append(L10n.exportDowngradeNotice)
        texts.append(L10n.scoreFormat)
        // 难度显示名
        for difficulty in Difficulty.allCases {
            texts.append(difficulty.menuTitleWithScale)
        }
        return texts
    }

    @Test("所有用户可见文案中无日文假名残留")
    func noJapaneseKanaInVisibleText() {
        let texts = visibleTexts()
        var offenders: [String] = []
        for text in texts {
            let kana = text.unicodeScalars.filter(isKana).map(String.init).joined()
            if !kana.isEmpty { offenders.append("「\(text)」含假名 \(kana)") }
        }
        #expect(offenders.isEmpty, "用户可见文案里残留日文假名：\(offenders)")
    }

    @Test("所有用户可见文案均非空")
    func noEmptyVisibleText() {
        for text in visibleTexts() {
            #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty,
                    "存在空的界面文案")
        }
    }

    @Test("原版日文对照完整保留（还原度回归）")
    func originalJapanesePreserved() {
        // ⚠️ 本地化**只改显示文字**。原版日文必须仍可查，
        //    否则「行为还原对照表」将失去对照依据。
        #expect(L10n.gameMenuOriginal == "ゲーム")
        #expect(L10n.gameMenu == "游戏")
        #expect(L10n.difficultyMenuOriginal == "難易度")
        #expect(L10n.difficultyMenu == "难度")
        #expect(L10n.highScoreMenuOriginal == "ハイスコア")
        #expect(L10n.highScoreMenu == "最高分")
        #expect(L10n.helpMenuOriginal == "ヘルプ")
        #expect(L10n.helpMenu == "帮助")
        #expect(L10n.startNewGameOriginal == "ゲームスタート")
        #expect(L10n.startNewGame == "开始新局")
        #expect(L10n.quitGameOriginal == "ゲームの終了")
        #expect(L10n.quitGame == "退出游戏")
        #expect(L10n.aboutOriginal == "バージョン情報...")
        #expect(L10n.about == "版本信息...")
        #expect(L10n.rankInMessageOriginal(rank: 3) == "3位にランクイン！！")
        #expect(L10n.rankInMessage(rank: 3) == "恭喜！排名第 3 位！！")
        #expect(L10n.scoreFormatOriginal == "%d.%d秒")
        #expect(L10n.scoreFormat == "%d.%d 秒")
    }

    @Test("难度译名成中文且难度递增")
    func difficultyNamesAreChinese() {
        let names = Difficulty.allCases.map(\.menuTitle)
        #expect(names == ["初级", "中级", "专家", "大师", "宗师"])
        // 译名依据见 docs/中文化改造方案.md §2.4：
        // 前 3 档与 Windows 扫雷逐字节相同 → 锚定其官方中文名。
        #expect(Difficulty.middle.menuTitle == "中级", "16×16/40 = Windows Intermediate → 中级")
        #expect(Difficulty.expert.menuTitle == "专家", "30×16/99 = Windows Expert → 专家")
    }

    /// 应用名：**正式名为中文「扫雷 2000」，且原版名 `mine2000` 完整保留**。
    ///
    /// ⚠️ 背景（2026-10-22 查明的事实）：
    /// 原版 `mine2000.EXE` 的 PE 资源里 ProductName / FileDescription /
    /// InternalName / 窗口标题 / About 标题**全是 `mine2000`**，
    /// 二进制里**「Sweeper」一次都没出现过**。
    /// 本移植早前用的「MineSweeper 2000」是自行补写的，
    /// 现改为「扫雷 2000」；原版名保留在 `L10n.appNameOriginal` 供反查。
    @Test("应用名为「扫雷 2000」，原版名 mine2000 完整保留")
    func appNameIsChineseButOriginalPreserved() {
        #expect(L10n.appName == "扫雷 2000")
        #expect(L10n.appNameOriginal == "mine2000")
        // App 菜单三条文案都应带上正式名
        #expect(L10n.appMenuAbout == "关于 扫雷 2000")
        #expect(L10n.appMenuHide == "隐藏 扫雷 2000")
        #expect(L10n.appMenuQuit == "退出 扫雷 2000")
        // ⚠️ 正式名里**不得**出现 "Sweeper" —— 那是原版没有的词
        #expect(!L10n.appName.contains("Sweeper"), "正式名不应含 Sweeper：\(L10n.appName)")
        #expect(!L10n.appMenuAbout.contains("Sweeper"))
    }

    /// **最高分窗口不得显示日文默认名**（用户实测反馈）。
    ///
    /// 存档里的默认名是原版「名前なし」（字节级一致的基准，不能改），
    /// 但**界面**必须显示中文「匿名」—— 两层必须分开。
    @Test("最高分窗口把默认名显示为「匿名」，不漏日文")
    func highScoreWindowUsesChineseDefaultName() {
        let text = HighScoreWindowController.renderText(HighScoreTable())
        #expect(!text.contains("名前なし"), "最高分窗口不应出现日文默认名")
        #expect(text.contains("匿名"), "空记录应显示「匿名」")
        // 五个难度的节标题都应在（本地化名）
        for difficulty in Difficulty.allCases {
            #expect(text.contains("【\(difficulty.menuTitle)】"))
        }
    }

    /// **存档层仍保留原版默认名**（字节级一致），不能因为界面改中文而改动。
    @Test("存档默认名仍是原版「名前なし」（字节级基准不动）")
    func archiveDefaultNameStillOriginal() {
        #expect(M2KCodec.defaultName == "名前なし")
        // 空表的记录名就是它
        let table = HighScoreTable()
        #expect(table.scores(for: .beginner).first?.name == M2KCodec.defaultName)
        // 而界面显示名是中文
        #expect(L10n.anonymousName == "匿名")
    }
}
