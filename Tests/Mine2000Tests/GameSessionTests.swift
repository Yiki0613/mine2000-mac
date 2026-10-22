import Testing
import Foundation
@testable import Mine2000

/// 会话层（计时 / 表情 / 计分格式）的测试。
@Suite("游戏会话与计分格式")
struct GameSessionTests {

    // MARK: - 计分格式

    /// 计分格式为「秒.十分之一秒」，与原版格式串 `%d.%d秒` 一致。
    ///
    /// - [已确证] `.rdata` `0x408F60` = CP932 `"%d.%d秒"`；
    ///   分数单位为 0.1 秒（计时函数 `0x401C46` = 毫秒差 / 100）。
    @Test("计分格式为 秒.十分之一秒 秒（本地化：数字后加空格，单位保留）")
    func testScoreFormat() {
        #expect(ScoreFormat.format(deciseconds: 0) == "0.0 秒")
        #expect(ScoreFormat.format(deciseconds: 5) == "0.5 秒")
        #expect(ScoreFormat.format(deciseconds: 10) == "1.0 秒")
        #expect(ScoreFormat.format(deciseconds: 123) == "12.3 秒")
        #expect(ScoreFormat.format(deciseconds: 1234) == "123.4 秒")
    }

    /// 秒 ↔ 十分之一秒单位的互转。
    @Test("秒与十分之一秒单位互转正确")
    func testScoreUnitConversion() {
        #expect(HighScoreEntry.deciseconds(from: 0) == 0)
        #expect(HighScoreEntry.deciseconds(from: 1) == 10)
        #expect(HighScoreEntry.deciseconds(from: 12.3) == 123)
        #expect(HighScoreEntry.seconds(fromDeciseconds: 123) == 12.3)
    }

    // MARK: - 计时

    /// 未开始时用时恒为 0（与原版状态 1 返回 0 的行为一致）。
    ///
    /// - [已确证] 计时函数 `0x401C30` 在 `+0x190 == 1` 时跳到 `0x401C6C`，
    ///   即 `xor eax,eax; ret`。
    @Test("未开始时用时为 0")
    func testElapsedIsZeroBeforeStart() {
        let session = GameSession(difficulty: .beginner, generator: SeededGenerator(seed: 1))
        #expect(session.board.state == .ready)
        #expect(session.elapsedDeciseconds == 0)
        #expect(session.scoreText == "0.0 秒")
    }

    /// 结束后用时冻结，不再增长。
    ///
    /// - [已确证] 胜负判定后原版写 `+0xC1A0`（最终用时），
    ///   之后计时函数（状态 3 / 4）直接返回该冻结值。
    @Test("结束后用时冻结")
    func testElapsedFreezesAfterGameOver() {
        let session = GameSession(difficulty: .beginner, generator: SeededGenerator(seed: 2))
        session.setElapsedForTesting(5.5)
        #expect(session.elapsedDeciseconds == 55)

        // 结束一局（翻开全部非雷格）
        session.reveal(row: 0, column: 0)
        for row in 0..<session.board.rows {
            for column in 0..<session.board.columns {
                let cell = session.board.cell(row: row, column: column)!
                if cell.containsMine || cell.isRevealed { continue }
                session.reveal(row: row, column: column)
            }
        }
        #expect(session.board.state == .won)
        let frozen = session.elapsedDeciseconds
        #expect(frozen == 55, "结束时应保持冻结值，实际 \(frozen)")
    }

    /// 重新开局后用时归零。
    @Test("重新开局后用时归零")
    func testRestartResetsElapsed() {
        let session = GameSession(difficulty: .middle, generator: SeededGenerator(seed: 3))
        session.setElapsedForTesting(9.0)
        #expect(session.elapsedDeciseconds == 90)
        session.restart()
        #expect(session.elapsedDeciseconds == 0)
        #expect(session.board.state == .ready)
    }

    /// 切换难度后棋盘尺寸随之变化。
    @Test("切换难度后棋盘尺寸变化")
    func testRestartWithNewDifficulty() {
        let session = GameSession(difficulty: .beginner, generator: SeededGenerator(seed: 4))
        #expect(session.board.columns == 8)
        #expect(session.board.rows == 8)
        session.restart(difficulty: .mania)
        #expect(session.board.columns == 64)
        #expect(session.board.rows == 48)
        #expect(session.board.mineCount == 777)
    }
}

/// 结束态锁定与失败揭示的测试。
@Suite("结束态与失败揭示")
struct BoardEndStateTests {

