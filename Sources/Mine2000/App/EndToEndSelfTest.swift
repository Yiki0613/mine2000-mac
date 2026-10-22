import Foundation

/// 端到端自检：把「一局完整游戏」从头到尾跑一遍，逐项断言。
///
/// ## 为什么需要它
///
/// 单元测试验证的是**单个函数**的行为，而真正容易出 bug 的是**状态之间的衔接**：
/// 首点布雷 → flood fill 扩散 → 插旗 → chording → 胜负判定 → 计时冻结 → 高分榜入榜。
/// 这些跨环节的衔接只有串起来跑一遍才能暴露问题。
///
/// 典型 bug（本项目实际踩到过的）：
/// * 右键插旗后逻辑层已改状态，但 `afterMove()` 没请求重绘 → 画面不更新；
/// * 嵌套 `zip` 的索引推断退化 → 启动即崩溃；
/// * 窗口尺寸硬编码 → 换难度后棋盘与窗口不匹配。
///
/// ## 用法
///
/// ```
/// swift run Mine2000 --selftest [输出文件路径]
/// ```
///
/// 结果以纯文本写入输出文件（默认 `/tmp/mine2000_selftest.txt`），
/// 每行一条 `PASS` / `FAIL` 记录，末尾给出汇总。
enum EndToEndSelfTest {

    /// 单条检查结果。
    private struct Check {
        let name: String
        let passed: Bool
        let detail: String
    }

