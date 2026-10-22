import Foundation

/// 游戏状态机。
///
/// ────────────────────────────────────────────────────────────────────────
/// **规格来源（[已确证]）**
///
/// 原版把状态存在结构体偏移 `+0x190` 的一个 `dword` 里，取值 **1..4**。
/// 该字段的写入点（全部为 `mov dword ptr [esi + 0x190], imm`）：
///
/// | VA | 写入值 | 语义 | 上下文 |
/// |---|---|---|---|
/// | `0x401EB8` | 1 | 未开始 | 重新开局：清棋盘 → 置 1 → 清零 `+0xC1A0` → 取 `timeGetTime()` 存入 `+0xC1A4` |
/// | `0x4026FD` / `0x40275D` / `0x4027C0` / `0x402820` / `0x402880` | 1 | 未开始 | 5 个难度各自的初始化函数（同上序列） |
/// | `0x40453B` | 2 | 游戏中 | 首次左键按下后 |
/// | `0x40252D` | 3 | 胜利 | 判定通关后；同时写 `+0xC1A0`（最终用时）并与高分榜比较 |
/// | `0x402940` | 4 | 失败 | 踩雷后；同时写 `+0xC1A0`（最终用时） |
///
/// 计时器取值函数 `0x401C30` 也按同一字段分派（跳转表 `0x401C70`）：
///
/// | `+0x190` | 跳转目标 | 行为 |
/// |---|---|---|
/// | 1（未开始） | `0x401C6C` | 直接 `xor eax,eax; ret` → **返回 0**（未开局不计时） |
/// | 2（游戏中） | `0x401C46` | `timeGetTime()` 差值 `* 0x51EB851F >> 37`，即 **毫秒差 / 100** |
/// | 3（胜利） | `0x401C64` | 返回 `+0xC1A0`（冻结的最终用时） |
/// | 4（失败） | `0x401C64` | 返回 `+0xC1A0`（冻结的最终用时） |
///
/// 因此本枚举的 `originalFieldValue` 与上表严格一一对应。
/// ────────────────────────────────────────────────────────────────────────
public enum GameState: Equatable, Sendable {
    /// 未开始（等待第一次点击）。对应原版 `+0x190 == 1`。
    case ready
    /// 游戏中。对应原版 `+0x190 == 2`。
    case playing
    /// 胜利（全部翻开）。对应原版 `+0x190 == 3`。
    case won
    /// 失败（踩到雷）。对应原版 `+0x190 == 4`。
    case lost

    /// 原版内部字段 `+0x190` 的取值（用于对齐原版语义）。
    ///
    /// - [已确证] 映射来自上表列出的 8 处写入点：
    ///   `1`（`0x401EB8` + 5 个难度初始化）、`2`（`0x40453B`）、
    ///   `3`（`0x40252D`）、`4`（`0x402940`）。
    public var originalFieldValue: Int {
        switch self {
        case .ready: return 1
        case .playing: return 2
        case .won: return 3
        case .lost: return 4
        }
    }

    /// 是否已结束（胜或负）。
    public var isFinished: Bool {
        self == .won || self == .lost
    }
}

/// 表情（对应图集区域 C 的 5 个 26×26 笑脸图块）。
///
/// ────────────────────────────────────────────────────────────────────────
/// **槽位与含义（[已确证]）**
///
/// 图集区域 C 在 `y = 55..80`，每个笑脸 26×26，横向步进 26 像素。
/// 原版绘制表情时用 `BitBlt` 从这里取图，**源 x 坐标**决定了画哪一张：
///
/// | 槽位 | 源 x | 含义 | 原版使用位置 |
/// |---|---|---|---|
/// | 0 | `0x00` | 正常微笑 | `0x40389D`（未开始 / 游戏中，鼠标未按下） |
/// | 1 | `0x1A` | 戴墨镜（胜利） | `0x403974`（状态 3 = 胜利） |
/// | 2 | `0x34` | X 眼（踩雷失败） | `0x4039A2`（状态 4 = 失败） |
/// | 3 | `0x4E` | 惊讶（张嘴 O 形） | `0x4038FA`（鼠标在棋盘上按下时） |
/// | 4 | `0x68` | 备用正常脸 | `0x4038C2`（鼠标不在棋盘范围内时） |
///
/// 表情选择由**状态 + 鼠标**共同决定，见 `FaceState`。
/// ────────────────────────────────────────────────────────────────────────
public enum FaceExpression: Int, CaseIterable, Sendable {
    /// 槽 0：正常微笑。
    case normal = 0
    /// 槽 1：胜利（戴墨镜）。
    case win = 1
    /// 槽 2：踩雷失败（X 眼，皱眉）。
    case lose = 2
    /// 槽 3：惊讶（张嘴 O 形，鼠标按下时）。
    case surprise = 3
    /// 槽 4：备用正常脸（鼠标不在棋盘上时）。
    case idle = 4