    /// 踩雷失败后，棋盘不再被后续操作改变。
    ///
    /// - [推断] 原版在胜负判定后（`+0x190` 写 3 或 4）即结束本局，
    ///   后续点击不应改变棋盘。
    @Test("失败后棋盘锁定")
    func testBoardLockedAfterLoss() {
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: 10))
        board.reveal(row: 0, column: 0)

        // 找到一颗雷并踩中
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

        let revealedAfterLoss = board.revealedCount
        let flagsAfterLoss = board.flagsPlaced

        // 后续操作不应改变棋盘
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                board.reveal(row: row, column: column)
            }
        }
        board.toggleFlag(row: 0, column: 0)

        #expect(board.revealedCount == revealedAfterLoss, "失败后翻开数不应变化")
        #expect(board.flagsPlaced == flagsAfterLoss, "失败后旗数不应变化")
        #expect(board.state == .lost, "失败后状态应保持为失败")
    }

    /// 胜利后棋盘锁定：用户操作不再改变棋盘。
    ///
    /// - [推断] 胜利瞬间会给所有剩余的雷自动插旗（经典扫雷行为，
    ///   原版对应 `0x4029F0` 调用胜利处理函数），
    ///   因此结束时 `flagsPlaced` 等于雷数；此处断言的是
    ///   **锁定期内用户无法再改变棋盘**。
    @Test("胜利后棋盘锁定")
    func testBoardLockedAfterWin() {
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: 11))
        board.reveal(row: 0, column: 0)
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                let cell = board.cell(row: row, column: column)!
                if cell.containsMine || cell.isRevealed { continue }
                board.reveal(row: row, column: column)
            }
        }
        #expect(board.state == .won)

        let revealedAfterWin = board.revealedCount
        let flagsAfterWin = board.flagsPlaced

        // 锁定期内：插旗与翻格都必须被拒绝
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                #expect(board.toggleFlag(row: row, column: column) == false,
                        "胜利后不应能插旗")
                #expect(board.reveal(row: row, column: column) == .ignored,
                        "胜利后不应能翻格")
            }
        }
        #expect(board.flagsPlaced == flagsAfterWin, "胜利后旗数不应变化")
        #expect(board.revealedCount == revealedAfterWin, "胜利后翻开数不应变化")
    }

    /// 失败时刚踩中的那颗雷被记录，供渲染层画红底高亮。
    ///
    /// - [已确证] 图集区域 A 第 1 行第 3 列 =「地雷 + 红底高亮」。
    @Test("失败时记录被踩中的雷")
    func testHitMineRecorded() {
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: 12))
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

        #expect(board.isHitMine(row: mineRow, column: mineColumn), "被踩中的雷应被标记")
        #expect(!board.isHitMine(row: 0, column: 0), "非被踩中的格不应被标记")
    }

    /// 失败时插错旗的格子被标记，供渲染层画 X。
    ///
    /// - [已确证] 图集区域 A 第 1 行第 4 列 =「地雷 + 红色 X」。
    @Test("失败时标记插错旗的格子")
    func testWrongFlagDetected() {
        let board = Board(difficulty: .beginner, generator: SeededGenerator(seed: 13))
        board.reveal(row: 0, column: 0)

        // 找一个**不是雷**的格子插旗
        var safeRow = -1, safeColumn = -1
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                let cell = board.cell(row: row, column: column)!
                if !cell.containsMine && !cell.isRevealed {
                    safeRow = row
                    safeColumn = column
                    break
                }
            }
            if safeRow >= 0 { break }
        }
        #expect(safeRow >= 0, "应能找到一个非雷格")
        board.toggleFlag(row: safeRow, column: safeColumn)
        #expect(board.isWrongFlag(row: safeRow, column: safeColumn) == false,
                "尚未失败时不应标记插错旗")

        // 踩雷 → 失败
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                if board.cell(row: row, column: column)!.containsMine {
                    board.reveal(row: row, column: column)
                }
            }
        }
        #expect(board.state == .lost)
        #expect(board.isWrongFlag(row: safeRow, column: safeColumn),
                "失败后插错旗的格子应被标记")
    }
}

/// 高分榜排序的测试。
@Suite("高分榜排序")
struct HighScoreTableTests {

    /// 用时越小排名越前。
    ///
    /// - [已确证] 原版比较代码 `0x402539`：`cmp edx, eax; jle` ——
    ///   只有新成绩严格小于榜上成绩才插入。
    @Test("用时越小排名越前")
    func testSubmitOrdersByScore() {
        var table = HighScoreTable()
        #expect(table.submit(name: "慢", score: 500, for: .beginner) == 0)
        #expect(table.submit(name: "快", score: 100, for: .beginner) == 0)
        #expect(table.submit(name: "中", score: 300, for: .beginner) == 1)

        let list = table.sortedScores(for: .beginner)
        #expect(list[0].name == "快")
        #expect(list[1].name == "中")
        #expect(list[2].name == "慢")
    }

    /// 成绩差于第 5 名时不入榜。
    @Test("成绩差于第 5 名不入榜")
    func testSubmitRejectsSlowScore() {
        var table = HighScoreTable()
        for i in 1...5 {
            #expect(table.submit(name: "P\(i)", score: i * 100, for: .beginner) == i - 1)
        }
        #expect(table.submit(name: "太慢", score: 9999, for: .beginner) == nil)
        #expect(table.sortedScores(for: .beginner).count == 5)
        #expect(table.sortedScores(for: .beginner).contains { $0.name == "太慢" } == false)
    }

