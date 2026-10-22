import Testing
import Foundation
@testable import Mine2000

/// 独立验证者补充的规格测试。
///
/// ────────────────────────────────────────────────────────────────────────
/// 本文件针对定稿规格里**最容易被实现错**的几条行为做「反向验证」：
/// 不是断言「代码这样写」，而是断言「原版语义就是这样」，
/// 并且每条断言都尽量用**可构造的场景**而不是依赖随机结果。
///
/// 覆盖的规格点：
/// 1. **首击只保证不踩雷**，不保证周围 3×3 安全（§5.3）；
/// 2. **首击安全**在大量不同种子下成立（§5.3）；
/// 3. **chording 触发条件**是「旗数 == 显示数字 且 旗数 ≠ 0」（§5.4），
///    三种边界（旗数 < 数字 / 旗数 > 数字 / 旗数 == 数字）都要覆盖；
/// 4. **剩余雷数 = 雷总数 − 已插旗数**，两个计数器互不干扰（§2.1）。
/// ────────────────────────────────────────────────────────────────────────
@Suite("规格反向验证")
struct VerificationSpecTests {

    // MARK: - 辅助：构造可控的 chording 场景

    /// 一个可用于 chording 测试的场景。
    ///
    /// - `target`：可作为 chording 触发点的格子（已翻开、带数字）。
    /// - `mineNeighbours`：该格周围**是雷**的邻格（必须插旗才能凑够旗数）。
    /// - `safeNeighbours`：该格周围**不是雷**的邻格（chording 成功后被翻开）。
    struct ChordScenario {
        let seed: UInt64
        let target: (row: Int, column: Int)
        let mineNeighbours: [(row: Int, column: Int)]
        let safeNeighbours: [(row: Int, column: Int)]
    }

    /// 在若干种子中搜索一个「周边既有雷、也有安全的隐藏格」的 chording 场景。
    ///
    /// 搜索是确定性的（按 seed 递增），因此测试可复现。
    static func findChordScenario(
        difficulty: Difficulty = .beginner,
        seedRange: Range<UInt64> = 0..<400
    ) -> ChordScenario? {
        for seed in seedRange {
            let board = Board(difficulty: difficulty, generator: SeededGenerator(seed: seed))
            // 首击展开，触发布雷
            board.reveal(row: 0, column: 0)

            for row in 0..<board.rows {
                for column in 0..<board.columns {
                    guard let cell = board.cell(row: row, column: column),
                          cell.isRevealed,
                          !cell.containsMine,
                          cell.adjacentMineCount >= 1,
                          cell.adjacentMineCount <= 3
                    else { continue }

                    var mines: [(row: Int, column: Int)] = []
                    var safes: [(row: Int, column: Int)] = []
                    for dr in -1...1 {
                        for dc in -1...1 {
                            if dr == 0 && dc == 0 { continue }
                            let nr = row + dr, nc = column + dc
                            guard let n = board.cell(row: nr, column: nc) else { continue }
                            if n.containsMine {
                                mines.append((nr, nc))
                            } else if !n.isRevealed {
                                safes.append((nr, nc))
                            }
                        }
                    }
                    // 需要：至少 1 个雷、至少 1 个安全隐藏格（chording 才有「翻开」的效果）
                    guard !mines.isEmpty, !safes.isEmpty else { continue }
                    return ChordScenario(
                        seed: seed,
                        target: (row, column),
                        mineNeighbours: mines,
                        safeNeighbours: safes
                    )
                }
            }
        }
        return nil
    }

    // MARK: - §5.3 首击语义