    /// 图集中的横向像素偏移（槽位 × 26）。
    public var sourceX: Int { rawValue * 26 }

    /// 根据游戏状态选择应显示的表情（不含鼠标因素）。
    ///
    /// - [已确证] 原版表情跳转表 `0x403A1C` 只有 4 项：
    ///   状态 1 → `0x40388E`、状态 2 → `0x40388E`、状态 3 → `0x40391F`、状态 4 → `0x403978`。
    ///   可见**「未开始」与「游戏中」共用同一条绘制分支**（两者都只在鼠标按下时才切到惊讶脸），
    ///   而胜利 / 失败各有专属分支。
    public static func expression(for state: GameState) -> FaceExpression {
        switch state {
        case .ready: return .normal
        case .playing: return .normal
        case .won: return .win
        case .lost: return .lose
        }
    }
}

/// 表情状态机（5 态）。
///
/// ────────────────────────────────────────────────────────────────────────
/// **为什么需要它**
///
/// 原版的表情不是由「游戏状态」单独决定的，而是 **游戏状态 × 鼠标状态** 的组合：
/// 绘制代码在 `0x403877` 处读 `+0x190`（游戏状态）跳转到 4 个分支之一，
/// 每个分支内部再读 `+0x90`（鼠标按键状态）与 `+0x88` / `+0x8C`（鼠标坐标，`-2` 表示在棋盘外）。
///
/// 由此可以得到原版实际会画出的 **5 种**表情：
///
/// | 条件 | 源 x | 图块 |
/// |---|---|---|
/// | 未开始 / 游戏中，鼠标未在棋盘上按下 | `0x00` | 正常微笑 |
/// | 未开始 / 游戏中，鼠标在棋盘上按下 | `0x4E` | 惊讶（O 形嘴） |
/// | 未开始 / 游戏中，鼠标在棋盘范围外 | `0x68` | 备用正常脸 |
/// | 胜利 | `0x1A` | 戴墨镜 |
/// | 失败 | `0x34` | X 眼 |
///
/// 本枚举把上述 5 种组合显式建模，UI 层只需给出「游戏状态 + 鼠标是否按下 + 鼠标是否在棋盘内」。
/// ────────────────────────────────────────────────────────────────────────
public enum FaceState: Equatable, Sendable {
    /// 未开始（对应原版 `+0x190 == 1`）。
    case notStarted
    /// 游戏中（对应原版 `+0x190 == 2`）。
    case playing
    /// 胜利（对应原版 `+0x190 == 3`）。
    case won
    /// 失败（对应原版 `+0x190 == 4`）。
    case lost
    /// 惊讶：鼠标在棋盘上按下（不改变游戏状态，只是叠加的表情）。
    case surprised

    /// 构造表情状态。
    ///
    /// - Parameters:
    ///   - gameState: 当前游戏状态。
    ///   - mousePressed: 鼠标按键是否处于按下状态（原版字段 `+0x90`）。
    ///   - mouseOnBoard: 鼠标是否位于棋盘范围内（原版字段 `+0x88` / `+0x8C` 不为 `-2`）。
    public init(gameState: GameState, mousePressed: Bool, mouseOnBoard: Bool) {
        switch gameState {
        case .won:
            self = .won
        case .lost:
            self = .lost
        case .ready:
            // [已确证] 未开始与游戏中在原版中共用同一分支（跳转表 0x403A1C 的两项相同），
            // 差别只在于「未开始」时计时器返回 0。
            self = (mousePressed && mouseOnBoard) ? .surprised : .notStarted
        case .playing:
            self = (mousePressed && mouseOnBoard) ? .surprised : .playing
        }
    }

    /// 该表情状态对应的图集槽位。
    public var expression: FaceExpression {
        switch self {
        case .notStarted: return .normal
        case .playing: return .normal
        case .won: return .win
        case .lost: return .lose
        case .surprised: return .surprise
        }
    }

    /// 是否为「鼠标在棋盘上按下」的惊讶表情。
    public var isSurprised: Bool { self == .surprised }
}
