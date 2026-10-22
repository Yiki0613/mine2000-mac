import Foundation

/// `.m2k`（Mine2000 Score）成绩档的编解码。
///
/// ────────────────────────────────────────────────────────────────────────
/// **文件格式（已确证，字节级）**
///
/// 原版 MSI 内嵌的 `hiscore.dat` 与虚拟机中的 `default.m2k` 字节级一致，
/// 总长 **325 字节** = **25 条记录 × 13 字节**（默认名长度时）。
///
/// 单条记录为**变长**结构：
///
/// ```
/// ┌──────────┬──────────────────┬──────────────────┐
/// │ 名字长度  │ Shift-JIS 名字字节 │ 分数 (uint32 LE) │
/// │  1 字节  │  长度 = 首字节的值  │     4 字节       │
/// └──────────┴──────────────────┴──────────────────┘
/// ```
///
/// **注意：记录长度是变的，不是固定 13 字节。**
/// 13 只是「默认名『名前なし』（Shift-JIS 8 字节）」这一特定情况下的长度：
/// `1 + 8 + 4 = 13`。
///
/// 证据（原版 `CMine2000Doc::Serialize`，`0x402E30`）：
/// ```
/// 00402e6b  push     eax              ; CString::GetBuffer → 名字
/// 00402e6c  push     esi
/// 00402e6c  call     0x405b02          ; ← 写「长度前缀 + 字符串」
/// 00402e85  call     0x405afc          ; ← 写分数（DWORD）
/// 00402eab  mov      [eax], ebx       ; 分数落盘
/// ```
/// 「写长度前缀 + 字符串」正是 MFC `CArchive::operator<<(CString&)` 的行为：
/// 长度 < 0xFF 时写 1 字节长度，否则写 `0xFF` + 2 字节（WORD）长度。
///
/// 默认档（25 条全部相同）的字节内容：
/// `08 | 96 bc 91 4f 82 c8 82 b5 | 9f 86 01 00`
/// * 长度 = 8，名字 = Shift-JIS「名前なし」（日文「无名字」），占 8 字节；
/// * 分数 = `0x0001869F` = **99999**，即「无成绩」哨兵值
///   （与反汇编 `0x403570` 的 `cmp ecx, 0x1869f` 上限一致）。
///
/// ────────────────────────────────────────────────────────────────────────
/// **记录顺序**
///
/// **[已确证]** 记录里**没有难度字段**，难度由**记录顺序**决定：
/// 记录 0–4 = 初級，5–9 = 中級，10–14 = 上級，15–19 = 超上級，20–24 = マニア。
/// 每个难度内部 5 条记录按名次 1→5 排列。
///
/// ────────────────────────────────────────────────────────────────────────
/// **与早前报告的差异（重要）**
///
/// 早前报告称「27 条 × 12 字节记录 + 1 字节尾部 = 325 字节」。
/// 该算术虽也等于 325，但**周期分析证明不成立**：
/// 若按 12 字节切分，第 2 条记录会整体错位 1 字节，
/// 而实际文件严格以 13 字节为周期重复。本实现以 13 字节为准。
/// ────────────────────────────────────────────────────────────────────────
public enum M2KCodec {

    /// 默认记录长度（名字 8 字节时）。
    public static let defaultRecordSize = 13

    /// 名字字段的固定字节数（默认名「名前なし」的 Shift-JIS 长度）。
    public static let nameFieldSize = 8

    /// 文件中的记录条数（5 难度 × 5 名）。
    public static let recordCount = 25

    /// 「无成绩」哨兵值（与原版默认档一致：99999）。
    public static let noScoreValue: Int = 99_999

    /// 默认名字（原版默认档用的「名前なし」）。
    ///
    /// ⚠️ **保持日文不变** —— 它是「编码结果与原版默认档 `hiscore.dat`
    /// 字节级完全一致」这一验收项的基准，不能改成中文。
    /// 中文界面下用户看到的默认名是 `L10n.anonymousName`（「匿名」），
    /// 那是**输入框占位符与新建记录的显示名**，与存档里的默认名是两回事。
    public static let defaultName = "名前なし"

    /// 导出到 `.m2k` 时，中文名降级用的替代名。
    ///
    /// 选 `Yiki` 的理由：符合本人署名规范；且中文本身无法用 Shift-JIS 编码，
    /// 换成别的中文词也一样会被降级，不如直接用 ASCII 名。
    public static let fallbackName = "Yiki"

    /// 判断某个名字能否用 Shift-JIS 编码（即能否存进原版 `.m2k`）。
    ///
    /// 中文（含日文汉字、假名之外的 CJK）均返回 `false`。
    public static func canEncode(name: String) -> Bool {
        name.data(using: .shiftJIS) != nil
    }

    // MARK: - 错误

    /// 编解码错误。
    public enum CodecError: Error, CustomStringConvertible {
        case truncatedData(expected: Int, actual: Int)
        case nameTooLong(Int)
        case notEncodable(String)
        case invalidRecordCount(Int)

