import Foundation

/// 一次翻开操作的结果。
public enum RevealOutcome: Equatable, Sendable {
    /// 翻开了空白区，本次共翻开 `count` 个格子（**含起始格**）。
    ///
    /// 不变量：`count == revealedCount` 的增量。
    case expanded(count: Int)
    /// 翻开了一个带数字的格子。
    case revealedNumber(adjacentMines: Int)
    /// 踩到雷，游戏结束。
    case hitMine
    /// 该格子已被翻开或已插旗，无事发生。
    case ignored
}

/// 扫雷棋盘（纯逻辑，不依赖 AppKit，可直接单测）。
///
/// ────────────────────────────────────────────────────────────────────────
/// **与原版行为对齐的关键点**
///
/// 1. **首点保护（已确证）**
///    原版的布雷函数（`0x401800`）在放置每颗雷时，会把随机出的
///    `(列, 行)` 与「本次首次点击的格子」比较，相等则跳过该位置：
///    ```
///    0x401844  cmp esi, [esp+0x14]   ; 随机列 vs 首点列
///    0x401848  jne 0x401850
///    0x40184A  cmp edx, [esp+0x18]   ; 随机行 vs 首点行
///    0x40184E  je  0x401874          ; 相同则换位置
///    ```
///    即：**只有首点所在的那一格被保护**，而不是整个 3×3 邻域。
///    因此首击**可能只翻开 1 格**（周围有雷时），原版没有「保证展开一片」的逻辑。
///    本实现严格照此行为（只保护首点格），不擅自扩大保护范围。
///
/// 2. **布雷时机（已确证）**
///    原版在关卡初始化时只清空棋盘（`0x401890` 循环清 64×48 个格子），
///    真正的布雷发生在**玩家首次点击时**（布雷函数带首点坐标参数）。
///    因此换档后棋盘上初始没有任何雷。
///
/// 3. **布雷算法（已确证）**
///    `列 = rand() % 列数`、`行 = rand() % 行数`，若该格已被占则重试；
///    循环直到放满 `地雷数` 颗为止。
///
/// 4. **相邻雷数（已确证）**
///    原版用 3×3 邻域遍历统计（`0x401E3A` 起的外层 `列-1..列+1`、
///    内层 `行-1..行+1` 双重循环），统计非零格子数。
/// ────────────────────────────────────────────────────────────────────────
public final class Board {

    // MARK: - 规格

    /// 当前难度。
    public let difficulty: Difficulty

    /// 横向格数（列）。
    public let columns: Int

    /// 纵向格数（行）。
    public let rows: Int

    /// 地雷总数。
    public let mineCount: Int

    /// 总格子数。
    public var cellCount: Int { columns * rows }

    // MARK: - 运行状态

    /// 当前游戏状态。
    public private(set) var state: GameState = .ready

    /// 已插旗数量。
    public private(set) var flagsPlaced: Int = 0

    /// 已翻开的格子数量。
    public private(set) var revealedCount: Int = 0

    /// 是否已经布雷（首点后为 true）。
    public private(set) var minesPlaced: Bool = false

    /// 剩余可显示的雷数 = 地雷总数 − 已插旗数。
    public var remainingMines: Int { mineCount - flagsPlaced }

    /// 刚踩中的那颗雷的位置（失败时用于高亮显示）。
    ///
    /// - [已确证] 图集区域 A 第 1 行第 3 列是「地雷 + 红底高亮」专用图块，
    ///   说明原版失败时会**特别标出刚踩中的那一颗**。
    public private(set) var hitMinePosition: (row: Int, column: Int)?

    /// 失败时插错旗的格子集合（渲染时画 X 标记）。
    ///
    /// - [已确证] 图集区域 A 第 1 行第 4 列是「地雷 + 红色 X」图块，
    ///   这是 Windows 扫雷「旗插错」的标准表现，原版图集里同样存在。
    public private(set) var wrongFlagPositions: Set<Int> = []

    // MARK: - 内部

    /// 格子数据，按行优先展开。
    private var cells: [Cell]

    /// 随机源，可注入以便单测复现。
    private var generator: any RandomNumberGenerator

    // MARK: - 初始化

    /// 创建一块空白棋盘（尚未布雷）。
    ///
    /// - Parameters:
    ///   - difficulty: 难度规格。
    ///   - generator: 随机源；默认使用系统随机，单测可注入固定种子。
    public init(
        difficulty: Difficulty,
        generator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.difficulty = difficulty
        self.columns = difficulty.columns
        self.rows = difficulty.rows
        self.mineCount = difficulty.mineCount
        self.cells = Array(repeating: Cell(), count: difficulty.cellCount)
        self.generator = generator
    }