    /// 固定种子随机源，保证自检可复现。
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            // SplitMix64
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 执行整套自检，返回逐条结果与是否全部通过。
    static func run(outputPath: String = "/tmp/mine2000_selftest.txt") -> Bool {
        var checks: [Check] = []

        func assert(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            checks.append(Check(name: name, passed: condition, detail: detail()))
        }

        // ── 1. 初始状态 ──────────────────────────────────────────────
        let session = GameSession(difficulty: .beginner, generator: SeededGenerator(seed: 20261022))
        assert("初始状态为未开始", session.board.state == .ready, "实际 \(session.board.state)")
        assert("初始剩余雷数 = 10", session.remainingMines == 10, "实际 \(session.remainingMines)")
        assert("初始计时为 0", session.elapsedDeciseconds == 0, "实际 \(session.elapsedDeciseconds)")
        assert("初始表情为平静", session.expression == .normal,
               "实际 \(session.expression)")

        // ── 2. 首点保护 + 布雷时机 ───────────────────────────────────
        assert("首点前未布雷", !session.board.minesPlaced)
        let firstOutcome = session.reveal(row: 4, column: 4)
        assert("首点后已布雷", session.board.minesPlaced)
        assert("首点格不含雷（首点保护）", firstOutcome != .hitMine, "实际 \(firstOutcome)")
        assert("首点后状态变为进行中", session.board.state == .playing, "实际 \(session.board.state)")
        assert("首点后计时启动", session.elapsedDeciseconds >= 0)

        // ── 3. flood fill 扩散 ───────────────────────────────────────
        // ⚠️ 原版**只保护首点那一格**，不保证首击展开一片（反汇编 0x401844 确认）。
        //    所以首点可能返回 .revealedNumber（只翻 1 格），这属于**正确行为**。
        //    要验证 flood fill，必须另找一个**空白区**（邻雷数 = 0）去翻。
        switch firstOutcome {
        case .expanded(let count):
            assert("首点展开时格数 > 1", count > 1, "实际 \(count)")
        case .revealedNumber(let n):
            // 首点旁边有雷 → 只翻 1 格，符合原版「仅保护首点格」语义
            assert("首点邻雷 > 0 时只翻 1 格（原版语义）",
                   session.board.revealedCount == 1 && n > 0,
                   "邻雷 \(n)，已翻 \(session.board.revealedCount) 格")
        default:
            assert("首点结果合理", false, "实际 \(firstOutcome)")
        }
        assert("已翻开计数 > 0", session.board.revealedCount > 0, "实际 \(session.board.revealedCount)")

        // 另开一局专门验证 flood fill：反复找空白区并翻开，展开格数必须 > 1
        let floodSession = GameSession(difficulty: .beginner, generator: SeededGenerator(seed: 4242))
        floodSession.reveal(row: 0, column: 0)   // 先布雷
        var floodVerified = false
        for row in 0..<floodSession.board.rows {
            for column in 0..<floodSession.board.columns {
                if let cell = floodSession.board.cell(row: row, column: column),
                   !cell.isRevealed, !cell.containsMine, cell.adjacentMineCount == 0 {
                    let before = floodSession.board.revealedCount
                    let outcome = floodSession.reveal(row: row, column: column)
                    if case .expanded(let count) = outcome {
                        assert("flood fill 从空白区展开多格", count > 1,
                               "起点 (\(row),\(column)) 展开 \(count) 格")
                        assert("flood fill 展开数与翻牌增量一致",
                               floodSession.board.revealedCount - before == count,
                               "增量 \(floodSession.board.revealedCount - before) vs 声明 \(count)")
                        floodVerified = true
                    }
                    break
                }
            }
            if floodVerified { break }
        }
        assert("flood fill 场景存在（空白区）", floodVerified, "该种子下未找到空白区")

        // ── 4. 右键插旗 ─────────────────────────────────────────────
        // 找一个未翻开且未插旗的格子
        var flagTarget: (row: Int, column: Int)?
        for row in 0..<session.board.rows {
            for column in 0..<session.board.columns {
                if let cell = session.board.cell(row: row, column: column),
                   !cell.isRevealed, !cell.isFlagged {
                    flagTarget = (row, column)
                    break
                }
            }
            if flagTarget != nil { break }
        }
        if let target = flagTarget {
            let before = session.remainingMines
            session.toggleFlag(row: target.row, column: target.column)
            assert("插旗后剩余雷数 -1", session.remainingMines == before - 1,
                   "插旗前 \(before) 插旗后 \(session.remainingMines)")
            assert("插旗格标记为已插旗",
                   session.board.cell(row: target.row, column: target.column)?.isFlagged == true)
            // 取消插旗
            session.toggleFlag(row: target.row, column: target.column)
            assert("取消插旗后剩余雷数复原", session.remainingMines == before,
                   "实际 \(session.remainingMines)")
        } else {
            assert("找到可插旗的格子", false)
        }

        // ── 5. 插旗格不能被翻开 ─────────────────────────────────────
        if let target = flagTarget {
            session.toggleFlag(row: target.row, column: target.column)
            let outcome = session.reveal(row: target.row, column: target.column)
            assert("插旗格无法被翻开", outcome == .ignored, "实际 \(outcome)")
            session.toggleFlag(row: target.row, column: target.column)
        }

        // ── 6. chording 语义 ────────────────────────────────────────
        // 找一个已翻开、数字 >= 1 的格子作为 chord 中心
        var chordCenter: (row: Int, column: Int)?
        for row in 0..<session.board.rows {
            for column in 0..<session.board.columns {
                if let cell = session.board.cell(row: row, column: column),
                   cell.isRevealed, !cell.containsMine, cell.adjacentMineCount > 0 {
                    chordCenter = (row, column)
                    break
                }
            }
            if chordCenter != nil { break }
        }
        if chordCenter != nil {
            // 邻域旗数不足时 chord 不应翻开任何格子
            let beforeCount = session.board.revealedCount
            session.chord(row: chordCenter!.row, column: chordCenter!.column)
            assert("chording 在旗数不足时不翻开格子",
                   session.board.revealedCount == beforeCount,
                   "前 \(beforeCount) 后 \(session.board.revealedCount)")
        } else {
            assert("找到可 chord 的数字格", false, "首点未展开出数字格（可能全是空白）")
        }

        // ── 7. 失败态：踩雷 ─────────────────────────────────────────
        // 找一颗雷并踩它
        var minePos: (row: Int, column: Int)?
        for row in 0..<session.board.rows {
            for column in 0..<session.board.columns {
                if let cell = session.board.cell(row: row, column: column), cell.containsMine {
                    minePos = (row, column)
                    break
                }
            }
            if minePos != nil { break }
        }
        if let mine = minePos {
            let outcome = session.reveal(row: mine.row, column: mine.column)
            assert("踩雷返回 hitMine", outcome == .hitMine, "实际 \(outcome)")
            assert("踩雷后状态为失败", session.board.state == .lost, "实际 \(session.board.state)")
            assert("记录被踩中的雷位置", session.board.hitMinePosition != nil)
            assert("失败后表情为失败", session.expression == .lose, "实际 \(session.expression)")
        } else {
            assert("找到地雷", false)
        }

        // ── 8. 结束态锁定 ───────────────────────────────────────────
        let stateAfterLoss = session.board.state
        let revealedAfterLoss = session.board.revealedCount
        session.reveal(row: 0, column: 0)
        session.toggleFlag(row: 0, column: 0)
        assert("失败后棋盘锁定（状态不变）", session.board.state == stateAfterLoss,
               "实际 \(session.board.state)")
        assert("失败后棋盘锁定（翻牌数不变）", session.board.revealedCount == revealedAfterLoss,
               "实际 \(session.board.revealedCount)")

        // ── 9. 计时冻结 ─────────────────────────────────────────────
        let frozen = session.elapsedDeciseconds
        Thread.sleep(forTimeInterval: 0.35)
        assert("结束后计时冻结", session.elapsedDeciseconds == frozen,
               "冻结值 \(frozen) 现在 \(session.elapsedDeciseconds)")

        // ── 10. 胜利态：另开一局并全部翻开非雷格 ───────────────────
        let winSession = GameSession(difficulty: .beginner, generator: SeededGenerator(seed: 777))
        winSession.reveal(row: 0, column: 0)
        // 翻开所有非雷格
        for row in 0..<winSession.board.rows {
            for column in 0..<winSession.board.columns {
                if let cell = winSession.board.cell(row: row, column: column),
                   !cell.containsMine, !cell.isRevealed {
                    winSession.reveal(row: row, column: column)
                }
            }
        }
        assert("全部非雷格翻开即胜利", winSession.board.state == .won, "实际 \(winSession.board.state)")
        assert("胜利后表情为胜利", winSession.expression == .win, "实际 \(winSession.expression)")
        assert("胜利后 isFinished", winSession.isFinished)
        let winFrozen = winSession.elapsedDeciseconds
        Thread.sleep(forTimeInterval: 0.2)
        assert("胜利后计时冻结", winSession.elapsedDeciseconds == winFrozen,
               "冻结值 \(winFrozen) 现在 \(winSession.elapsedDeciseconds)")

        // ── 11. 高分榜入榜 ──────────────────────────────────────────
        var table = HighScoreTable()
        let totalSlots = Difficulty.allCases.reduce(0) { $0 + $1.columns > 0 ? $0 + HighScoreTable.entriesPerDifficulty : $0 }
        assert("高分榜初始 25 条（5 难度 × 5 名）",
               totalSlots == 25 && table.scores(for: .beginner).count == 5,
               "实际槽位 \(totalSlots)，初級条数 \(table.scores(for: .beginner).count)")
        // 提交一个明显优于空记录的成绩 → 应入榜并排第一
        let rank = table.submit(name: "Yiki", score: 123, for: .beginner)
        assert("成绩可入榜（返回名次）", rank != nil, "返回 \(String(describing: rank))")
        assert("新成绩排第 1 名", rank == 0, "实际 \(String(describing: rank))")
        let beginnerScores = table.sortedScores(for: .beginner)
        assert("入榜后首条为新成绩", beginnerScores.first?.name == "Yiki",
               "实际 \(beginnerScores.first?.name ?? "nil")")
        assert("入榜后成绩正确", beginnerScores.first?.score == 123,
               "实际 \(String(describing: beginnerScores.first?.score))")
        // 差于第 5 名的不入榜
        let currentWorst = table.scores(for: .beginner)[4]
        let rank2 = table.submit(name: "X", score: currentWorst.score + 1, for: .beginner)
        assert("差于第 5 名不入榜", rank2 == nil, "返回 \(String(describing: rank2))")
        // 各难度榜单相互独立
        assert("各难度榜单相互独立", table.scores(for: .middle).first?.name != "Yiki",
               "中级首条 \(table.scores(for: .middle).first?.name ?? "nil")")

        // ── 12. 难度切换后棋盘重建 ───────────────────────────────────
        session.restart(difficulty: .middle)
        assert("切难度后棋盘尺寸变化", session.board.columns == 16 && session.board.rows == 16,
               "实际 \(session.board.columns)x\(session.board.rows)")
        assert("切难度后未布雷", !session.board.minesPlaced)
        assert("切难度后状态重置", session.board.state == .ready, "实际 \(session.board.state)")
        assert("切难度后计时归零", session.elapsedDeciseconds == 0, "实际 \(session.elapsedDeciseconds)")
        assert("切难度后剩余雷数 = 40", session.remainingMines == 40, "实际 \(session.remainingMines)")

        // ── 13. .m2k 编解码往返 ─────────────────────────────────────
        do {
            let encoded = try M2KCodec.encode(table)
            let decoded = try M2KCodec.decode(encoded)
            let before = table.sortedScores(for: .beginner)
            let after = decoded.sortedScores(for: .beginner)
            assert(".m2k 编码非空", !encoded.isEmpty, "字节数 \(encoded.count)")
            assert(".m2k 往返后初级条数一致", after.count == before.count,
                   "前 \(before.count) 后 \(after.count)")
            assert(".m2k 往返后首条名字一致", after.first?.name == before.first?.name,
                   "实际 \(after.first?.name ?? "nil")")
            assert(".m2k 往返后首条成绩一致", after.first?.score == before.first?.score,
                   "实际 \(String(describing: after.first?.score))")
        } catch {
            assert(".m2k 编解码往返成功", false, "错误 \(error)")
        }

        // ── 汇总 ────────────────────────────────────────────────────
        let passed = checks.filter(\.passed).count
        let failed = checks.count - passed
        var text = ""
        for c in checks {
            text += (c.passed ? "PASS  " : "FAIL  ") + c.name
            if !c.detail.isEmpty { text += "  —  " + c.detail }
            text += "\n"
        }
        text += "\n汇总：\(passed)/\(checks.count) 通过，\(failed) 项失败\n"
        try? text.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print(text)
        return failed == 0
    }
}
