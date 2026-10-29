import AppKit

/// 棋盘绘制视图 + 鼠标交互。
///
/// 只负责按 `Board` 的状态把图块贴到正确的位置，并把鼠标事件转成
/// 逻辑层的调用，不含任何游戏规则。
public final class BoardView: NSView {

    /// 图集渲染器。
    private let renderer: TileRenderer

    /// 被观察的棋盘。
    private var board: Board

    /// 缩放倍数（1 = 原始 16px 格子）。
    public var scale: Int = 1 {
        didSet { needsDisplay = true }
    }

    /// 当前按下的格子（左键按住时高亮）。
    private var pressedCell: (row: Int, column: Int)?

    /// 右键按下的格子（用于区分「右键」与「左右同按」）。
    private var rightPressedCell: (row: Int, column: Int)?

    /// 是否检测到左右键同时按下（= 扫雷）。
    private var bothButtonsPressed = false

    /// 鼠标当前所在的格子（不在棋盘内时为 nil）。
    ///
    /// 原版用 `+0x88` / `+0x8C` 两个字段记录鼠标格坐标，
    /// 按压反馈的判定**完全依赖它**（见 `shouldRenderPressed`）。
    internal private(set) var mouseCell: (row: Int, column: Int)?

    /// 鼠标是否当前位于棋盘范围内。
    private var mouseOnBoard = true

    /// 鼠标按键是否处于按下状态（左键或右键）。
    ///
    /// 只用于「惊讶」表情与悬停重绘判定，**不用于凹陷反馈** ——
    /// 凹陷只看 `leftButtonDown`（原版的 `+0x90` 只有左键会写）。
    private var mousePressed = false

    /// 左键是否按着。
    ///
    /// 单独一个状态，是因为**凹陷反馈只由左键触发**：
    /// 原版 `+0x90` 只取 2（左键单按）和 3（左右同按），
    /// 右键单按根本不写这个字段，所以右键按下时格子不凹陷，旗子照常显示。
    private var leftButtonDown = false

    /// 交互回调。
    public struct Callbacks {
        /// 左键翻开。
        public var onReveal: ((Int, Int) -> Void)?
        /// 右键插旗。
        public var onToggleFlag: ((Int, Int) -> Void)?
        /// 中键 / 左右同按 → 扫雷。
        public var onChord: ((Int, Int) -> Void)?
        /// 鼠标按下 / 离开棋盘状态变化（用于切换「惊讶」表情）。
        public var onMouseStateChanged: ((Bool, Bool) -> Void)?

        public init(
            onReveal: ((Int, Int) -> Void)? = nil,
            onToggleFlag: ((Int, Int) -> Void)? = nil,
            onChord: ((Int, Int) -> Void)? = nil,
            onMouseStateChanged: ((Bool, Bool) -> Void)? = nil
        ) {
            self.onReveal = onReveal
            self.onToggleFlag = onToggleFlag
            self.onChord = onChord
            self.onMouseStateChanged = onMouseStateChanged
        }
    }

    /// 交互回调集合。
    public var callbacks = Callbacks()

    /// 初始化。
    public init(board: Board, renderer: TileRenderer) {
        self.board = board
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 暂不支持")
    }

    /// 替换棋盘（例如切换难度）。
    public func setBoard(_ board: Board) {
        self.board = board
        pressedCell = nil
        rightPressedCell = nil
        bothButtonsPressed = false
        needsDisplay = true
    }

    /// 当前棋盘。
    public var currentBoard: Board { board }