    // MARK: - 访问

    /// 取得指定格子；坐标越界返回 nil。
    public func cell(row: Int, column: Int) -> Cell? {
        guard isValid(row: row, column: column) else { return nil }
        return cells[index(row: row, column: column)]
    }

    /// 坐标是否在棋盘内。
    public func isValid(row: Int, column: Int) -> Bool {
        row >= 0 && row < rows && column >= 0 && column < columns
    }

    /// 全部格子（按行优先展开），供渲染层直接使用。
    public var allCells: [Cell] { cells }

    // MARK: - 操作

    /// 翻开一个格子。
    ///
    /// 首次调用时会先布雷，并保证首点格不含雷。
    ///
    /// 结束后（胜或负）本方法不再改变棋盘。
    @discardableResult
    public func reveal(row: Int, column: Int) -> RevealOutcome {
        guard isValid(row: row, column: column) else { return .ignored }

        // 结束态锁定：胜负已分，棋盘不再变化。
        if state.isFinished { return .ignored }

        let i = index(row: row, column: column)

        // 已插旗的格子不能被翻开
        if cells[i].isFlagged { return .ignored }
        // 已翻开的格子不重复处理
        if cells[i].isRevealed {
            return cells[i].containsMine ? .hitMine : .ignored
        }

        // 首点：先布雷（保护首点格）
        if !minesPlaced {
            placeMines(excludingRow: row, excludingColumn: column)
            minesPlaced = true
            state = .playing
        }

        // 踩雷
        if cells[i].containsMine {
            cells[i].isRevealed = true
            revealedCount += 1
            state = .lost
            hitMinePosition = (row, column)
            computeWrongFlags()
            return .hitMine
        }

        // 翻开并统计
        cells[i].isRevealed = true
        revealedCount += 1

        if cells[i].adjacentMineCount == 0 {
            // 空白区 → 连锁展开
            // ⚠️ `expandFrom` 返回的是「新翻开的格数」，**不含起始格**
            //    （起始格在上方已单独 `revealedCount += 1`）。
            //    而 `RevealOutcome.expanded(count:)` 的文档语义是「本次翻开的总格数（含起始格）」，
            //    故此处 +1，保证 `count == revealedCount 增量` 这一不变量成立。
            let expanded = expandFrom(row: row, column: column) + 1
            checkWin()
            return .expanded(count: expanded)
        }

        checkWin()
        return .revealedNumber(adjacentMines: cells[i].adjacentMineCount)
    }

    /// 切换一个格子的旗子状态。
    ///
    /// 已翻开的格子不能插旗；胜负已分后不再改变棋盘。
    @discardableResult
    public func toggleFlag(row: Int, column: Int) -> Bool {
        guard isValid(row: row, column: column) else { return false }

        // 结束态锁定：胜负已分，棋盘不再变化。
        if state.isFinished { return false }

        let i = index(row: row, column: column)
        guard !cells[i].isRevealed else { return false }

        if cells[i].isFlagged {
            cells[i].isFlagged = false
            flagsPlaced -= 1
        } else {
            cells[i].isFlagged = true
            flagsPlaced += 1
        }
        return true
    }

