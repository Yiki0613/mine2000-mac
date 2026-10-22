import Foundation

/// 计分格式。
///
/// ────────────────────────────────────────────────────────────────────────
/// **[已确证]** 原版计分单位为 **十分之一秒（0.1 s）**，显示为 `"%d.%d秒"`。
///
/// 证据（字节级）：
/// * `.rdata` 中 `0x408F60` 处的格式串明文为 `%d.%d秒`
///   （字节 `25 64 2e 25 64 95 62 00`；`95 62` 是 Shift-JIS 的「秒」）；
///   同区还有 `0x408F68` = `%d位にランクイン！！`（入榜提示）。
/// * 高分榜渲染 `0x401F32`：`idiv 0xA` → 商 = v/10，余数 = v%10，
///   依次 `push` 进 `sprintf("%d.%d秒", 商, 余数)`；
/// * 计时函数 `0x401C46`：`x * 0x51EB851F >> 37 == x / 100`（x 为毫秒差），
///   即 **毫秒 / 100 = 0.1 秒**，且 1000 ms → 10 单位，自洽。
///
/// 因此 `format(deciseconds: 1234)` → `"123.4秒"`。
///
/// > **注意**：早前实现把单位当成「百分之一秒」并输出 `"%d.%02d"`（无「秒」后缀），
/// > 与反汇编不符，已按字节证据修正。
/// ────────────────────────────────────────────────────────────────────────
public enum ScoreFormat {

    /// 把十分之一秒（0.1 s）格式化为原版的「秒.十分之一秒」字符串。
    ///
    /// - Parameter deciseconds: 成绩，单位十分之一秒。
    public static func format(deciseconds: Int) -> String {
        let value = min(max(deciseconds, 0), HighScoreEntry.maxScore)
        // 原版格式串为 "%d.%d"（第二项不补零）
        // ⚠️ 单位「秒」保留：原版为 Shift-JIS 的 `%d.%d秒`（字节 25 64 2e 25 64 95 62 00），
        //    本地化只在「秒」前后加空格，数字格式不变。
        return String(format: L10n.scoreFormat, value / 10, value % 10)
    }

    /// 把秒数转换为十分之一秒。
    public static func deciseconds(from seconds: TimeInterval) -> Int {
        HighScoreEntry.deciseconds(from: seconds)
    }

    /// 把十分之一秒转换为秒。
    public static func seconds(fromDeciseconds deciseconds: Int) -> TimeInterval {
        HighScoreEntry.seconds(fromDeciseconds: deciseconds)
    }
}

/// 一次游戏的会话状态（计时 + 表情 + 棋盘）。
///
/// 把「棋盘逻辑」与「时间/表情」聚合起来，供 AppKit 层直接驱动。
public final class GameSession {

    /// 当前棋盘。
    public private(set) var board: Board

    /// 随机源（可注入以便单测）。
    private var generator: any RandomNumberGenerator

    /// 计时基准时刻。
    ///
    /// ## 原版行为（反汇编 `0x401C46`）
    ///
    /// 计时 = `(timeGetTime() − [+0xC1A4]) / 100`，单位十分之一秒。
    /// `+0xC1A4`（基准）在 5 处「关卡初始化」被写（`0x401ED2`、`0x402717`、
    /// `0x402777`、`0x4027DA`、`0x40283A`、`0x40289A`），**第一次点击不重置**。
    ///
    /// 这意味着原版**严格说会把「关卡建立后到第一次点击之间」的等待时间算进成绩**。
    ///
    /// ⚠️ 本移植按用户 2026-10-22 的决定**改为第一次点击才起算**：
    /// 启动后发呆的时间不再计入。理由：符合所有扫雷的直觉，也更公平；
    /// 偏差仅出现在「启动后长时间不点第一格」这种非典型场景。
    /// 实现见 `markStartedIfNeeded(wasReady:)`。
    private var baselineDate: Date

    /// 冻结的最终用时（十分之一秒单位）；`nil` 表示尚未结束。
    private var frozenDeciseconds: Int?

    /// 是否已结束（胜或负）。
    public var isFinished: Bool { board.state.isFinished }

