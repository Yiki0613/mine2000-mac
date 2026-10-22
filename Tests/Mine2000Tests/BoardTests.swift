import Testing
@testable import Mine2000

/// 确定性随机源：让布雷过程可复现。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed &* 6364136223846793005 &+ 1442695040888963407
    }

    mutating func next() -> UInt64 {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2685821657736338717
    }
}

// MARK: - 难度规格表

@Suite("难度规格表")
struct DifficultyTests {

    /// 5 档难度的权威规格（来自反汇编实测，见 Difficulty.swift 注释）。
    @Test("5 档难度的列/行/雷数与反汇编一致")
    func testDifficultySpecifications() {
        let expected: [(Difficulty, cols: Int, rows: Int, mines: Int)] = [
            (.beginner, 8, 8, 10),
            (.middle, 16, 16, 40),
            (.expert, 30, 16, 99),
            (.hiper, 48, 24, 256),
            (.mania, 64, 48, 777),
        ]
        for (difficulty, cols, rows, mines) in expected {
            #expect(difficulty.columns == cols, "\(difficulty) 列数")
            #expect(difficulty.rows == rows, "\(difficulty) 行数")
            #expect(difficulty.mineCount == mines, "\(difficulty) 地雷数")
        }
    }

    /// 难度枚举必须是 5 个，且序号 0..4 与原版 `+0x180` 字段一致。
    @Test("难度枚举为 5 个，序号 0..4")
    func testDifficultyCaseCount() {
        #expect(Difficulty.allCases.count == 5)
        #expect(Difficulty.allCases.map(\.rawValue) == [0, 1, 2, 3, 4])
    }

    /// 每档的格子数 = 列 × 行。
    @Test("格子总数 = 列 × 行")
    func testCellCountMatchesDimensions() {
        for d in Difficulty.allCases {
            #expect(d.cellCount == d.columns * d.rows, "\(d) 格子总数")
        }
    }

    /// 地雷数必须小于格子数（否则游戏无意义）。
    @Test("地雷数小于格子总数")
    func testMineCountFitsOnBoard() {
        for d in Difficulty.allCases {
            #expect(d.mineCount < d.cellCount, "\(d) 地雷数应小于格子数")
        }
    }

    /// 格子边长为 16 像素。
    @Test("格子边长为 16 像素")
    func testCellSizeIs16() {
        #expect(Difficulty.cellSize == 16)
    }

    /// 菜单标题为本地化中文难度名。
    ///
    /// ⚠️ 译名依据见 `docs/中文化改造方案.md` §2.4：
    /// 前 3 档锚定 Windows 扫雷官方中文名（中級 16×16/40、上級 30×16/99
    /// 与原版逐字节相同），后 2 档用「大师 / 宗师」承接「专家之上」。
    @Test("菜单标题为本地化中文难度名")
    func testMenuTitles() {
        #expect(Difficulty.beginner.menuTitle == "初级")
        #expect(Difficulty.middle.menuTitle == "中级")
        #expect(Difficulty.expert.menuTitle == "专家")
        #expect(Difficulty.hiper.menuTitle == "大师")
        #expect(Difficulty.mania.menuTitle == "宗师")
    }

    /// 原版日文难度名完整保留（**还原度回归**）。
    ///
    /// ⚠️ 本地化**只改显示文字**，原版日文必须仍可查，
    /// 否则「行为还原对照表」将失去对照依据。
    @Test("原版日文难度名完整保留（还原度回归）")
    func testMenuTitlesOriginalPreserved() {
        #expect(Difficulty.beginner.menuTitleOriginal == "初級")
        #expect(Difficulty.middle.menuTitleOriginal == "中級")
        #expect(Difficulty.expert.menuTitleOriginal == "上級")
        #expect(Difficulty.hiper.menuTitleOriginal == "超上級")
        #expect(Difficulty.mania.menuTitleOriginal == "マニア")
    }