    /// 扫雷（chording）：在一个已翻开、且周围旗数与周围雷数相同的数字格上，
    /// 一次性翻开其周围所有未插旗的未翻开格。
    ///
    /// ────────────────────────────────────────────────────────────────────
    /// **[已确证]** 触发条件为 **旗数 == 该格数字 且 旗数 ≠ 0**，
    /// 随后翻开周围 8 格（原版有两个 3×3 邻域统计函数：数雷 / 数旗，
    /// chording 用的是「数旗」那个）。
    ///
    /// - Returns: 本次新翻开的格子数量（0 表示条件不满足或无变化）。
    @discardableResult
    public func chord(row: Int, column: Int) -> Int {
        guard isValid(row: row, column: column) else { return 0 }
        // 只能在进行中的棋盘上操作
        guard state == .playing else { return 0 }

        let i = index(row: row, column: column)
        let target = cells[i]
        // 必须是已翻开、非雷、且带数字的格子
        guard target.isRevealed, !target.containsMine, target.adjacentMineCount > 0 else {
            return 0
        }

        // 统计周围的旗数与未翻开格数
        var flagsAround = 0
        var hiddenNeighbours: [(Int, Int)] = []
        for dr in -1...1 {
            for dc in -1...1 {
                if dr == 0 && dc == 0 { continue }
                let nr = row + dr, nc = column + dc
                guard isValid(row: nr, column: nc) else { continue }
                let neighbour = cells[index(row: nr, column: nc)]
                if neighbour.isFlagged {
                    flagsAround += 1
                } else if !neighbour.isRevealed {
                    hiddenNeighbours.append((nr, nc))
                }
            }
        }

        // 旗数与该格显示的雷数不一致 → 不触发
        // [已确证] 条件为「旗数 == 数字 且 旗数 ≠ 0」
        guard flagsAround == target.adjacentMineCount, flagsAround != 0 else { return 0 }

        // 翻开所有未插旗的未翻开邻格
        var opened = 0
        for (nr, nc) in hiddenNeighbours {
            let j = index(row: nr, column: nc)
            guard !cells[j].isRevealed, !cells[j].isFlagged else { continue }
            if cells[j].containsMine {
                // 扫雷踩到雷 → 失败
                cells[j].isRevealed = true
                revealedCount += 1
                state = .lost
                return opened
            }
            cells[j].isRevealed = true
            revealedCount += 1
            opened += 1
            // 若展开的是空白区，继续连锁展开
            if cells[j].adjacentMineCount == 0 {
                opened += expandFrom(row: nr, column: nc)
            }
        }

        if opened > 0 { checkWin() }
        return opened
    }

    /// 是否已胜利（所有非雷格都已翻开）。
    public var isWon: Bool {
        state == .won
    }

    // MARK: - 内部实现

    /// 失败时标记插错旗的格子（渲染时画 X 标记）。
    ///
    /// - [已确证] 图集区域 A 第 1 行提供了两个专用图块：
    ///   - 第 3 列 =「地雷 + 红底高亮」→ 用于标出**刚踩中的那颗雷**；
    ///   - 第 4 列 =「地雷 + 红色 X」→ 用于标出**插错旗的格子**。
    ///
    ///   这两个图块只有在「失败时揭示全部地雷」的行为下才有意义，
    ///   因此原版必然执行了这一步。
    ///
    ///   本方法**只记录展示信息**，不修改任何格子的 `isRevealed`：
    ///   「是否翻开」是玩家操作的结果，失败时一次性揭示全部地雷属于
    ///   展示层行为，由渲染层根据 `state == .lost` 决定。
    private func computeWrongFlags() {
        wrongFlagPositions.removeAll()
        for row in 0..<rows {
            for column in 0..<columns {
                let i = index(row: row, column: column)
                if !cells[i].containsMine && cells[i].isFlagged {
                    // 旗插在了不是雷的格子上 → 渲染时画 X 标记
                    wrongFlagPositions.insert(i)
                }
            }
        }
    }

    /// 渲染用：某格是否「插错了旗」（失败时才有意义）。
    ///
    /// - [已确证] 依据图集区域 A 第 1 行第 4 列的「地雷 + 红色 X」图块。
    public func isWrongFlag(row: Int, column: Int) -> Bool {
        guard isValid(row: row, column: column) else { return false }
        return wrongFlagPositions.contains(index(row: row, column: column))
    }

    /// 渲染用：某格是否为「刚踩中的那颗雷」（失败时才有意义）。
    ///
    /// - [已确证] 依据图集区域 A 第 1 行第 3 列的「地雷 + 红底高亮」图块。
    public func isHitMine(row: Int, column: Int) -> Bool {
        guard let hit = hitMinePosition else { return false }
        return hit.row == row && hit.column == column
    }

    /// 行优先索引。
    private func index(row: Int, column: Int) -> Int {
        row * columns + column
    }

    /// 布雷。
    ///
    /// 与原版一致：`列 = rand() % columns`、`行 = rand() % rows`，
    /// 跳过首点格与已占用的格子。
    private func placeMines(excludingRow: Int, excludingColumn: Int) {
        var placed = 0
        var attempts = 0
        // 尝试次数上限：按格子数的平方级别给足余量，避免极端情况下死循环
        let maxAttempts = max(1000, cells.count * 32)

        while placed < mineCount && attempts < maxAttempts {
            attempts += 1

            let c = Int.random(in: 0..<columns, using: &generator)
            let r = Int.random(in: 0..<rows, using: &generator)

            // 首点保护：只保护首点所在的那一格
            if r == excludingRow && c == excludingColumn { continue }

            let i = index(row: r, column: c)
            if cells[i].containsMine { continue }

            cells[i].containsMine = true
            placed += 1
        }

        computeAdjacentMineCounts()
    }