    /// 视图尺寸（像素）。
    public override var intrinsicContentSize: NSSize {
        NSSize(
            width: CGFloat(board.columns * Difficulty.cellSize * scale),
            height: CGFloat(board.rows * Difficulty.cellSize * scale)
        )
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // 像素级保真：关闭插值
        context.interpolationQuality = .none

        let tileSize = CGFloat(Difficulty.cellSize * scale)
        let cells = board.allCells

        for row in 0..<board.rows {
            for column in 0..<board.columns {
                let i = row * board.columns + column
                let cell = cells[i]

                var tile = Self.tileIndex(for: cell, state: board.state)

                // 失败时：揭示全部地雷，刚踩中的那颗高亮，插错旗的画 X
                if board.state == .lost {
                    if board.isHitMine(row: row, column: column) {
                        tile = .mineHighlighted
                    } else if board.isWrongFlag(row: row, column: column) {
                        tile = .mineWithX
                    } else if cell.containsMine && !cell.isFlagged {
                        tile = .mine
                    }
                }

                // 按压反馈：把该格画成**凹陷底板**。
                //
                // ⚠️ 早前这里错用 `.mineHighlighted`（红底高亮的雷），
                //    导致「按下瞬间先闪出一个雷」—— 视觉上像踩雷了。
                //    `.mineHighlighted` 的正确用途是**失败态标记刚踩中的那颗雷**。
                //
                // 原版规格（反汇编 `0x403c20` 画棋盘函数，字节级）：
                // ```
                // 00403d79  mov eax, [ecx+0x90]    ; 鼠标按键状态
                // 00403d7f  cmp eax, 2             ; 状态 2 = 单键按下
                // 00403d84  cmp [ecx+0x88], edx    ; 鼠标 x == 该格 x
                // 00403d90  cmp [ecx+0x8c], edx    ; 鼠标 y == 该格 y
                // 00403d96  je  0x403dc9           ; → 该格画凹陷底板
                // 00403d98  cmp eax, 3             ; 状态 3 = 左右同按
                // ...  |鼠标 - 该格| <= 1 判定      ; 该格及八邻都凹陷
                // 00403dc9  push 0                  ; 源 y = 0 → 区域 A 第 0 行
                // ```
                // 源 (0, 0) 正是 `.blankPlate`（左上 128 暗边的**凹陷**底板），
                // 与 `.coveredCell`（左上白高光的凸起）构成原版的 raised/pressed 配对。
                if shouldRenderPressed(row: row, column: column) {
                    tile = .blankPlate
                }

                let image = renderer.image(for: tile)

                // NSView 坐标原点在左下角，棋盘行序自上而下，故翻转 y
                let x = CGFloat(column) * tileSize
                let y = CGFloat(board.rows - 1 - row) * tileSize

                let target = CGRect(x: x, y: y, width: tileSize, height: tileSize)
                image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        }
    }

    /// 根据格子状态选择应显示的图块。
    static func tileIndex(for cell: Cell, state: GameState) -> TileIndex {
        if cell.isFlagged {
            return .flag
        }
        if cell.isRevealed {
            if cell.containsMine {
                // 失败时把踩到的那颗雷高亮成红底
                return state == .lost ? .mineHighlighted : .mine
            }
            if cell.adjacentMineCount > 0 {
                return .digit(cell.adjacentMineCount)
            }
            // 翻开的空白格：原版用纯色底板绘制（区域 A 第 0 行第 0 列）
            return .blankPlate
        }
        return .coveredCell
    }

    /// 判定某个格子在当前鼠标状态下是否应画成**凹陷底板**。
    ///
    /// ## 原版规格（反汇编 `0x403c20`，字节级确证）
    ///
    /// | 鼠标按键状态 | 判定 | 效果 |
    /// |---|---|---|
    /// | `2`（单键按下） | 鼠标格 **x、y 都等于**该格 | 该格凹陷 |
    /// | `3`（左右同按） | `\|鼠标x − 格x\| ≤ 1` 且 `\|鼠标y − 格y\| ≤ 1` | 该格**及八邻**都凹陷 |
    /// | 其他 | — | 不凹陷 |
    ///
    /// 该替换只发生在**未翻开**格的绘制路径上（原版 `0x403d6b` 分支），
    /// 已翻开的格子不受影响。
    ///
    /// - Parameters:
    ///   - row: 格子行。
    ///   - column: 格子列。
    /// - Returns: 是否画成凹陷底板。
    internal func shouldRenderPressed(row: Int, column: Int) -> Bool {
        guard let cell = board.cell(row: row, column: column) else { return false }

        // 已翻开的格子不参与按压反馈（原版：按压分支在未翻开路径内）
        if cell.isRevealed { return false }

        // 已插旗的格子不画凹陷。
        //
        // 原版右键单按时**不写** `+0x90`（只有左键=2、左右同按=3），
        // 所以插旗后格子照常显示旗子。若这里不早退，凹陷底板会把旗子盖住 ——
        // 表现就是「右键按下去旗子反而不见了」。
        //
        // 左键按在已插旗的格子上同样不凹陷，与原版一致（`+0x90` 虽为 2，
        // 但绘制分支里旗子的优先级高于按压底板）。
        if cell.isFlagged { return false }

        guard let mouse = mouseCell else { return false }

        if bothButtonsPressed {
            // 左右同按：鼠标格及八邻（上下左右 + 对角）都凹陷
            return abs(mouse.row - row) <= 1 && abs(mouse.column - column) <= 1
        }
        // 单键按下：仅鼠标所在的那一格凹陷，且**必须是左键**
        return leftButtonDown && mouse.row == row && mouse.column == column
    }

    // MARK: - 测试支持

    /// 注入鼠标状态（**仅供单元测试**）。
    ///
    /// 按压反馈的判定依赖三个状态：鼠标所在格、鼠标是否按下、是否左右同按。
    /// 这些状态在真实交互中由 `mouseDown` / `mouseMoved` 等事件设置，
    /// 单元测试里用真实事件模拟成本高（且受窗口/坐标系影响），
    /// 故提供一个显式注入口。
    ///
    /// - Parameters:
    ///   - mouseCell: 鼠标所在格（nil = 不在棋盘上）。
    ///   - pressed: 是否有鼠标键按下（决定「惊讶」表情）。
    ///   - bothButtons: 是否左右同按。
    ///   - leftButton: 左键是否按着（决定凹陷）。省略时跟随 `pressed`，
    ///     显式传 `false` 可模拟「只按右键」——此时不凹陷、只显示旗子。
    internal func simulatePressForTesting(
        mouseCell: (row: Int, column: Int)?,
        pressed: Bool,
        bothButtons: Bool,
        leftButton: Bool? = nil
    ) {
        self.mouseCell = mouseCell
        self.mousePressed = pressed
        self.leftButtonDown = leftButton ?? pressed
        self.bothButtonsPressed = bothButtons
    }

    // MARK: - 鼠标交互

    /// 把视图坐标换算成棋盘格坐标。
    private func cell(at point: NSPoint) -> (row: Int, column: Int)? {
        let tileSize = CGFloat(Difficulty.cellSize * scale)
        guard tileSize > 0 else { return nil }
        let column = Int(point.x / tileSize)
        // NSView 坐标原点在左下角
        let row = board.rows - 1 - Int(point.y / tileSize)
        guard board.isValid(row: row, column: column) else { return nil }
        return (row, column)
    }

    /// 通知外部鼠标状态变化（用于「惊讶」表情）。
    private func notifyMouseState(pressed: Bool) {
        mousePressed = pressed
        let onBoard = mouseOnBoard
        callbacks.onMouseStateChanged?(pressed, onBoard)
    }

    public override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let target = cell(at: location) else { return }
        pressedCell = target
        mouseCell = target
        mouseOnBoard = true
        leftButtonDown = true
        // 先按右键、再按左键 → 同样构成左右同按。
        // 反向（先左后右）在 rightMouseDown 里处理，两边都要有，
        // 否则「从右侧发起」能扫雷、「从左侧发起」不能。
        if rightPressedCell != nil {
            bothButtonsPressed = true
        }
        notifyMouseState(pressed: true)
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let target = cell(at: location)
        pressedCell = nil
        leftButtonDown = false
        mouseCell = target
        needsDisplay = true
        // 右键可能还按着，别把「有键按下」误报成 false
        notifyMouseState(pressed: rightPressedCell != nil)

        guard let target else { return }

        // 左右键同按 → 扫雷
        if bothButtonsPressed {
            bothButtonsPressed = false
            rightPressedCell = nil
            callbacks.onChord?(target.row, target.column)
            return
        }

        callbacks.onReveal?(target.row, target.column)
    }