    /// 难度菜单项附带规模信息。
    @Test("难度菜单项附带规模信息")
    func testMenuTitlesWithScale() {
        #expect(Difficulty.beginner.menuTitleWithScale == "初级（8×8，10 雷）")
        #expect(Difficulty.middle.menuTitleWithScale == "中级（16×16，40 雷）")
        #expect(Difficulty.expert.menuTitleWithScale == "专家（30×16，99 雷）")
        #expect(Difficulty.hiper.menuTitleWithScale == "大师（48×24，256 雷）")
        #expect(Difficulty.mania.menuTitleWithScale == "宗师（64×48，777 雷）")
    }

    /// 棋盘像素尺寸 = 格数 × 16。
    @Test("棋盘像素尺寸按 16px/格计算")
    func testPixelDimensions() {
        for d in Difficulty.allCases {
            #expect(d.boardPixelWidth == d.columns * 16)
            #expect(d.boardPixelHeight == d.rows * 16)
        }
    }
}

// MARK: - 棋盘初始化与布雷

@Suite("棋盘逻辑")
struct BoardTests {

    // MARK: 地雷布局

    /// 布雷数量正确。
    @Test("布雷数量与规格一致")
    func testMineCountAfterFirstReveal() {
        for d in Difficulty.allCases {
            let board = Board(difficulty: d, generator: SeededGenerator(seed: 42))
            board.reveal(row: 0, column: 0)
            let mineCells = board.allCells.filter(\.containsMine).count
            #expect(mineCells == d.mineCount, "\(d) 实际雷数")
        }
    }

    /// 雷不会越界（每个坐标都可安全访问，越界返回 nil）。
    @Test("雷不会越界")
    func testMinesStayWithinBounds() {
        let board = Board(difficulty: .expert, generator: SeededGenerator(seed: 7))
        board.reveal(row: 0, column: 0)
        for row in -1...(board.rows) {
            for column in -1...(board.columns) {
                let inBounds = row >= 0 && row < board.rows && column >= 0 && column < board.columns
                #expect((board.cell(row: row, column: column) != nil) == inBounds)
            }
        }
    }

    /// 首点保护：第一次点击的格子一定不含雷（原版只保护首点这一格）。
    @Test("首点格一定不含雷")
    func testFirstClickCellIsNeverAMine() {
        for d in Difficulty.allCases {
            for seed in 0..<20 {
                let board = Board(difficulty: d, generator: SeededGenerator(seed: UInt64(seed)))
                let row = Int.random(in: 0..<d.rows)
                let column = Int.random(in: 0..<d.columns)
                board.reveal(row: row, column: column)
                let cell = board.cell(row: row, column: column)
                #expect(cell != nil)
                #expect(cell?.containsMine == false, "\(d) seed=\(seed) 首点不该是雷")
            }
        }
    }

    /// 初始状态：未开始、没有雷、全部未翻开。
    @Test("初始状态为未开始且无雷")
    func testInitialState() {
        let board = Board(difficulty: .middle, generator: SeededGenerator(seed: 1))
        #expect(board.state == .ready)
        #expect(board.minesPlaced == false)
        #expect(board.revealedCount == 0)
        #expect(board.flagsPlaced == 0)
        #expect(board.allCells.allSatisfy { !$0.isRevealed && !$0.containsMine })
    }

    // MARK: 首点展开

    /// 首点翻开必然不会踩雷（因为首点受保护）。
    @Test("首点不会踩雷")
    func testFirstRevealNeverHitsMine() {
        for seed in 0..<50 {
            let board = Board(difficulty: .hiper, generator: SeededGenerator(seed: UInt64(seed)))
            let outcome = board.reveal(row: 5, column: 5)
            #expect(outcome != .hitMine, "seed=\(seed)")
        }
    }

    /// 首点展开后进入 playing 状态。
    @Test("首点后进入进行中状态")
    func testRevealEntersPlayingState() {
        let board = Board(difficulty: .middle, generator: SeededGenerator(seed: 3))
        board.reveal(row: 0, column: 0)
        #expect(board.state == .playing)
    }

    // MARK: flood fill 递归展开

    /// 空白区的连锁展开：周围无雷的格子会成片翻开。
    ///
    /// 注意：首点是否落在「空白区」取决于随机布雷结果，
    /// 因此这里用**条件式不变量**断言（而不是依赖某个固定种子恰好命中）：
    /// * 若首点周围无雷（adjacentMineCount == 0），则必定触发连锁展开；
    /// * 若首点周围有雷，则只翻开首点本身。
    /// 同时要求在多个种子中至少出现过一次真正的连锁展开，
    /// 以确保展开路径确实被覆盖到。
    @Test("空白区连锁展开")
    func testFloodFillExpandsEmptyRegion() {
        var sawRealExpansion = false

        for seed in 0..<60 {
            let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: UInt64(seed)))
            board.reveal(row: 2, column: 2)

