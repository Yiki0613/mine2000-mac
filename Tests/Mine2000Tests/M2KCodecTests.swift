import Testing
import Foundation
@testable import Mine2000

/// `.m2k` 成绩档的字节级编解码测试。
///
/// ────────────────────────────────────────────────────────────────────────
/// **核心硬标准**：读原版 `hiscore.dat` → 解码 → 再编码 → **字节完全一致**。
/// 这是验证 `.m2k` 实现正确性的最终判据。
/// ────────────────────────────────────────────────────────────────────────
@Suite(".m2k 成绩档编解码")
struct M2KCodecTests {

    /// 原版 `hiscore.dat` 的路径。
    ///
    /// 优先读仓库内夹具 `Tests/Fixtures/hiscore.dat`（325 字节，原版默认档原样拷贝），
    /// 保证 clone 下来即可跑测试、CI 上也能复现。
    /// 若本地还留着原版解包产物，则回退到原始位置做交叉校验。
    static var hiscoreURL: URL {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Mine2000Tests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/hiscore.dat")
        if FileManager.default.fileExists(atPath: fixtures.path) {
            return fixtures
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Mine2000Tests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .deletingLastPathComponent()   // 上一级
            .appendingPathComponent("原始文件/解包产物/hiscore.dat")
    }

    /// 读取原版默认档的原始字节。
    static func loadHiscoreBytes() throws -> [UInt8] {
        let url = hiscoreURL
        #expect(FileManager.default.fileExists(atPath: url.path),
                "找不到原版成绩档：\(url.path)")
        return [UInt8](try Data(contentsOf: url))
    }

    // MARK: - 往返测试（硬标准）

    /// **字节级往返**：解码原版默认档 → 重新编码 → 与原文件逐字节相同。
    @Test("原版 hiscore.dat 字节级往返完全一致")
    func testByteExactRoundTrip() throws {
        let original = try Self.loadHiscoreBytes()

        // 前提校验：文件长度应为 325 字节（25 条 × 13 字节）。
        #expect(original.count == 325, "原版成绩档应为 325 字节，实际 \(original.count)")

        // 解码 → 重新编码
        let table = try M2KCodec.decode(original)
        let reencoded = try M2KCodec.encode(table)

        // 硬标准：字节完全一致
        #expect(reencoded.count == original.count,
                "重新编码后长度应为 \(original.count)，实际 \(reencoded.count)")
        #expect(reencoded == original, "重新编码后的字节与原文件不一致")

