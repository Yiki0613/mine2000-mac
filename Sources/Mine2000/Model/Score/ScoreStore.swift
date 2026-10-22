import Foundation

/// 成绩持久化（UTF-8 双轨制）。
///
/// ## 为什么不用 `.m2k` 直接存
///
/// 原版 `.m2k` 的**名字字段是 Shift-JIS（CP932）**。
///
/// ⚠️ **实测结论（勿再简化成「Shift-JIS 不能存中文」）**：
/// CP932 覆盖**约 6356 个汉字**（GB2312 的 94%），
/// 故「琪」「正」「安」「静」这类**能**编码、能直接存进原版 `.m2k`；
/// 但「张」「泽」「氲」这类**不能**，会被 `M2KCodec.CodecError.notEncodable` 拒绝。
///
/// 所以问题不是「中文一律存不下」，而是**约 6% 的汉字存不下** ——
/// 降级机制依然必要，且必须在导出时静默降级 + 提示，不能让用户丢成绩。
///
/// 故采用**双轨制**：
///
/// | 轨道 | 文件 | 编码 | 用途 |
/// |---|---|---|---|
/// | 应用内 | `scores.json` | UTF-8 | 日常使用，名字可为任意中文 |
/// | 原版互通 | 用户导出的 `.m2k` | Shift-JIS | 与原版 Windows 版互通 |
///
/// ## 迁移
///
/// 旧版本把成绩存在 `hiscore.m2k`（Shift-JIS）。
/// 本版本启动时若发现 `scores.json` 不存在而 `hiscore.m2k` 存在，
/// 则自动读取并转存为 `scores.json`（**不删除旧文件**，便于回退）。
///
/// ## 导出降级
///
/// 导出 `.m2k` 时，若某条记录的名字**无法用 Shift-JIS 编码**，
/// 则该名字降级为 `Yiki`（见 `L10n` 相关约定），
/// 成绩数值、难度、排名结构**完全保留**。
public enum ScoreStore {

    // MARK: - 错误

    /// 存档错误。
    public enum StoreError: Error, CustomStringConvertible {
        case encodingFailed

        public var description: String {
            switch self {
            case .encodingFailed: return "成绩存档编码失败"
            }
        }
    }

    // MARK: - 落盘

    /// 成绩文件所在的目录（`~/Library/Application Support/Mine2000/`）。
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base.appendingPathComponent("Mine2000", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// UTF-8 成绩档（应用内使用）。
    public static var scoresURL: URL {
        directory.appendingPathComponent("scores.json")
    }

    /// 旧版 Shift-JIS 成绩档（仅用于一次性迁移，迁移后不删除）。
    public static var legacyM2KURL: URL {
        directory.appendingPathComponent("hiscore.m2k")
    }

    // MARK: - JSON 表示

    /// 单条记录的 JSON 表示。
    private struct EntryJSON: Codable {
        let name: String
        let score: Int
    }

    /// 整份成绩表的 JSON 表示。
    private struct TableJSON: Codable {
        /// 键为难度序号（0…4），值为该难度的记录数组。
        let difficulties: [String: [EntryJSON]]
    }

    // MARK: - 读写

    /// 把成绩表编码为 UTF-8 JSON。
    public static func encode(_ table: HighScoreTable) throws -> Data {
        var dict: [String: [EntryJSON]] = [:]
        for difficulty in Difficulty.allCases {
            dict[String(difficulty.rawValue)] = table.scores(for: difficulty).map {
                EntryJSON(name: $0.name, score: $0.score)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(TableJSON(difficulties: dict))
    }

    /// 从 UTF-8 JSON 还原成绩表。
    public static func decode(_ data: Data) throws -> HighScoreTable {
        let json = try JSONDecoder().decode(TableJSON.self, from: data)
        var table = HighScoreTable()
        for difficulty in Difficulty.allCases {
            guard let entries = json.difficulties[String(difficulty.rawValue)] else { continue }
            var list: [HighScoreEntry] = []
            for entry in entries {
                list.append(HighScoreEntry(name: entry.name, score: entry.score))
            }
            // 保持 5 条上限（原版结构：每难度 5 名）
            if list.count > HighScoreTable.entriesPerDifficulty {
                list = Array(list.prefix(HighScoreTable.entriesPerDifficulty))
            }
            table.replaceScores(list, for: difficulty)
        }
        return table
    }

    /// 读取应用内成绩档；若不存在则尝试从旧版 `.m2k` 迁移。
    ///
    /// - Returns: 成绩表；无任何可用数据时返回空表。
    public static func load() -> HighScoreTable {
        // 1) 优先读 UTF-8 成绩档
        if let data = try? Data(contentsOf: scoresURL), let table = try? decode(data) {
            return table
        }
        // 2) 迁移：读旧版 Shift-JIS `.m2k`
        if let legacyData = try? Data(contentsOf: legacyM2KURL),
           let legacy = try? M2KCodec.decode([UInt8](legacyData)) {
            // 转存为 UTF-8（失败不致命，只是没迁移成功）
            try? save(legacy)
            return legacy
        }
        // 3) 都没有 → 空表
        return HighScoreTable()
    }

    /// 保存成绩表到应用内 UTF-8 成绩档。
    public static func save(_ table: HighScoreTable) throws {
        let data = try encode(table)
        try data.write(to: scoresURL, options: .atomic)
    }

    // MARK: - 导出降级

    /// 导出为原版 `.m2k` 字节流，**中文名自动降级**。
    ///
    /// - Returns: 字节流 + 是否发生过降级（用于弹提示）。
    public static func exportM2K(_ table: HighScoreTable) throws -> (bytes: [UInt8], downgraded: Bool) {
        var downgraded = false
        var sanitized = HighScoreTable()
        for difficulty in Difficulty.allCases {
            var list: [HighScoreEntry] = []
            for entry in table.scores(for: difficulty) {
                if M2KCodec.canEncode(name: entry.name) {
                    list.append(entry)
                } else {
                    // ⚠️ 中文名无法用 Shift-JIS 表示 → 降级为 Yiki
                    downgraded = true
                    list.append(HighScoreEntry(name: M2KCodec.fallbackName, score: entry.score))
                }
            }
            sanitized.replaceScores(list, for: difficulty)
        }
        return (try M2KCodec.encode(sanitized), downgraded)
    }
}