    /// 计算所有格子的相邻雷数（3×3 邻域）。
    private func computeAdjacentMineCounts() {
        for r in 0..<rows {
            for c in 0..<columns {
                let i = index(row: r, column: c)
                guard !cells[i].containsMine else {
                    cells[i].adjacentMineCount = 0
                    continue
                }
                var count = 0
                for dr in -1...1 {
                    for dc in -1...1 {
                        if dr == 0 && dc == 0 { continue }
                        let nr = r + dr
                        let nc = c + dc
                        guard isValid(row: nr, column: nc) else { continue }
                        if cells[index(row: nr, column: nc)].containsMine { count += 1 }
                    }
                }
                cells[i].adjacentMineCount = count
            }
        }
    }

    /// 从一个空白格开始连锁展开（flood fill）。
    ///
    /// 使用显式栈而非递归，避免大棋盘上的栈深度问题。
    ///
    /// ────────────────────────────────────────────────────────────────────
    /// **[已确证] 展开邻域 = 8 邻（3×3）**
    ///
    /// 反汇编 `0x4028B0`（expand 函数）：
    /// ```
    /// 00402967  lea       eax, [edi + 1]      ; x+1
    /// 0040296a  lea       ebx, [edi - 1]      ; x-1
    /// 00402975  lea       edx, [ebp - 1]      ; y-1
    /// 0040297c  inc       ebp                ; y+1
    /// 00402988  push      edi                ; 内层：x 从 x-1 遍历到 x+1
    /// 0040298c  call      0x4028b0           ;   递归展开
    /// 0040299a  inc       ebx                ; 外层：y 从 y-1 遍历到 y+1
    /// 0040299d  jle       0x402980
    /// ```
    /// 即 **x、y 各遍历 3 个值 → 3×3 = 8 邻域**（含 4 个对角）。
    /// 展开条件：该格周围雷数 == 0（`0x402914 test eax,eax` / `je 0x402951`）。
    ///
    /// > 注：早前《原版内部结构_反汇编确证》把此处记作「展开四邻」，
    /// > 那是把 3×3 循环误读为十字形；**按字节复核后更正为 8 邻**。
    /// > 本实现与之一致。
    /// ────────────────────────────────────────────────────────────────────
    ///
    /// - Returns: 本次**新翻开**的格子数（**不含起始格**，起始格由调用方负责）。
    private func expandFrom(row: Int, column: Int) -> Int {
        var stack: [(Int, Int)] = [(row, column)]
        var newlyRevealed = 0

        while let (r, c) = stack.popLast() {
            for dr in -1...1 {
                for dc in -1...1 {
                    if dr == 0 && dc == 0 { continue }
                    let nr = r + dr
                    let nc = c + dc
                    guard isValid(row: nr, column: nc) else { continue }
                    let j = index(row: nr, column: nc)
                    guard !cells[j].isRevealed, !cells[j].isFlagged else { continue }
                    guard !cells[j].containsMine else { continue }
                    cells[j].isRevealed = true
                    revealedCount += 1
                    newlyRevealed += 1
                    // 只有空白格（周围无雷）才继续向外扩散
                    if cells[j].adjacentMineCount == 0 {
                        stack.append((nr, nc))
                    }
                }
            }
        }
        return newlyRevealed
    }

    /// 判定是否胜利。
    ///
    /// ────────────────────────────────────────────────────────────────────
    /// **[已确证]** 原版的胜利判定是 **未翻开格数 == 雷数**
    /// （反汇编 `0x4029DF`：`cmp eax, [esi+0xC194]`，
    ///  `0xC194` 即雷数字段），
    /// 并且**胜利后自动给所有雷插旗**（`0x4029F0` 处调用 `0x4024F0`）。
    /// ────────────────────────────────────────────────────────────────────
    private func checkWin() {
        guard state == .playing else { return }
        let unrevealed = cells.count - revealedCount
        guard unrevealed == mineCount else { return }

        state = .won
        // 胜利后自动给所有雷插旗
        autoFlagAllMines()
    }

    /// 胜利（或失败）时给所有雷插上旗。
    private func autoFlagAllMines() {
        var flags = 0
        for i in 0..<cells.count {
            if cells[i].containsMine && !cells[i].isFlagged {
                cells[i].isFlagged = true
                flags += 1
            }
        }
        flagsPlaced += flags
    }
}