    /// 各难度的榜单相互独立。
    @Test("各难度榜单相互独立")
    func testDifficultiesAreIndependent() {
        var table = HighScoreTable()
        table.submit(name: "初中级", score: 100, for: .beginner)
        table.submit(name: "中高级", score: 200, for: .middle)
        #expect(table.sortedScores(for: .beginner)[0].name == "初中级")
        #expect(table.sortedScores(for: .middle)[0].name == "中高级")
        #expect(table.sortedScores(for: .expert)[0].isEmpty)
    }

    /// 「无成绩」哨兵值为 99999。
    ///
    /// - [已确证] 原版默认档 25 条记录分数全为 `0x0001869F` = 99999。
    @Test("无成绩哨兵值为 99999")
    func testNoScoreSentinel() {
        #expect(HighScoreEntry.noScoreSentinel == 99_999)
        #expect(HighScoreEntry(name: "x", score: 99_999).isEmpty)
        #expect(HighScoreEntry(name: "x", score: 99_998).isEmpty == false)
    }

    /// 成绩上限与哨兵值一致（原版计时上限 `0x1869F`）。
    ///
    /// - [已确证] 反汇编 `0x403570`：`cmp ecx, 0x1869F` 为计时/成绩上限，
    ///   超过则被截断。
    @Test("成绩上限为 99999")
    func testMaxScore() {
        #expect(HighScoreEntry.maxScore == 99_999)
        // 超过上限的成绩会被夹取
        #expect(HighScoreEntry.deciseconds(from: 100_000) == 99_999)
    }

    /// 高分榜的「无成绩」记录应被视为空。
    @Test("默认高分榜 25 条记录均为空")
    func testDefaultTableIsEmpty() {
        let table = HighScoreTable()
        for difficulty in Difficulty.allCases {
            let list = table.scores(for: difficulty)
            #expect(list.count == 5, "\(difficulty) 应有 5 条记录")
            for entry in list {
                #expect(entry.isEmpty, "默认记录应为「无成绩」")
                #expect(entry.score == 99_999, "默认记录分数应为 99999")
            }
        }
    }

    // MARK: - 计时起点

    /// **计时从第一次点击起算，不含「启动后到第一次点击」的等待**。
    ///
    /// 反汇编里 `+0xC1A4`（基准）只在 5 处「关卡初始化」被写，
    /// **第一次点击不重置** —— 也就是原版会把启动后发呆的时间算进成绩。
    /// 本移植按用户 2026-10-22 的决定改为第一次操作才起算
    /// （见 `GameSession.markStartedIfNeeded`）。
    @Test("计时从第一次点击起算，不含启动后的等待")
    func timerStartsAtFirstAction() {
        let session = GameSession(difficulty: .beginner,
                                  generator: SeededGenerator(seed: 2026))
        // 模拟「app 启动后发呆 0.35 秒」
        Thread.sleep(forTimeInterval: 0.35)

        #expect(session.elapsedDeciseconds == 0, "未开始时计时必须为 0")
        #expect(session.board.state == .ready)

        session.reveal(row: 0, column: 0)
        // 刚点完，应立即从 0 起算（允许 1 个单位的调度误差）
        let justAfter = session.elapsedDeciseconds
        #expect(justAfter <= 1,
                "第一次点击后应从 0 起算，实际 \(justAfter)（说明基准还是启动时刻）")

        // 再等 0.35 秒，应该约 3~4 个十分之一秒
        Thread.sleep(forTimeInterval: 0.35)
        let later = session.elapsedDeciseconds
        #expect(later >= 2 && later <= 8,
                "0.35 秒后应约 3~4 个十分之一秒，实际 \(later)")
    }

    /// 插旗也会启动计时（原版里首次插旗同样让局面离开「未开始」）。
    @Test("首次插旗也起算计时")
    func timerStartsOnFirstFlag() {
        let session = GameSession(difficulty: .beginner,
                                  generator: SeededGenerator(seed: 7))
        Thread.sleep(forTimeInterval: 0.3)
        session.toggleFlag(row: 1, column: 1)
        let justAfter = session.elapsedDeciseconds
        #expect(justAfter <= 1,
                "首次插旗后应从 0 起算，实际 \(justAfter)")
    }

    /// 重开一局（切难度 / 点笑脸）会重置计时基准。
    @Test("重开一局重置计时基准")
    func restartResetsTimer() {
        let session = GameSession(difficulty: .beginner,
                                  generator: SeededGenerator(seed: 9))
        session.reveal(row: 0, column: 0)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(session.elapsedDeciseconds >= 2, "应先跑起来")

        session.restart()
        #expect(session.elapsedDeciseconds == 0, "重开后应回到 0")
        Thread.sleep(forTimeInterval: 0.2)
        #expect(session.elapsedDeciseconds == 0, "重开后未点击，仍应为 0")
    }
}