    /// 已用时（秒）。
    ///
    /// 胜负判定后**冻结**（原版在 `+0x190` 变为 3/4 时停止累加，
    /// 计时函数 `0x401C30` 的跳转表对 state 3/4 走 `0x401C64` 分支，
    /// 直接返回已存下的 `+0xC1A0` 值）。
    public var elapsed: TimeInterval {
        guard board.state != .ready else { return 0 }
        return HighScoreEntry.seconds(fromDeciseconds: elapsedDeciseconds)
    }

    /// 已用时（十分之一秒单位）。
    public var elapsedDeciseconds: Int {
        if let frozen = frozenDeciseconds { return frozen }
        // [已确证] 原版状态 1（未开始）时计时函数直接返回 0（`0x401C6C`）
        guard board.state != .ready else { return 0 }
        return HighScoreEntry.deciseconds(from: Date().timeIntervalSince(baselineDate))
    }

    /// 当前表情。
    public var expression: FaceExpression {
        FaceExpression.expression(for: board.state)
    }

    /// 剩余雷数显示值。
    public var remainingMines: Int { board.remainingMines }

    /// 成绩（十分之一秒）。
    public var scoreDeciseconds: Int { elapsedDeciseconds }

    /// 格式化后的成绩（秒.十分之一秒）。
    public var scoreText: String { ScoreFormat.format(deciseconds: scoreDeciseconds) }

    /// 初始化。
    public init(
        difficulty: Difficulty,
        generator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.board = Board(difficulty: difficulty, generator: generator)
        self.generator = generator
        self.baselineDate = Date()
    }

    /// 换难度 → 全新一局。
    public func restart(difficulty: Difficulty) {
        board = Board(difficulty: difficulty, generator: generator)
        baselineDate = Date()
        frozenDeciseconds = nil
    }

    /// 重新开始当前难度。
    public func restart() {
        restart(difficulty: board.difficulty)
    }

    /// 左键：翻开一个格子。
    @discardableResult
    public func reveal(row: Int, column: Int) -> RevealOutcome {
        let wasReady = board.state == .ready
        let outcome = board.reveal(row: row, column: column)
        markStartedIfNeeded(wasReady: wasReady)
        freezeTimerIfFinished()
        return outcome
    }

    /// 右键：插旗 / 取消插旗。
    @discardableResult
    public func toggleFlag(row: Int, column: Int) -> Bool {
        let wasReady = board.state == .ready
        let changed = board.toggleFlag(row: row, column: column)
        markStartedIfNeeded(wasReady: wasReady)
        freezeTimerIfFinished()
        return changed
    }

    /// 中键 / 左右同按：扫雷（chording）。
    @discardableResult
    public func chord(row: Int, column: Int) -> Int {
        let wasReady = board.state == .ready
        let opened = board.chord(row: row, column: column)
        markStartedIfNeeded(wasReady: wasReady)
        freezeTimerIfFinished()
        return opened
    }

    /// 冻结计时（游戏结束时调用）。
    public func stopTimer() {
        freezeTimerIfFinished()
    }

    /// 测试用：直接设定已用时。
    public func setElapsedForTesting(_ seconds: TimeInterval) {
        frozenDeciseconds = HighScoreEntry.deciseconds(from: seconds)
    }

    /// 测试用：强制结束计时。
    public func freezeTimerForTesting() {
        freezeTimerIfFinished()
    }

    /// 第一次操作让局面离开「未开始」时，把计时基准重置为当下。
    ///
    /// ⚠️ 这是**本移植与原版的唯一有意偏差**（用户 2026-10-22 拍板）：
    /// 原版基准取在「关卡建立」时刻，启动后发呆的时间会计入成绩；
    /// 本实现改为「第一次点击/插旗才起算」，`elapsedDeciseconds` 从 0 开始涨。
    ///
    /// - Parameter wasReady: 本次操作**之前**是否处于未开始状态。
    private func markStartedIfNeeded(wasReady: Bool) {
        guard wasReady, board.state != .ready else { return }
        baselineDate = Date()
    }

    /// 结束时冻结计时。
    ///
    /// - [已确证] 原版在胜负判定后写 `+0xC1A0`（最终用时），
    ///   之后计时函数（状态 3 / 4）直接返回该冻结值，不再随时间增长。
    private func freezeTimerIfFinished() {
        guard board.state.isFinished, frozenDeciseconds == nil else { return }
        frozenDeciseconds = HighScoreEntry.deciseconds(
            from: Date().timeIntervalSince(baselineDate)
        )
    }
}