    /// **首击只保证不踩雷，不保证周围 3×3 安全。**
    ///
    /// 反向验证：构造一个「首击格的**斜角邻格**就是雷」的场景。
    /// 若实现错误地做了 3×3 保护，这个场景就构造不出来。
    @Test("首击格周围可以存在地雷（原版不做 3×3 保护）")
    func testFirstClickNeighbourMayContainMine() throws {
        var foundSeed: UInt64?
        var foundNeighbour: (row: Int, column: Int)?

        for seed in UInt64(0)..<400 {
            let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: seed))
            // 首点 (0,0)：它自身必无雷，但斜角 (1,1) 可能有雷
            board.reveal(row: 0, column: 0)
            if board.cell(row: 1, column: 1)?.containsMine == true {
                foundSeed = seed
                foundNeighbour = (1, 1)
                break
            }
        }

        let seed = try #require(foundSeed, "应能找到首击格斜角邻格为雷的种子")
        let neighbour = try #require(foundNeighbour)

        // 复核：首击格本身无雷，但斜角邻格有雷 —— 这正是「只保护 1 格」的语义
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: seed))
        board.reveal(row: 0, column: 0)
        #expect(board.cell(row: 0, column: 0)?.containsMine == false,
                "首击格本身必须无雷")
        #expect(board.cell(row: neighbour.row, column: neighbour.column)?.containsMine == true,
                "首击格的斜角邻格可以是雷（原版只保护首击那一格）")
    }

    /// **首击安全**在 1000 个不同种子下都成立。
    ///
    /// 用 1000 个不同种子 × 随机首击位置，覆盖每一档难度。
    @Test("首击安全：1000 个不同种子下首击格绝不会是雷")
    func testFirstClickIsNeverAMineAcross1000Seeds() {
        var checked = 0
        for seed in UInt64(0)..<1000 {
            for difficulty in Difficulty.allCases {
                let board = Board(difficulty: difficulty, generator: SeededGenerator(seed: seed))
                // 首击位置也随种子变化
                let row = Int(seed % UInt64(difficulty.rows))
                let column = Int((seed / 7) % UInt64(difficulty.columns))

                let outcome = board.reveal(row: row, column: column)
                #expect(outcome != .hitMine,
                        "seed=\(seed) \(difficulty) 首击 (\(row),\(column)) 不应踩雷")
                #expect(board.cell(row: row, column: column)?.containsMine == false,
                        "seed=\(seed) \(difficulty) 首击格不应含雷")
                checked += 1
            }
        }
        #expect(checked == 1000 * Difficulty.allCases.count,
                "应完成 \(1000 * Difficulty.allCases.count) 次首击检查，实际 \(checked)")
    }

    /// **首击只展开一格也可能发生**（原版没有「首击必开一片」的保证）。
    ///
    /// 反向验证：存在种子，使得首击格**周围有雷** → 首击只翻开首击格本身
    /// （返回带数字的结果，而非连锁展开）。
    @Test("首击可能只翻开 1 格（原版不保证首击展开一片）")
    func testFirstClickMayExpandToASingleCell() {
        var sawSingleCell = false
        for seed in UInt64(0)..<400 {
            let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: seed))
            let outcome = board.reveal(row: 3, column: 3)
            // 带数字的结果 = 首击格周围有雷 → 不发生连锁展开，只翻开 1 格
            if case .revealedNumber(let adjacent) = outcome, adjacent > 0 {
                #expect(board.revealedCount == 1,
                        "首击格周围有雷时只应翻开首击格本身")
                sawSingleCell = true
                break
            }
        }
        #expect(sawSingleCell, "应存在「首击只翻开 1 格」的场景，证明未实现首击必开一片")
    }

    // MARK: - §5.4 chording 触发条件

    /// **旗数 < 该格数字** → 不触发 chording。
    @Test("chording 边界：旗数少于数字时不触发")
    func testChordDoesNotTriggerWhenFlagsFewerThanNumber() throws {
        let scenario = try #require(Self.findChordScenario(), "应能找到可用的 chording 场景")
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: scenario.seed))
        board.reveal(row: 0, column: 0)

        // 只插 k-1 面旗（k = 该格数字），旗数不足
        let k = scenario.mineNeighbours.count
        #expect(k >= 1)
        for (index, cell) in scenario.mineNeighbours.prefix(k - 1).enumerated() {
            board.toggleFlag(row: cell.row, column: cell.column)
            #expect(board.flagsPlaced == index + 1)
        }

        let opened = board.chord(row: scenario.target.row, column: scenario.target.column)
        #expect(opened == 0, "旗数 < 数字时不应翻开任何格子")
        // 邻格仍是隐藏状态
        for cell in scenario.safeNeighbours {
            #expect(board.cell(row: cell.row, column: cell.column)?.isRevealed == false,
                    "旗数不足时邻格不应被翻开")
        }
    }

    /// **旗数 > 该格数字** → 不触发 chording。
    @Test("chording 边界：旗数多于数字时不触发")
    func testChordDoesNotTriggerWhenFlagsExceedNumber() throws {
        let scenario = try #require(Self.findChordScenario(), "应能找到可用的 chording 场景")
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: scenario.seed))
        board.reveal(row: 0, column: 0)

        // 插满 k 面雷旗，再多插 1 面（插在安全格上）
        for cell in scenario.mineNeighbours {
            board.toggleFlag(row: cell.row, column: cell.column)
        }
        let extra = try #require(scenario.safeNeighbours.first, "应至少有一个安全邻格")
        board.toggleFlag(row: extra.row, column: extra.column)

        let opened = board.chord(row: scenario.target.row, column: scenario.target.column)
        #expect(opened == 0, "旗数 > 数字时不应翻开任何格子")
    }

    /// **旗数 == 该格数字 且 旗数 ≠ 0** → 触发 chording，翻开周围安全格。
    @Test("chording 边界：旗数等于数字时触发并翻开周围格")
    func testChordTriggersWhenFlagsEqualNumber() throws {
        let scenario = try #require(Self.findChordScenario(), "应能找到可用的 chording 场景")
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: scenario.seed))
        board.reveal(row: 0, column: 0)

        // 恰好插 k 面旗（k = 该格数字）
        for cell in scenario.mineNeighbours {
            board.toggleFlag(row: cell.row, column: cell.column)
        }
        #expect(board.flagsPlaced == scenario.mineNeighbours.count)

        let opened = board.chord(row: scenario.target.row, column: scenario.target.column)
        #expect(opened == scenario.safeNeighbours.count,
                "旗数 == 数字时应翻开所有安全邻格，实际翻开 \(opened) 个")

        for cell in scenario.safeNeighbours {
            #expect(board.cell(row: cell.row, column: cell.column)?.isRevealed == true,
                    "安全邻格应被翻开")
        }
    }

    /// **旗数 == 0** → 不触发（原版显式检查 `test eax,eax; je`）。
    @Test("chording 边界：旗数为 0 时不触发")
    func testChordDoesNotTriggerWithZeroFlags() throws {
        let scenario = try #require(Self.findChordScenario(), "应能找到可用的 chording 场景")
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: scenario.seed))
        board.reveal(row: 0, column: 0)

        #expect(board.flagsPlaced == 0)
        let opened = board.chord(row: scenario.target.row, column: scenario.target.column)
        #expect(opened == 0, "旗数为 0 时不应触发 chording")
    }

    /// **非数字格**（已翻开的空白格）不能作为 chording 触发点。
    @Test("chording 边界：非数字格不能触发")
    func testChordDoesNotTriggerOnBlankCell() throws {
        // 找一个「已翻开且周围 0 雷」的格子
        var found: (seed: UInt64, row: Int, column: Int)?
        for seed in UInt64(0)..<400 {
            let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: seed))
            board.reveal(row: 0, column: 0)
            for row in 0..<board.rows {
                for column in 0..<board.columns {
                    if let cell = board.cell(row: row, column: column),
                       cell.isRevealed,
                       !cell.containsMine,
                       cell.adjacentMineCount == 0 {
                        found = (seed, row, column)
                        break
                    }
                }
                if found != nil { break }
            }
            if found != nil { break }
        }

        let scenario = try #require(found, "应能找到已翻开的空白格")
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: scenario.seed))
        board.reveal(row: 0, column: 0)

        // 空白格周围理论上没有雷可插旗，即使插旗也凑不出「旗数 == 0 且 ≠ 0」
        let opened = board.chord(row: scenario.row, column: scenario.column)
        #expect(opened == 0, "空白格（数字为 0）不应触发 chording")
    }

    // MARK: - §2.1 剩余雷数

    /// **剩余雷 = 雷总数 − 已插旗数**，两个计数器互不干扰。
    ///
    /// 关键点：插旗数与「已翻开格数」是**两个独立计数器**——
    /// 插旗不影响翻开计数，翻开不影响插旗计数。
    @Test("剩余雷数 = 雷总数 − 已插旗数（两个独立计数器）")
    func testRemainingMinesUsesIndependentFlagCounter() {
        let board = Board(difficulty: .middle, generator: SeededGenerator(seed: 31))
        board.reveal(row: 0, column: 0)

        #expect(board.remainingMines == board.mineCount)
        #expect(board.flagsPlaced == 0)
        #expect(board.revealedCount >= 1, "首击后翻开数应 > 0")

        // 插一面旗：剩余雷 -1，但翻开数不变
        let revealedBefore = board.revealedCount
        var flagged = false
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                if let cell = board.cell(row: row, column: column),
                   !cell.isRevealed, !cell.containsMine {
                    board.toggleFlag(row: row, column: column)
                    flagged = true
                    break
                }
            }
            if flagged { break }
        }
        #expect(flagged, "应能插上一面旗")
        #expect(board.flagsPlaced == 1)
        #expect(board.remainingMines == board.mineCount - 1)
        #expect(board.revealedCount == revealedBefore, "插旗不应改变翻开计数")

        // 取消插旗：剩余雷复原
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                if let cell = board.cell(row: row, column: column), cell.isFlagged {
                    board.toggleFlag(row: row, column: column)
                    #expect(board.flagsPlaced == 0)
                    #expect(board.remainingMines == board.mineCount)
                    return
                }
            }
        }
        Issue.record("未找到刚插的旗")
    }

    /// **胜利后自动给所有雷插旗**（原版 `0x4025E0` 行为），剩余雷因此归零。
    @Test("胜利后自动给全部地雷插旗，剩余雷归零")
    func testAutoFlagAllMinesOnWin() {
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: 41))
        board.reveal(row: 0, column: 0)
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                let cell = board.cell(row: row, column: column)!
                if cell.containsMine || cell.isRevealed { continue }
                board.reveal(row: row, column: column)
            }
        }
        #expect(board.state == .won)
        #expect(board.flagsPlaced == board.mineCount, "胜利后应给所有雷插旗")
        #expect(board.remainingMines == 0)
    }
}
