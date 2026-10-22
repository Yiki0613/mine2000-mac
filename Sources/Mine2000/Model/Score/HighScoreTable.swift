import Foundation

/// 一条高分记录。
///
/// ────────────────────────────────────────────────────────────────────────
/// **[已确证]** 原版计分单位为 **十分之一秒（0.1 s）**，显示为 `"%d.%d秒"`。
///
/// 证据（字节级，非转述）：
/// * `.rdata` 中 `0x408F60` 处的格式串明文为 `%d.%d秒`
///   （字节 `25 64 2e 25 64 95 62 00`，`95 62` 是 Shift-JIS 的「秒」）；
/// * 计时函数 `0x401C30`：
///   ```
///   00401c46  call     [0x40852c]        ; timeGetTime() → 毫秒
///   00401c4c  mov      edx, [esi+0xc1a4]  ; 起始时间戳
///   00401c54  sub      ecx, edx           ; 差值（毫秒）
///   00401c56  mov      eax, 0x51eb851f    ; 32 位「除以 100」魔数
///   00401c5b  mul      ecx
///   00401c5d  mov      eax, edx
///   00401c5f  shr      eax, 5             ; 合计右移 37 位
///   ```
///   `0x51EB851F * x >> 37 == x / 100`，即 **毫秒 / 100 = 十分之一秒**
///   （注意：毫秒 ÷ 100 得到的是 0.1 s 单位，**不是**百分之一秒）。
/// * 高分榜文本 `0x401F32`：
///   ```
///   00401f36  mov      ecx, 0xa
///   00401f3b  idiv     ecx                ; 商 = v/10，�� = v%10
///   00401f46  push     0x408f60           ; "%d.%d秒"
///   ```
///   即 **v/10 秒 . v%10 十分之一秒**（例：`1234 → "123.4秒"`）。
/// * 反汇编 `0x403570` 处 `cmp ecx, 0x1869f`（= 99999）为计时/成绩上限，
///   也是「无成绩」哨兵值。
///
/// **推论（推断）**：原版 HUD 数码管按「百/十/个位秒 + 十分之一秒」四格显示，
/// 该细节未在反汇编中直接确证，见 `文档/行为还原对照表.md`。
/// ────────────────────────────────────────────────────────────────────────
public struct HighScoreEntry: Equatable, Sendable {

    /// 玩家名（原版为 Shift-JIS 编码，此处用 Swift String 承载）。
    public var name: String

    /// 成绩，单位为**十分之一秒（0.1 s）**。数值**越小越好**。
    public var score: Int

    public init(name: String, score: Int) {
        self.name = name
        self.score = score
    }

    /// 是否为空记录（无成绩）。
    ///
    /// 原版默认档用 `99999`（0x1869F）作为「无成绩」哨兵值。
    public var isEmpty: Bool { score >= HighScoreEntry.noScoreSentinel }

    /// 「无成绩」哨兵值。
    public static let noScoreSentinel: Int = 99_999

    /// 成绩上界（原版计时上限）。
    public static let maxScore: Int = 99_999

    /// 把秒数转换为十分之一秒（0.1 s），并夹取到合法区间。
    public static func deciseconds(from seconds: TimeInterval) -> Int {
        let value = Int((seconds * 10).rounded())
        return min(max(value, 0), maxScore)
    }

    /// 把十分之一秒转换为秒。
    public var seconds: TimeInterval { Double(score) / 10 }

    /// 把十分之一秒转换为秒。
    public static func seconds(fromDeciseconds deciseconds: Int) -> TimeInterval {
        Double(deciseconds) / 10
    }
}

/// 5 难度 × 5 名的高分榜。
///
/// ────────────────────────────────────────────────────────────────────────
/// **[已确证]** 原版高分榜结构为 5 难度 × 5 名 = 25 条记录。
///
/// 内存结构为「每难度块 60 字节」（5 条 × 12 字节），块首 = `doc + 0x58`；
/// 落盘时展开为 `1 字节长度 + Shift-JIS 名字 + 4 字节分数`（见 `M2KCodec`）。
///
/// 记录中**没有难度字段**，难度由**记录顺序**隐含：
/// 0–4 = 初級，5–9 = 中級，10–14 = 上級，15–19 = 超上級，20–24 = マニア。
/// ────────────────────────────────────────────────────────────────────────
public struct HighScoreTable: Equatable, Sendable {

    /// 每个难度的记录数。
    public static let entriesPerDifficulty = 5

    /// 5 个难度各 5 条记录，按 `Difficulty.allCases` 顺序索引。
    public private(set) var entries: [Difficulty: [HighScoreEntry]]

    /// 创建一份全空的高分榜。
    ///
    /// 名字用原版默认名「名前なし」（Shift-JIS 8 字节），
    /// 这样编码出的字节流与原版默认档 `hiscore.dat` **完全一致**。
    public init() {
        var table: [Difficulty: [HighScoreEntry]] = [:]
        for difficulty in Difficulty.allCases {
            table[difficulty] = Array(
                repeating: HighScoreEntry(
                    name: M2KCodec.defaultName,
                    score: HighScoreEntry.noScoreSentinel
                ),
                count: Self.entriesPerDifficulty
            )
        }
        self.entries = table
    }

    /// 取得某难度的记录列表（按名次从高到低，即用时从小到大）。
    public func scores(for difficulty: Difficulty) -> [HighScoreEntry] {
        entries[difficulty] ?? []
    }

    /// 取得某难度的记录列表，**按用时升序**（第一名在前，空记录垫后）。
    ///
    /// 用于高分榜显示：原版按名次顺序展示，同用时时先达成者在前。
    public func sortedScores(for difficulty: Difficulty) -> [HighScoreEntry] {
        scores(for: difficulty).enumerated()
            .sorted { lhs, rhs in
                if lhs.element.score == rhs.element.score {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.score < rhs.element.score
            }
            .map(\.element)
    }

    /// 直接替换某难度的记录列表（供解码器使用）。
    mutating func setScores(_ list: [HighScoreEntry], for difficulty: Difficulty) {
        entries[difficulty] = list
    }

    /// 直接替换某难度的记录列表（**公开**，供 UTF-8 存档与导出降级使用）。
    public mutating func replaceScores(_ list: [HighScoreEntry], for difficulty: Difficulty) {
        entries[difficulty] = list
    }

    /// 提交一次成绩，返回是否进入榜单，以及名次（0 = 第一名）。
    ///
    /// 规则：按用时升序排名，用时相同则**先达成者在前**（已有记录优先）。
    /// 成绩必须优于当前第 5 名才会入榜。
    @discardableResult
    public mutating func submit(
        name: String,
        score: Int,
        for difficulty: Difficulty
    ) -> Int? {
        var list = scores(for: difficulty)
        // 找到插入位置
        var insertIndex = list.count
        for (i, entry) in list.enumerated() {
            if score < entry.score {
                insertIndex = i
                break
            }
        }
        // 未能进入前 5 名
        guard insertIndex < Self.entriesPerDifficulty else { return nil }

        list.insert(HighScoreEntry(name: name, score: score), at: insertIndex)
        if list.count > Self.entriesPerDifficulty {
            list.removeLast()
        }
        entries[difficulty] = list
        return insertIndex
    }
}
