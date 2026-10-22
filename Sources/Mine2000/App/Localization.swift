import Foundation

/// 界面文案集中管理（本地化）。
///
/// ## 为什么要有这一层
///
/// 原版 Windows 版界面是日文，本移植按「技术复刻」定位先把原版日文原样搬了过来；
/// 2026-10-22 起改为**全中文界面**。
///
/// 但**还原度必须保留**：原版的日文原文与菜单 ID 体系仍是行为规格的一部分，
/// 日后要能逐项对账。因此本文件同时保存
/// **「原版日文」** 与 **「本地化显示」** 两列，
/// 源码注释、行为还原对照表与单元测试都引用这里的常量。
///
/// ## 命名约定
///
/// * `xxx` 系列 —— 本地化后的显示文案（**代码里用这个**）；
/// * `xxxOriginal` 系列 —— 原版日文原文（**仅供对照与测试断言**）。
///
/// ## 难度译名的依据
///
/// 见 `docs/中文化改造方案.md` §2.4：
/// 原版中級 16×16/40、上級 30×16/99 与 Windows 扫雷**逐字节相同**，
/// 故前 3 档锚定 Windows 官方中文名（初级 / 中级 / **专家**），
/// 后 2 档用「大师 / 宗师」承接「专家之上」。
public enum L10n {

    // MARK: - 顶级菜单

    /// 顶级菜单：ゲーム → 游戏
    public static let gameMenu = "游戏"
    /// 顶级菜单：ゲーム → 游戏（原版日文）
    public static let gameMenuOriginal = "ゲーム"

    /// 顶级菜单：難易度 → 难度
    public static let difficultyMenu = "难度"
    /// 顶级菜单：難易度 → 难度（原版日文）
    public static let difficultyMenuOriginal = "難易度"

    /// 顶级菜单：ハイスコア → 最高分
    public static let highScoreMenu = "最高分"
    /// 顶级菜单：ハイスコア → 最高分（原版日文）
    public static let highScoreMenuOriginal = "ハイスコア"

    /// 顶级菜单：ヘルプ → 帮助
    public static let helpMenu = "帮助"
    /// 顶级菜单：ヘルプ → 帮助（原版日文）
    public static let helpMenuOriginal = "ヘルプ"

    // MARK: - 菜单项

    /// メニュー项：ゲームスタート → 开始新局
    public static let startNewGame = "开始新局"
    /// メニュー项：ゲームスタート → 开始新局（原版日文）
    public static let startNewGameOriginal = "ゲームスタート"

    /// メニュー项：ハイスコアの表示 → 查看最高分
    public static let showHighScores = "查看最高分"
    /// メニュー项：ハイスコアの表示 → 查看最高分（原版日文）
    public static let showHighScoresOriginal = "ハイスコアの表示"

    /// メニュー项：ハイスコアのインポート → 导入最高分
    public static let importHighScores = "导入最高分"
    /// メニュー项：ハイスコアのインポート → 导入最高分（原版日文）
    public static let importHighScoresOriginal = "ハイスコアのインポート"

    /// メニュー项：ハイスコアのエクスポート → 导出最高分
    public static let exportHighScores = "导出最高分"
    /// メニュー项：ハイスコアのエクスポート → 导出最高分（原版日文）
    public static let exportHighScoresOriginal = "ハイスコアのエクスポート"

    /// メニュー项：ゲームの終了 → 退出游戏
    public static let quitGame = "退出游戏"
    /// メニュー项：ゲームの終了 → 退出游戏（原版日文）
    public static let quitGameOriginal = "ゲームの終了"

    /// メニュー项：バージョン情報... → 版本信息...
    public static let about = "版本信息..."
    /// メニュー项：バージョン情報... → 版本信息...（原版日文）
    public static let aboutOriginal = "バージョン情報..."

    // MARK: - 应用名