    /// 右键按下 —— **立即插旗**。
    ///
    /// 原版在 `WM_RBUTTONDOWN`（`0x404620`）里直接调标旗函数，不是等松开：
    /// ```
    /// 004046b3  cmp  dword ptr [esp+0x1c], 0x20   ; 鼠标在 HUD 区？
    /// 004046b8  jl   0x4046e7                     ; 是 → 跳过
    /// 004046ba  mov  edx, dword ptr [ebx+0x190]   ; 游戏状态
    /// 004046c2  jle  0x4046e7                     ; ≤ 0 → 跳过
    /// 004046c7  jg   0x4046e7                     ; > 2（胜/负）→ 跳过
    /// 004046cd  call 0x4018d0                     ; ★ 标旗，按下即调
    /// ```
    /// 早前把插旗放在 `rightMouseUp`，表现就是「按下去没反应、松开才出旗」。
    public override func rightMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let target = cell(at: location) else { return }
        rightPressedCell = target
        mouseCell = target
        mouseOnBoard = true

        // 左键也按着 → 左右同按 = 扫雷，此时不插旗
        // （原版 `0x40467e test dl, 1` 判左键，命中则走状态 3 的 3×3 凹陷分支）
        if pressedCell != nil {
            bothButtonsPressed = true
            notifyMouseState(pressed: true)
            needsDisplay = true
            return
        }

