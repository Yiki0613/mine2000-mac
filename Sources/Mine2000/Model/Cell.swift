import Foundation

/// 单个格子的状态。
///
/// 原版每个格子在棋盘数组里占 16 字节（stride 3 个 dword），
/// 反汇编 `0x401E1B: lea eax,[edx+edx*2]; shl eax,4` 可见每格 3×4 字节。
public struct Cell: Equatable, Sendable {
    /// 格子是否被翻开。
    public var isRevealed: Bool
    /// 格子是否被插了旗。
    public var isFlagged: Bool
    /// 格子是否含雷。
    public var containsMine: Bool
    /// 周围 8 邻域内的雷数（仅在翻开且非雷格时有意义）。
    public var adjacentMineCount: Int

    public init(
        isRevealed: Bool = false,
        isFlagged: Bool = false,
        containsMine: Bool = false,
        adjacentMineCount: Int = 0
    ) {
        self.isRevealed = isRevealed
        self.isFlagged = isFlagged
        self.containsMine = containsMine
        self.adjacentMineCount = adjacentMineCount
    }

    /// 是否为「已翻开且非雷且周围无雷」的空区（flood fill 的起点）。
    public var isEmptyRegion: Bool {
        isRevealed && !containsMine && adjacentMineCount == 0
    }
}