    /// 应用正式名称（菜单栏最左、窗口标题、About 面板共用）。
    ///
    /// ## 命名依据（2026-10-22 定稿）
    ///
    /// 原版 `mine2000.EXE` 的 PE 资源里，**产品名从头到尾就是 `mine2000`**：
    ///
    /// | 资源字段 | 原版值 |
    /// |---|---|
    /// | `ProductName` | `mine2000` |
    /// | `FileDescription` | `mine2000` |
    /// | `InternalName` | `mine2000` |
    /// | `OriginalFilename` | `mine2000.EXE` |
    /// | 窗口标题（STRING ID 128） | `mine2000` |
    /// | About 对话框标题 | `mine2000` |
    /// | About 对话框正文 | `2000 Version 2.2.1` / `Copyright (C) 1999-2005` |
    ///
    /// 二进制里**「Sweeper」这个词一次都没出现过**。
    /// 本移植早前用的「MineSweeper 2000」是自行补写的（为了让访达里能看出是什么游戏），
    /// 于 2026-10-22 改为**「扫雷 2000」**：中文直白、保留 2000 这一世代标识
    /// （对应原版权跨度 1999–2005 与版本号 2.21）。
    ///
    /// 原版名保留在 `appNameOriginal`，供还原度反查。
    public static let appName = "扫雷 2000"

    /// 原版应用名（仅供对照与测试断言，不显示给用户）
    public static let appNameOriginal = "mine2000"

    // MARK: - App 菜单（macOS 惯用项，原版 Windows 无对应物）

    /// App 菜单 → 关于
    public static var appMenuAbout: String { "关于 \(appName)" }

    /// App 菜单 → 隐藏
    public static var appMenuHide: String { "隐藏 \(appName)" }

    /// App 菜单 → 退出
    public static var appMenuQuit: String { "退出 \(appName)" }

    // MARK: - 对话框与提示

    /// 入榜提示：%d位にランクイン！！ → 恭喜！排名第 %d 位！！
    public static func rankInMessage(rank: Int) -> String {
        "恭喜！排名第 \(rank) 位！！"
    }

    /// 入榜提示原版日文（仅供对照）
    public static func rankInMessageOriginal(rank: Int) -> String {
        String(format: "%d位にランクイン！！", rank)
    }

    /// 名字输入提示：名前を入力してください → 请输入名字
    public static let enterNamePrompt = "请输入名字"

    /// 名字输入框占位符：名前なし → 匿名
    public static let anonymousName = "匿名"

    /// 按钮：キャンセル → 取消
    public static let cancel = "取消"

    /// 按钮：OK → 确定
    public static let ok = "确定"

    /// 文件对话框：読み込む .m2k ファイルを選択してください → 请选择要导入的 .m2k 文件
    public static let importFilePrompt = "请选择要导入的 .m2k 文件"

    /// 文件对话框：保存する .m2k ファイル名を入力してください → 请输入要导出的 .m2k 文件名
    public static let exportFilePrompt = "请输入要导出的 .m2k 文件名"

    /// 错误提示：インポートに失敗しました → 导入失败
    public static let importFailed = "导入失败"

    /// 错误提示：エクスポートに失敗しました → 导出失败
    public static let exportFailed = "导出失败"

    /// 导出降级提示（中文名无法用 Shift-JIS 表示）
    public static let exportDowngradeNotice = "部分名字含中文，导出到 .m2k 时已替换为 Yiki（原版格式仅支持 Shift-JIS）。"

    // MARK: - 计分格式

    /// 计分格式：%d.%d秒 → %d.%d 秒
    ///
    /// 保留「秒」的单位语义，与原版格式串 `"%d.%d秒"` 逐字节对应
    /// （原版为 Shift-JIS 的「秒」= `95 62`）。
    public static let scoreFormat = "%d.%d 秒"

    /// 计分格式原版日文（仅供对照）
    public static let scoreFormatOriginal = "%d.%d秒"
}