        notifyMouseState(pressed: true)
        callbacks.onToggleFlag?(target.row, target.column)
        // 回调链会自己重绘，但插旗也可能被模型拒绝（已翻开 / 已结束），
        // 这里再置一次，保证任何情况下画面都跟手。
        needsDisplay = true
    }

    /// 右键松开 —— 只收尾，不再插旗。
    public override func rightMouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        mouseCell = cell(at: location)
        rightPressedCell = nil
        needsDisplay = true

        if bothButtonsPressed {
            bothButtonsPressed = false
            notifyMouseState(pressed: false)
            if let target = cell(at: location) {
                callbacks.onChord?(target.row, target.column)
            }
            return
        }

        // 单右键：旗已在 rightMouseDown 插好（或取消），这里什么都不做
        notifyMouseState(pressed: pressedCell != nil)
    }

    public override func otherMouseDown(with event: NSEvent) {
        // 中键 → 扫雷
        guard event.buttonNumber == 2 else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard let target = cell(at: location) else { return }
        callbacks.onChord?(target.row, target.column)
    }

    // MARK: - 拖动

    /// 左键拖动 —— 按压凹陷跟着鼠标走。
    public override func mouseDragged(with event: NSEvent) {
        handleDrag(event)
    }

    /// 右键拖动（左右同按时，拖动事件由后按下的右键接管）。
    public override func rightMouseDragged(with event: NSEvent) {
        handleDrag(event)
    }

    /// 中键拖动。
    public override func otherMouseDragged(with event: NSEvent) {
        handleDrag(event)
    }

    /// 拖动时更新鼠标所在格。
    ///
    /// ⚠️ 这条**必须单独实现**：AppKit 在鼠标键按下后只发 `*Dragged`，
    /// **不再发 `mouseMoved`**。早前只重写了 `mouseMoved`，于是按下后拖动
    /// 完全收不到事件，`mouseCell` 钉在按下的那一格 —— 凹陷不跟随；
    /// 而 `mouseUp` 又按「松开位置」翻牌，造成画面与结果错位。
    ///
    /// 原版对应机制是 `SetCapture` / `ReleaseCapture`（`0x4084F4`/`0x4084F8`）：
    /// 按下后捕获鼠标，拖出窗口也继续收 `WM_MOUSEMOVE` 并更新 `+0x88/+0x8C`。
    private func handleDrag(_ event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let target = cell(at: location)

        let moved = target?.row != mouseCell?.row || target?.column != mouseCell?.column
        mouseCell = target
        mouseOnBoard = target != nil

        if moved {
            // 凹陷格变了 → 重绘；移出棋盘则凹陷消失
            needsDisplay = true
            notifyMouseState(pressed: mousePressed)
        }
    }

    // MARK: - 鼠标进出

    public override func mouseEntered(with event: NSEvent) {
        mouseOnBoard = true
        updateMouseCell()
        notifyMouseState(pressed: mousePressed)
    }

    public override func mouseExited(with event: NSEvent) {
        mouseOnBoard = false
        mouseCell = nil
        notifyMouseState(pressed: mousePressed)
    }

    /// 鼠标移动 —— 更新当前所在格。
    ///
    /// ⚠️ 原版在 `+0x88` / `+0x8C` 里实时记录鼠标格坐标，
    ///    按压反馈与「惊讶」表情都依赖它。
    ///    早前本实现**没有** `mouseMoved` 重写，导致：
    ///    ① 双键同按时无法判断哪些邻格该凹陷；
    ///    ② 鼠标移出再移回时状态不同步。
    public override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let target = cell(at: location)
        if target?.row != mouseCell?.row || target?.column != mouseCell?.column {
            mouseCell = target
            // 鼠标在棋盘内移动 → 凹陷格可能变化，需要重绘
            if mousePressed || bothButtonsPressed { needsDisplay = true }
        }
        mouseOnBoard = target != nil
        notifyMouseState(pressed: mousePressed)
    }

    /// 根据当前鼠标位置刷新 `mouseCell`。
    private func updateMouseCell() {
        let location = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        mouseCell = cell(at: location)
    }
}
