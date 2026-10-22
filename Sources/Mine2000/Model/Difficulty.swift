import Foundation

/// 5 档难度。
///
/// ────────────────────────────────────────────────────────────────────────
/// **规格来源与置信度**
///
/// 本表的 `(列数, 行数, 地雷数)` 全部来自对原版 `mine2000.EXE` 的**反汇编实测**，
/// 而不是从截图反推，因此置信度高于早前报告里的「运行时内存扫描」数值。
///
/// 证据：`.text` 段 5 个关卡初始化函数，各自连续写入 3 个字段：
///
/// | 函数地址 | 等级字段 `+0x180` | 列数 `+0xC19C` | 行数 `+0xC198` | 地雷数 `+0xC194` | 菜单 |
/// |---|---|---|---|---|---|
/// | `0x4026D0` | 0 | `0x08` = 8  | `0x08` = 8  | `0x0A` = 10  | 初級 |
/// | `0x402730` | 1 | `0x10` = 16 | `0x10` = 16 | `0x28` = 40  | 中級 |
/// | `0x402790` | 2 | `0x1E` = 30 | `0x10` = 16 | `0x63` = 99  | 上級 |
/// | `0x4027F0` | 3 | `0x30` = 48 | `0x18` = 24 | `0x100` = 256 | 超上級 |
/// | `0x402850` | 4 | `0x40` = 64 | `0x30` = 48 | `0x309` = 777 | マニア |
///
/// 独立交叉验证（跳转表 `0x4013D8`，共 5 项）：
/// ```
/// [0] → 0x401303  (8, 8)      初級
/// [1] → 0x4012B4  (16, 16)    中級
/// [2] → 0x4012BF  (30, 16)    上級
/// [3] → 0x4012CE  (48, 24)    超上級
/// [4] → 0x4012DD  (64, 48)    マニア
/// ```
/// 两处独立代码路径给出一致的 5 组数值，互为佐证。
///
/// ────────────────────────────────────────────────────────────────────────
/// **与早前报告的差异（重要）**
///
/// 早前「运行时内存扫描」得到的数值是 *261 / 485 / 773 / 948*，与上表不符。
/// 反汇编给出的 10 / 40 / 99 / 256 / 777 恰好是 **Windows 经典扫雷
/// Beginner/Intermediate/Expert 的标准地雷数（10/40/99）**，并按比例延续到
/// 后两档，符合该系列作品的递增规律；而 261/485/773/948 与任何经典序列都
/// 对不上，且中級 16×16 = 256 格根本放不下 261 颗雷 —— 这本身就证明
/// 旧数值不可信。
///
/// 因此本实现以反汇编数值为准，并在 `文档/行为还原对照表.md` 中标注该冲突。
public enum Difficulty: Int, CaseIterable, Hashable, Sendable {
    /// 初級 —— 8 列 × 8 行，10 雷
    case beginner = 0
    /// 中級 —— 16 列 × 16 行，40 雷
    case middle = 1
    /// 上級 —— 30 列 × 16 行，99 雷
    case expert = 2
    /// 超上級 —— 48 列 × 24 行，256 雷
    case hiper = 3
    /// マニア —— 64 列 × 48 行，777 雷
    case mania = 4

    /// 菜单里显示的**中文**难度名。
    ///
    /// ────────────────────────────────────────────────────────────────────
    /// **[译名依据]** 见 `docs/中文化改造方案.md` §2.4。
    ///
    /// 关键事实：原版**中級 16×16/40** 与**上級 30×16/99** 与 Windows 扫雷
    /// 逐字节相同，故前 3 档锚定 Windows 官方中文名（初级 / 中级 / **专家**）；
    /// 后 2 档用「大师 / 宗师」承接「专家之上」，
    /// 构成「入门 → 进阶 → 专业 → 精通 → 登峰」的标准中文难度阶梯。
    ///
    /// ⚠️ 早前把「上級」直译为「高级」是**按字面译**而非**按难度认知译**，
    /// 已更正 —— Windows 里 30×16/99 官方就叫「专家」。
    /// ────────────────────────────────────────────────────────────────────
    public var menuTitle: String {
        switch self {
        case .beginner: return "初级"
        case .middle: return "中级"
        case .expert: return "专家"
        case .hiper: return "大师"
        case .mania: return "宗师"
        }
    }

    /// 菜单里显示的**原版日文**难度名（仅供对照与测试断言）。
    public var menuTitleOriginal: String {
        switch self {
        case .beginner: return "初級"
        case .middle: return "中級"
        case .expert: return "上級"
        case .hiper: return "超上級"
        case .mania: return "マニア"
        }
    }

    /// 菜单里显示的完整难度项文字：`专家（30×16，99 雷）`。
    ///
    /// 附带规模信息，让玩家一眼看出该档的面积与密度，不必逐档试玩。
    public var menuTitleWithScale: String {
        "\(menuTitle)（\(columns)×\(rows)，\(mineCount) 雷）"
    }

    /// 英文名，便于日志与文档引用。
    public var englishTitle: String {
        switch self {
        case .beginner: return "Beginner"
        case .middle: return "Middle"
        case .expert: return "Expert"
        case .hiper: return "Hiper"
        case .mania: return "Mania"
        }
    }

    /// 横向格数（列）。
    public var columns: Int {
        switch self {
        case .beginner: return 8
        case .middle: return 16
        case .expert: return 30
        case .hiper: return 48
        case .mania: return 64
        }
    }

    /// 纵向格数（行）。
    public var rows: Int {
        switch self {
        case .beginner: return 8
        case .middle: return 16
        case .expert: return 16
        case .hiper: return 24
        case .mania: return 48
        }
    }

    /// 地雷总数。
    public var mineCount: Int {
        switch self {
        case .beginner: return 10
        case .middle: return 40
        case .expert: return 99
        case .hiper: return 256
        case .mania: return 777
        }
    }

    /// 总格子数。
    public var cellCount: Int { columns * rows }

    /// 单个格子的像素边长。
    ///
    /// [已确证] 原版格子为 16×16 像素；反汇编中格子步进一律用
    /// `shl eax, 4`（×16）计算，例如 `0x401E1B: lea eax,[edx+edx*2]; shl eax,4`
    /// 即 行×3×16（每行 3 个 dword/格）。
    public static let cellSize = 16

    /// 棋盘区域的总像素宽度。
    public var boardPixelWidth: Int { columns * Self.cellSize }

    /// 棋盘区域的总像素高度。
    public var boardPixelHeight: Int { rows * Self.cellSize }
}