            let clicked = board.cell(row: 2, column: 2)!
            if clicked.adjacentMineCount == 0 {
                // 空白区 → 必然连锁展开，翻开数应大于 1
                #expect(board.revealedCount > 1, "seed=\(seed) 空白区应连锁展开")
                sawRealExpansion = true
            } else {
                // 带数字 → 只翻开首点本身
                #expect(board.revealedCount == 1, "seed=\(seed) 带数字格只翻开首点")
            }
        }
        #expect(sawRealExpansion, "应至少有一个种子命中真正的连锁展开")
    }

    /// 展开只会发生在「周围无雷」的格子上。
    @Test("带数字的格子不会被连锁展开")
    func testExpansionStopsAtNumberedCells() {
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: 5))
        board.reveal(row: 2, column: 2)
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                let cell = board.cell(row: row, column: column)!
                if cell.isRevealed && !cell.containsMine && cell.adjacentMineCount > 0 {
                    // 带数字的格子只能是被直接点开的那个
                    let directHit = (row == 2 && column == 2)
                    #expect(directHit, "带数字的格子 (\(row),\(column)) 不应被连锁展开")
                }
            }
        }
    }

    /// 相邻雷数统计正确：与独立计算的 8 邻域结果一致。
    @Test("相邻雷数统计正确")
    func testAdjacentMineCountComputation() {
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: 11))
        board.reveal(row: 0, column: 0)

        for row in 0..<board.rows {
            for column in 0..<board.columns {
                let cell = board.cell(row: row, column: column)!
                guard cell.isRevealed, !cell.containsMine else { continue }
                var expected = 0
                for dr in -1...1 {
                    for dc in -1...1 {
                        if dr == 0 && dc == 0 { continue }
                        let nr = row + dr, nc = column + dc
                        guard board.isValid(row: nr, column: nc) else { continue }
                        if board.cell(row: nr, column: nc)!.containsMine { expected += 1 }
                    }
                }
                #expect(cell.adjacentMineCount == expected, "(\(row),\(column)) 相邻雷数")
            }
        }
    }

    /// 展开出的格子都确实没有雷。
    @Test("展开不会翻出雷格")
    func testExpansionNeverRevealsMine() {
        let board = Board(difficulty: .expert, generator: SeededGenerator(seed: 77))
        board.reveal(row: 8, column: 8)
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                let cell = board.cell(row: row, column: column)!
                if cell.isRevealed && !cell.containsMine {
                    continue
                }
                if cell.isRevealed && cell.containsMine {
                    // 只允许玩家直接踩中的那一颗雷被翻开
                    #expect(row == 8 && column == 8, "只有直接点开的雷格才可被翻开")
                }
            }
        }
    }

    // MARK: 插旗计数

    /// 插旗与取消插旗的计数正确。
    ///
    /// 注意：插旗只能落在**未翻开**的格子上，而首点展开可能已经把目标格翻开，
    /// 因此这里动态挑选未翻开的格子来插旗，避免依赖随机布局。
    @Test("插旗计数正确")
    func testFlagCounting() {
        let board = Board(difficulty: .middle, generator: SeededGenerator(seed: 13))
        board.reveal(row: 0, column: 0)

        // 收集两个未翻开的格子
        var free: [(Int, Int)] = []
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                if board.cell(row: row, column: column)!.isRevealed { continue }
                free.append((row, column))
                if free.count == 2 { break }
            }
            if free.count == 2 { break }
        }
        #expect(free.count == 2, "应能找到 2 个未翻开的格子")

        board.toggleFlag(row: free[0].0, column: free[0].1)
        #expect(board.flagsPlaced == 1)
        #expect(board.cell(row: free[0].0, column: free[0].1)!.isFlagged)

        board.toggleFlag(row: free[1].0, column: free[1].1)
        #expect(board.flagsPlaced == 2)

        board.toggleFlag(row: free[0].0, column: free[0].1)
        #expect(board.flagsPlaced == 1)
        #expect(board.cell(row: free[0].0, column: free[0].1)!.isFlagged == false)
    }

    /// 剩余雷数 = 总雷数 − 已插旗数。
    @Test("剩余雷数随插旗递减")
    func testRemainingMines() {
        let board = Board(difficulty: .middle, generator: SeededGenerator(seed: 17))
        board.reveal(row: 0, column: 0)
        #expect(board.remainingMines == board.mineCount)

        // 找一个未翻开的格子插旗
        var target: (Int, Int)?
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                if !board.cell(row: row, column: column)!.isRevealed {
                    target = (row, column)
                    break
                }
            }
            if target != nil { break }
        }
        #expect(target != nil)
        board.toggleFlag(row: target!.0, column: target!.1)
        #expect(board.remainingMines == board.mineCount - 1)
    }

    /// 已翻开的格子不能插旗。
    @Test("已翻开格子不能插旗")
    func testCannotFlagRevealedCell() {
        let board = Board(difficulty: .middle, generator: SeededGenerator(seed: 19))
        board.reveal(row: 4, column: 4)
        let changed = board.toggleFlag(row: 4, column: 4)
        #expect(changed == false)
        #expect(board.flagsPlaced == 0)
    }

    /// 已插旗的格子不能被翻开。
    @Test("已插旗格子不能被翻开")
    func testFlaggedCellCannotBeRevealed() {
        let board = Board(difficulty: .middle, generator: SeededGenerator(seed: 23))
        board.reveal(row: 0, column: 0)
        board.toggleFlag(row: 6, column: 6)
        let outcome = board.reveal(row: 6, column: 6)
        #expect(outcome == .ignored)
        #expect(board.cell(row: 6, column: 6)!.isRevealed == false)
    }

    // MARK: 胜负判定

    /// 踩雷 → 失败。
    @Test("踩雷判负")
    func testLoseOnMine() {
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: 29))
        board.reveal(row: 0, column: 0)
        var mineRow = -1, mineColumn = -1
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                if board.cell(row: row, column: column)!.containsMine {
                    mineRow = row
                    mineColumn = column
                }
            }
        }
        #expect(mineRow >= 0, "应至少有一颗雷")
        let outcome = board.reveal(row: mineRow, column: mineColumn)
        #expect(outcome == .hitMine)
        #expect(board.state == .lost)
        #expect(board.state.isFinished)
    }

    /// 全部非雷格翻开 → 胜利。
    @Test("全部非雷格翻开判胜")
    func testWinWhenAllNonMineCellsRevealed() {
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: 31))
        board.reveal(row: 0, column: 0)

        for row in 0..<board.rows {
            for column in 0..<board.columns {
                let cell = board.cell(row: row, column: column)!
                if cell.containsMine || cell.isRevealed { continue }
                board.reveal(row: row, column: column)
            }
        }
        #expect(board.state == .won)
        #expect(board.isWon)
    }

    /// 胜利时已翻开的格子数 = 总格子数 − 雷数。
    @Test("胜利时翻开数 = 格子总数 − 雷数")
    func testWinRevealedCountMatches() {
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: 37))
        board.reveal(row: 0, column: 0)
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                let cell = board.cell(row: row, column: column)!
                if cell.containsMine || cell.isRevealed { continue }
                board.reveal(row: row, column: column)
            }
        }
        #expect(board.revealedCount == board.cellCount - board.mineCount)
    }

    /// 越界操作被安全忽略。
    @Test("越界操作被忽略")
    func testOutOfBoundsOperationsAreIgnored() {
        let board = Board(difficulty: .middle, generator: SeededGenerator(seed: 41))
        #expect(board.cell(row: -1, column: 0) == nil)
        #expect(board.cell(row: 0, column: 999) == nil)
        #expect(board.reveal(row: -1, column: 0) == .ignored)
        #expect(board.toggleFlag(row: 999, column: 0) == false)
        #expect(board.flagsPlaced == 0)
    }

    /// 重复翻开同一个格子不改变计数。
    @Test("重复翻开不改变计数")
    func testRevealingTwiceIsIdempotent() {
        let board = Board(difficulty: .middle, generator: SeededGenerator(seed: 43))
        board.reveal(row: 2, column: 2)
        let countAfterFirst = board.revealedCount
        board.reveal(row: 2, column: 2)
        #expect(board.revealedCount == countAfterFirst)
    }

    /// 失败后状态不再被改写。
    @Test("失败后状态保持为失败")
    func testStateStaysLost() {
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: 53))
        board.reveal(row: 0, column: 0)
        var mineRow = -1, mineColumn = -1
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                if board.cell(row: row, column: column)!.containsMine {
                    mineRow = row
                    mineColumn = column
                }
            }
        }
        board.reveal(row: mineRow, column: mineColumn)
        #expect(board.state == .lost)
        // 失败后再点其它格不应回到 playing
        board.reveal(row: 0, column: 0)
        #expect(board.state == .lost)
    }
}