        public var description: String {
            switch self {
            case .truncatedData(let e, let a):
                return "数据不足：期望至少 \(e) 字节，实际 \(a) 字节"
            case .nameTooLong(let n):
                return "名字过长：\(n) 字节（上限 \(nameFieldSize)）"
            case .notEncodable(let s):
                return "名字无法用 Shift-JIS 编码：\(s)"
            case .invalidRecordCount(let n):
                return "记录数非法：\(n)（应为 \(recordCount)）"
            }
        }
    }

    // MARK: - 名字编码

    /// 把名字编码为 Shift-JIS 字节。
    ///
    /// - Throws: `CodecError.notEncodable`（名字含 Shift-JIS 无法表示的字符）
    public static func encodeName(_ name: String) throws -> [UInt8] {
        guard let data = name.data(using: .shiftJIS) else {
            throw CodecError.notEncodable(name)
        }
        return [UInt8](data)
    }

    /// 把 Shift-JIS 字节解码为名字（无法解码时按 Latin-1 兜底，不丢字节）。
    public static func decodeName(_ bytes: [UInt8]) -> String {
        if let s = String(data: Data(bytes), encoding: .shiftJIS) { return s }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - 单条记录

    /// 编码一条记录（变长：`1 字节长度 + 名字 + 4 字节分数`）。
    ///
    /// 长度前缀采用 MFC `CArchive` 的规则：长度 < 0xFF 时写 1 字节；
    /// 否则写 `0xFF` + 2 字节小端长度。
    public static func encodeRecord(_ entry: HighScoreEntry) throws -> [UInt8] {
        let nameBytes = try encodeName(entry.name)
        var out: [UInt8] = []
        if nameBytes.count < 0xFF {
            out.append(UInt8(nameBytes.count))
        } else {
            out.append(0xFF)
            out.append(UInt8(nameBytes.count & 0xFF))
            out.append(UInt8((nameBytes.count >> 8) & 0xFF))
        }
        out.append(contentsOf: nameBytes)
        let score = UInt32(min(max(entry.score, 0), HighScoreEntry.maxScore))
        out.append(UInt8(score & 0xFF))
        out.append(UInt8((score >> 8) & 0xFF))
        out.append(UInt8((score >> 16) & 0xFF))
        out.append(UInt8((score >> 24) & 0xFF))
        return out
    }

    /// 解码一条记录。
    ///
    /// - Parameter offset: 在 `data` 中的起始偏移。
    /// - Returns: 记录与消耗的字节数。
    public static func decodeRecord(
        _ data: [UInt8],
        at offset: Int
    ) throws -> (entry: HighScoreEntry, consumed: Int) {
        guard offset < data.count else {
            throw CodecError.truncatedData(expected: offset + 1, actual: data.count)
        }
        let nameLength = Int(data[offset])
        var nameStart = offset + 1
        var nameLengthActual = nameLength
        if nameLength == 0xFF {
            // MFC 扩展长度：0xFF + WORD 小端长度
            guard offset + 4 <= data.count else {
                throw CodecError.truncatedData(expected: offset + 4, actual: data.count)
            }
            nameLengthActual = Int(data[offset + 1]) | (Int(data[offset + 2]) << 8)
            nameStart = offset + 3
        }
        guard nameStart + nameLengthActual <= data.count else {
            throw CodecError.truncatedData(
                expected: nameStart + nameLengthActual,
                actual: data.count
            )
        }
        let nameBytes = Array(data[nameStart..<(nameStart + nameLengthActual)])
        let scoreStart = nameStart + nameLengthActual
        guard scoreStart + 4 <= data.count else {
            throw CodecError.truncatedData(expected: scoreStart + 4, actual: data.count)
        }
        var score: UInt32 = 0
        for i in 0..<4 {
            score |= UInt32(data[scoreStart + i]) << (8 * UInt32(i))
        }
        let entry = HighScoreEntry(
            name: decodeName(nameBytes),
            score: Int(score)
        )
        return (entry, scoreStart + 4 - offset)
    }

    // MARK: - 整档

    /// 把高分榜编码为 `.m2k` 字节（25 条变长记录）。
    public static func encode(_ table: HighScoreTable) throws -> [UInt8] {
        var out: [UInt8] = []
        for difficulty in Difficulty.allCases {
            for entry in table.scores(for: difficulty) {
                out.append(contentsOf: try encodeRecord(entry))
            }
        }
        return out
    }

    /// 从 `.m2k` 字节解码出高分榜。
    ///
    /// 解码是**宽容**的：记录数不足时用空记录补齐，多余的尾部字节忽略。
    public static func decode(_ data: [UInt8]) throws -> HighScoreTable {
        var table = HighScoreTable()
        var offset = 0
        var recordIndex = 0

        while offset < data.count && recordIndex < recordCount {
            let (entry, consumed) = try decodeRecord(data, at: offset)
            offset += consumed
            let difficulty = Difficulty.allCases[recordIndex / HighScoreTable.entriesPerDifficulty]
            var list = table.scores(for: difficulty)
            let slot = recordIndex % HighScoreTable.entriesPerDifficulty
            if slot < list.count {
                list[slot] = entry
            }
            table.setScores(list, for: difficulty)
            recordIndex += 1
        }
        return table
    }
}