        // 逐字节定位第一个差异，便于失败时排查
        if reencoded != original {
            for (i, (a, b)) in zip(original, reencoded).enumerated() {
                if a != b {
                    Issue.record("第 \(i) 字节不同：原文件 \(String(a, radix: 16)) vs 重新编码 \(String(b, radix: 16))")
                    break
                }
            }
        }
    }

    /// 往返两次仍一致（幂等性）。
    @Test("连续两次往返字节稳定")
    func testRoundTripIsIdempotent() throws {
        let original = try Self.loadHiscoreBytes()
        let once = try M2KCodec.encode(try M2KCodec.decode(original))
        let twice = try M2KCodec.encode(try M2KCodec.decode(once))
        #expect(once == twice, "第二次往返结果与第一次不同")
        #expect(once == original, "第一次往返即与原文件不同")
    }

    // MARK: - 字段语义

    /// 默认档的 25 条记录内容：名字「名前なし」、分数 99999。
    @Test("默认档 25 条记录均为 名前なし / 99999")
    func testDefaultFileContents() throws {
        let original = try Self.loadHiscoreBytes()
        let table = try M2KCodec.decode(original)

        for difficulty in Difficulty.allCases {
            let list = table.scores(for: difficulty)
            #expect(list.count == 5, "\(difficulty) 应有 5 条记录")
            for (i, entry) in list.enumerated() {
                #expect(entry.name == "名前なし",
                        "\(difficulty) 第 \(i + 1) 条名字应为「名前なし」，实际「\(entry.name)」")
                #expect(entry.score == 99_999,
                        "\(difficulty) 第 \(i + 1) 条分数应为 99999，实际 \(entry.score)")
                #expect(entry.isEmpty, "\(difficulty) 第 \(i + 1) 条应被识别为「无成绩」")
            }
        }
    }

    /// 单条记录的字节布局：`[长度][名字][4 字节小端分数]`。
    @Test("单条记录布局为 长度 + Shift-JIS 名字 + uint32 小端分数")
    func testRecordLayout() throws {
        // 分数必须在合法区间内（原版上限 99999 = 0x1869F）
        let entry = HighScoreEntry(name: "AB", score: 0x0102)
        let bytes = try M2KCodec.encodeRecord(entry)

        #expect(bytes.count == 1 + 2 + 4, "记录长度应为 7 字节")
        #expect(bytes[0] == 2, "首字节应为名字长度")
        #expect(bytes[1] == 0x41, "名字首字节应为 'A'")
        #expect(bytes[2] == 0x42, "名字次字节应为 'B'")
        // 分数小端：02 01 00 00
        #expect(Array(bytes[3...]) == [0x02, 0x01, 0x00, 0x00],
                "分数应为 uint32 小端序")

        // 解回来应完全一致
        let (decoded, consumed) = try M2KCodec.decodeRecord(bytes, at: 0)
        #expect(consumed == bytes.count, "消耗字节数应等于记录长度")
        #expect(decoded == entry, "解码结果应与原记录相等")
    }

    /// 日文名字的 Shift-JIS 往返。
    @Test("日文名字 Shift-JIS 往返无损")
    func testJapaneseNameRoundTrip() throws {
        let names = ["名前なし", "たなか", "山田太郎", "A", "高橋・佐藤"]
        for name in names {
            let bytes = try M2KCodec.encodeName(name)
            #expect(M2KCodec.decodeName(bytes) == name, "名字「\(name)」往返后不一致")
        }
    }

    /// 「名前なし」的 Shift-JIS 字节应与原版默认档一致。
    @Test("「名前なし」的 Shift-JIS 字节与原版一致")
    func testDefaultNameBytes() throws {
        let bytes = try M2KCodec.encodeName("名前なし")
        #expect(bytes == [0x96, 0xBC, 0x91, 0x4F, 0x82, 0xC8, 0x82, 0xB5],
                "「名前なし」的 Shift-JIS 字节应为 96 bc 91 4f 82 c8 82 b5")
    }

    /// 大端/小端混淆会导致分数错位 —— 断言分数确实按小端解析。
    @Test("分数按小端序解析")
    func testScoreIsLittleEndian() throws {
        var bytes: [UInt8] = [0x01]  // 名字长度 1
        bytes.append(0x41)            // 名字 'A'
        bytes.append(contentsOf: [0x01, 0x00, 0x00, 0x00])  // 分数 = 1（小端）
        let (entry, _) = try M2KCodec.decodeRecord(bytes, at: 0)
        #expect(entry.score == 1, "小端分数 01 00 00 00 应解析为 1，实际 \(entry.score)")
    }

    /// 数据不足时应抛出明确的错误。
    @Test("数据不足时抛出 truncatedData")
    func testTruncatedDataThrows() {
        #expect(throws: M2KCodec.CodecError.self) {
            try M2KCodec.decodeRecord([0x08, 0x96], at: 0)
        }
    }

    /// 无法用 Shift-JIS 表示的名字应抛错（而不是静默丢字节）。
    @Test("无法 Shift-JIS 编码的名字抛出 notEncodable")
    func testNotEncodableNameThrows() {
        // emoji 无法用 Shift-JIS 表示
        #expect(throws: M2KCodec.CodecError.self) {
            try M2KCodec.encodeName("😀")
        }
    }

    /// 长名字（≥ 0xFF 字节）应按 MFC `CArchive` 规则用扩展长度前缀。
    ///
    /// - [已确证] 原版写盘用 MFC `CArchive::operator<<(CString&)`：
    ///   长度 < 0xFF 写 1 字节长度，否则写 `0xFF` + 2 字节小端长度。
    @Test("超长名字使用 0xFF 扩展长度前缀")
    func testLongNameUsesExtendedLengthPrefix() throws {
        // 造一个 ≥ 255 字节的 Shift-JIS 名字
        let long = String(repeating: "あ", count: 130)   // 260 字节
        let entry = HighScoreEntry(name: long, score: 1_234)
        let bytes = try M2KCodec.encodeRecord(entry)

        #expect(bytes[0] == 0xFF, "长度 ≥ 0xFF 时首字节应为 0xFF 标记")
        let extLen = Int(bytes[1]) | (Int(bytes[2]) << 8)
        #expect(extLen == 260, "扩展长度应为 260，实际 \(extLen)")

        // 应能原样解回来
        let (decoded, consumed) = try M2KCodec.decodeRecord(bytes, at: 0)
        #expect(consumed == bytes.count, "消耗字节数应等于记录长度")
        #expect(decoded.name == long, "长名字往返后不一致")
        #expect(decoded.score == 1_234, "分数应保持不变")
    }
}
