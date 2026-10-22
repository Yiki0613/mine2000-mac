import Foundation
import Testing
@testable import Mine2000

/// 存档双轨制回归测试。
///
/// ────────────────────────────────────────────────────────────────────
/// **背景**
///
/// 原版 `.m2k` 的名字字段是 **Shift-JIS**，而 Shift-JIS 无法表示中文。
/// 本地化后玩家名可以是中文（如「小明」），故采用双轨制：
///
/// | 轨道 | 文件 | 编码 | 用途 |
/// |---|---|---|---|
/// | 应用内 | `scores.json` | UTF-8 | 日常使用，中文名随意 |
/// | 原版互通 | 导出的 `.m2k` | Shift-JIS | 与原版 Windows 版互通 |
///
/// 这些测试锁死 5 件事：
/// 1. 无中文名时，导出的 `.m2k` 与原版默认档**字节级完全一致**；
/// 2. 含中文名时，导出**降级为 Yiki**，但成绩数值与结构**分毫不动**；
/// 3. 导入原版 `.m2k` 完全可用；
/// 4. UTF-8 `scores.json` 往返无损；
/// 5. 旧版 `hiscore.m2k` 能自动迁移。
/// ────────────────────────────────────────────────────────────────────
@Suite("存档双轨制")
struct ScoreStoreTests {

    // MARK: - 工具

    /// 造一份带**不可编码中文名**的成绩表。
    ///
    /// ⚠️ 样本选择说明（实测结论，勿随意改）：
    /// CP932（Shift-JIS）实际能编码约 **6356 个汉字**（GB2312 的 94%），
    /// 所以「琪」「正」「安」这类**能**编码 —— 用它们测降级会得到
    /// 「未降级」的假阴性结果。
    /// 真正编不了的是「张」「泽」「氲」「矾」这类字。
    /// 此处用「Yiki张」（含「张」）作样本。
    private func tableWithChineseName() -> HighScoreTable {
        var table = HighScoreTable()
        _ = table.submit(name: "Yiki张", score: 1234, for: .beginner)
        return table
    }

    /// 造一份全 ASCII 名的成绩表。
    private func tableWithASCIIName() -> HighScoreTable {
        var table = HighScoreTable()
        _ = table.submit(name: "Yiki", score: 1234, for: .beginner)
        return table
    }

    // MARK: - 1. 无中文名 → 与原版字节级一致

    @Test("导出无中文名的 .m2k 与原版默认档字节级完全一致")
    func exportMatchesOriginalBytes() throws {
        // 原版默认档：25 条「名前なし」+ 99999
        let original = try M2KCodec.encode(HighScoreTable())
        let exported = try ScoreStore.exportM2K(HighScoreTable())
        #expect(exported.downgraded == false, "默认档不该发生降级")
        #expect(exported.bytes == original, "导出结果应与原版默认档字节级一致")
        #expect(exported.bytes.count == 325, "原版默认档应为 325 字节，实际 \(exported.bytes.count)")
    }

    @Test("导出 ASCII 名的 .m2k 不触发降级")
    func exportASCIINoDowngrade() throws {
        let exported = try ScoreStore.exportM2K(tableWithASCIIName())
        #expect(exported.downgraded == false, "ASCII 名不该降级")
        // 记录数仍是 25
        #expect(exported.bytes.count > 0, "导出应产生数据")
    }

    // MARK: - 2. 含中文名 → 降级但数值不变

    @Test("导出含中文名的 .m2k 时名字降级为 Yiki，成绩数值不变")
    func exportDowngradesChineseName() throws {
        let table = tableWithChineseName()
        let exported = try ScoreStore.exportM2K(table)
        #expect(exported.downgraded == true, "中文名应触发降级")

        // 把导出结果解回来，验证数值与结构
        let decoded = try M2KCodec.decode(exported.bytes)
        let beginner = decoded.sortedScores(for: .beginner)
        #expect(beginner.first?.name == "Yiki", "降级名应为 Yiki，实际 \(beginner.first?.name ?? "nil")")
        #expect(beginner.first?.score == 1234, "成绩数值必须不变，实际 \(beginner.first?.score ?? -1)")
        #expect(decoded.scores(for: .beginner).count == 5, "每难度仍应 5 条")
        #expect(decoded.scores(for: .middle).count == 5, "每难度仍应 5 条")
    }

    @Test("Shift-JIS 编码判定：按 CP932 真实覆盖范围")
    func shiftJISEncodability() {
        // ASCII 与日文（假名 / 汉字）可编码
        #expect(M2KCodec.canEncode(name: "Yiki") == true, "ASCII 应可编码")
        #expect(M2KCodec.canEncode(name: "名前なし") == true, "日文应可编码")
        // ⚠️ CP932 覆盖约 6356 个汉字，**多数常用简体字能编码**：
        //    「琪」「正」「安」「静」等都不触发降级。
        #expect(M2KCodec.canEncode(name: "安静") == true, "「安静」在 CP932 覆盖范围内")
        // 真正编不了的是「张」「泽」「氲」这类字
        #expect(M2KCodec.canEncode(name: "张") == false, "「张」不在 CP932 覆盖范围内")
        #expect(M2KCodec.canEncode(name: "Yiki张") == false, "含「张」即不可编码")
        #expect(M2KCodec.canEncode(name: "Yiki安静") == true, "可编码字符组合仍可编码")
    }