// MARK: - 游戏状态 / 表情

@Suite("游戏状态与表情")
struct GameStateTests {

    /// 各状态对应的表情符合原版语义。
    ///
    /// - [已确证] 原版表情跳转表 `0x403A1C` 只有 4 项：
    ///   状态 1（未开始）→ `0x40388E`、状态 2（游戏中）→ `0x40388E`
    ///   （**两者共用同一分支**）、状态 3（胜利）→ `0x40391F`、状态 4（失败）→ `0x403978`。
    ///   在 `0x40388E` 分支中，鼠标未按下时取源 x = `0x00` → **槽 0 正常微笑**。
    ///   因此「未开始」与「游戏中」在鼠标未按下时都显示正常微笑，
    ///   而非「未开始显示备用脸」。
    @Test("状态 → 表情映射")
    func testExpressionMapping() {
        #expect(FaceExpression.expression(for: .ready) == .normal)
        #expect(FaceExpression.expression(for: .playing) == .normal)
        #expect(FaceExpression.expression(for: .won) == .win)
        #expect(FaceExpression.expression(for: .lost) == .lose)
    }

    /// 5 态表情机：未开始 / 游戏中 / 胜利 / 失败 / 惊讶。
    ///
    /// - [已确证] 惊讶脸（槽 3，源 x = `0x4E`）来自
    ///   `0x4038ED`：状态 1/2 且鼠标在棋盘上按下时绘制。
    @Test("5 态表情机覆盖全部表情")
    func testFaceStateMachine() {
        // 未开始 / 游戏中：鼠标未按下 → 正常微笑
        #expect(FaceState(gameState: .ready, mousePressed: false, mouseOnBoard: true) == .notStarted)
        #expect(FaceState(gameState: .playing, mousePressed: false, mouseOnBoard: true) == .playing)

        // 鼠标在棋盘上按下 → 惊讶
        #expect(FaceState(gameState: .ready, mousePressed: true, mouseOnBoard: true) == .surprised)
        #expect(FaceState(gameState: .playing, mousePressed: true, mouseOnBoard: true) == .surprised)

        // 胜负状态不受鼠标影响
        #expect(FaceState(gameState: .won, mousePressed: true, mouseOnBoard: true) == .won)
        #expect(FaceState(gameState: .lost, mousePressed: true, mouseOnBoard: true) == .lost)

        // 表情图块对应关系
        #expect(FaceState.notStarted.expression == .normal)
        #expect(FaceState.playing.expression == .normal)
        #expect(FaceState.won.expression == .win)
        #expect(FaceState.lost.expression == .lose)
        #expect(FaceState.surprised.expression == .surprise)
    }

    /// 表情枚举有 5 个，且与图集区域 C 的槽位对应。
    @Test("表情枚举为 5 个，槽位 0..4")
    func testFaceCountMatchesAtlas() {
        #expect(FaceExpression.allCases.count == 5)
        #expect(FaceExpression.allCases.map(\.rawValue) == [0, 1, 2, 3, 4])
    }

    /// 只有胜/负算「已结束」。
    @Test("仅胜负为已结束状态")
    func testIsFinished() {
        #expect(GameState.ready.isFinished == false)
        #expect(GameState.playing.isFinished == false)
        #expect(GameState.won.isFinished)
        #expect(GameState.lost.isFinished)
    }
}