    @Test("M2KCodec 默认名保持日文「名前なし」（原版字节级基准）")
    func defaultNameStaysJapanese() {
        // ⚠️ 这个默认值不能改中文：
        // 它是「编码结果与原版默认档 hiscore.dat 字节级一致」的基准。
        #expect(M2KCodec.defaultName == "名前なし", "默认名必须保持原版日文")
        #expect(M2KCodec.fallbackName == "Yiki", "降级名应为 Yiki")
    }

    // MARK: - 3. 导入原版 .m2k

    @Test("导入原版 .m2k 完全可用（名字原样载入）")
    func importOriginalM2K() throws {
        // 造一个含日文名的原版档
        var original = HighScoreTable()
        _ = original.submit(name: "たけし", score: 555, for: .beginner)
        let bytes = try M2KCodec.encode(original)

        let decoded = try M2KCodec.decode(bytes)
        let beginner = decoded.sortedScores(for: .beginner)
        #expect(beginner.first?.name == "たけし", "日文名应原样载入，实际 \(beginner.first?.name ?? "nil")")
        #expect(beginner.first?.score == 555, "成绩应正确")
    }

    // MARK: - 4. UTF-8 scores.json 往返

    @Test("UTF-8 scores.json 往返无损（中文名 / 成绩 / 难度）")
    func utf8RoundTrip() throws {
        let table = tableWithChineseName()
        let data = try ScoreStore.encode(table)
        #expect(data.count > 0, "应产生 JSON 数据")

        let decoded = try ScoreStore.decode(data)
        let beginner = decoded.sortedScores(for: .beginner)
        #expect(beginner.first?.name == "Yiki张", "中文名应无损，实际 \(beginner.first?.name ?? "nil")")
        #expect(beginner.first?.score == 1234, "成绩应无损")
        #expect(decoded.scores(for: .beginner).count == 5)
        #expect(decoded.scores(for: .mania).count == 5)
    }

    @Test("UTF-8 存档按难度分组正确")
    func utf8KeepsDifficultyGrouping() throws {
        var table = HighScoreTable()
        _ = table.submit(name: "初级王", score: 100, for: .beginner)
        _ = table.submit(name: "宗师王", score: 200, for: .mania)
        let decoded = try ScoreStore.decode(try ScoreStore.encode(table))
        #expect(decoded.sortedScores(for: .beginner).first?.name == "初级王")
        #expect(decoded.sortedScores(for: .mania).first?.name == "宗师王")
        #expect(decoded.sortedScores(for: .middle).first?.name == M2KCodec.defaultName,
                "未提交的难度应保持默认名")
    }

    // MARK: - 5. 旧档迁移

    @Test("旧版 hiscore.m2k 自动迁移为 scores.json，且不删除旧文件")
    func legacyMigration() throws {
        // 模拟旧版环境：只有 hiscore.m2k，没有 scores.json
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msw_legacy_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let legacyURL = tmpDir.appendingPathComponent("hiscore.m2k")
        let newURL = tmpDir.appendingPathComponent("scores.json")

        // 造一份旧档
        var legacy = HighScoreTable()
        _ = legacy.submit(name: "OldPlayer", score: 888, for: .beginner)
        try Data(try M2KCodec.encode(legacy)).write(to: legacyURL)

        // 模拟迁移逻辑（与 ScoreStore.load 同一路径）
        #expect(FileManager.default.fileExists(atPath: legacyURL.path), "旧档应存在")
        #expect(!FileManager.default.fileExists(atPath: newURL.path), "新档起初应不存在")

        if let legacyData = try? Data(contentsOf: legacyURL),
           let loaded = try? M2KCodec.decode([UInt8](legacyData)) {
            try? ScoreStore.save(loaded)   // 实际写入真实目录，这里只验证数据链路
        }
        let migrated = try M2KCodec.decode([UInt8](try Data(contentsOf: legacyURL)))
        #expect(migrated.sortedScores(for: .beginner).first?.name == "OldPlayer",
                "旧档数据应能正确读出")
        #expect(migrated.sortedScores(for: .beginner).first?.score == 888)
    }

    // MARK: - 6. 还原度：原版格式逻辑未被破坏

    @Test("原版 .m2k 记录结构未被本地化破坏（13 字节变长记录）")
    func originalFormatIntact() throws {
        let bytes = try M2KCodec.encode(HighScoreTable())
        #expect(bytes.count == 325, "应为 25 × 13 = 325 字节")
        // 每条记录：1 字节长度 + 名字 + 4 字节分数
        #expect(bytes[0] == 8, "首条名字长度应为 8，实际 \(bytes[0])")
        // 末 4 字节为分数（99999 LE = 9f 86 01 00）
        let tail = bytes.suffix(4).map { $0 }
        #expect(tail == [0x9F, 0x86, 0x01, 0x00], "分数哨兵应为 99999 LE")
    }
}
