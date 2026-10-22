import AppKit

/// 顶部信息条：左侧地雷计数器、中间表情按钮、右侧计时器。
///
/// ────────────────────────────────────────────────────────────────────────
/// **布局规格**
///
/// - [已确证] HUD 高度 **32 像素**（由视口实测反推：
///   中級 16×16 格 = 256px 网格 + 32px HUD = 288px，
///   与 `分析/原版截图/shot_middle.bmp` 的 260×292（含 2px 窗口边框）一致）。
/// - [已确证] 表情图块为 26×26（图集区域 C，槽位 0..4）。
/// - [已确证] 数字使用图集区域 B 的七段 LED 图块（13×23，槽位 0..9 + 空白）。
///
/// **小数点说明**
///
/// 图集区域 B 只有 0–9 与空白共 11 个槽位，**没有小数点图块**，
/// 因此「秒.十分之一秒」中的小数点是本实现**自行绘制的 2×2 红点**
/// （[推断]，非原版图块）。
/// ────────────────────────────────────────────────────────────────────────
public final class HUDView: NSView {

    /// 图集渲染器。
    private let renderer: TileRenderer

    /// 缩放倍数。
    public var scale: Int = 1 {
        didSet { needsDisplay = true }
    }

    /// 剩余地雷数。
    public var remainingMines: Int = 0 {
        didSet { needsDisplay = true }
    }

    /// 已用时（十分之一秒单位，与原版一致）。
    public var elapsedDeciseconds: Int = 0 {
        didSet { needsDisplay = true }
    }

    /// 当前表情。
    public var expression: FaceExpression = .idle {
        didSet { needsDisplay = true }
    }

    /// 表情按钮点击回调。
    public var onFaceClicked: (() -> Void)?

    /// 初始化。
    public init(renderer: TileRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 暂不支持")
    }

    /// HUD 高度（像素）。
    ///
    /// - [已确证] 32 像素（见类型注释中的视口反推）。
    public static var height: Int { 32 }

    /// 当前棋盘的列数（决定计时器位数）。
    ///
    /// - [已确证] 原版计时器**按难度变位数**（`0x403520`）：
    ///   ```
    ///   0040364E  cmp eax, 8          ; eax = 棋盘列数
    ///   00403651  jle 0x4036B3        ; ≤ 8（初级 8×8）→ 跳过前两位，只画 3 位
    ///   ```
    ///   即：**初级 3 位，其他难度 5 位**（万/千/百/十/个，单位十分之一秒）。
    ///
    ///   雷数则**永远是 3 位**（`0x403B52`–`0x403B76` 只有 3 次贴图，x = 6/19/32），
    ///   所以原版左右本来就不等宽 —— 中级以上计时器比雷数宽 26px。
    public var timerColumns: Int = 16 {
        didSet { if oldValue != timerColumns { needsDisplay = true } }
    }

    /// 计时器显示的位数：初级 3 位、其他 5 位（见 `timerColumns`）。
    public var timerDigitCount: Int { timerColumns <= 8 ? 3 : 5 }

    /// 左侧雷数计数器的左边界（像素）。
    ///
    /// - [已确证] 原版 `0x403B58` 的 `push 6` 就是第一次 LED 贴图的 xDest。
    public static var minesLeftInset: Int { 6 }

    /// 右侧计时器的右边界（像素）。
    ///
    /// - [已确证] 原版最后一位的目标 x = `16D − 19`，加槽宽 13 后右边界 = `16D − 6`，
    ///   即右边距 **6**（初級 128 − 6 = 122 也对得上）。
    public static var timerRightInset: Int { 6 }

    /// LED 数码管顶边距 HUD 顶部的距离（像素）。
    ///
    /// - [已确证] 原版 `BitBlt` 的目标 y = **4**（反汇编 `0x403520`：
    ///   每次 LED 贴图都 `push 4` 作为 yDest）。
    /// - ⚠️ **必须是整数**：早前实现用 `(height - ledH) / 2` = **4.5**（半像素），
    ///   矩形填充落在半像素边界上被抗锯齿混合，
    ///   表现为「小数点槽的红底发暗、与相邻数字槽颜色不一致」。
    public static var ledTopInset: Int { 4 }

    /// 表情图块边长（像素）。
    public static var faceSize: Int { 26 }

    /// 表情图块顶边距 HUD 顶部的距离（像素）。
    ///
    /// - [已确证] 原版表情贴图的 `BitBlt` 目标 y = **3**。
    ///   证据：`0x4039A4` 是所有表情共用的贴图尾部，里面 `push 3` 就是 yDest：
    ///   ```
    ///   004039AE  shl eax, 4        ; 客户区宽 × 16（缩放）
    ///   004039BC  sar eax, 1        ; /2 → 水平中心
    ///   004039BE  push 3            ; ★ yDest = 3
    ///   004039C0  sub eax, 0xd      ; xDest = 中心 − 13
    ///   004039C5  call [0x40800c]   ; BitBlt
    ///   ```
    ///   32 − 3 − 26 = 3，即上下各留 3px —— 正是**垂直居中**。
    ///
    /// ⚠️ 早前（v1.4）为了「整数定位」把它改成 `32 − 4 − 26 = 2`，
    ///    是**把 LED 的内缩 4 误套到表情上**：LED 的 yDest 才是 4，
    ///    表情的 yDest 是 3。两个控件各有各的内缩，不能混用。
    public static var faceTopInset: Int { 3 }

    /// 表情按钮是否处于**按下态**。
    ///
    /// ## 原版机制（反汇编 `0x40388E` / `0x40391F` / `0x403978` 三处分支一致）
    ///
    /// 每个状态分支都是同一套结构（以「未开始/游戏中」为例）：
    /// ```
    /// 0040388E  cmp dword ptr [esi + 0x90], ebx   ; 鼠标按键状态 == 1（未按下）？
    /// 00403894  jne 0x4038A4                      ; 按下了 → 走按压分支
    /// 00403896  push 0x37 / push 0                    ; 未按下 → 槽 0（凸起 normal）
    /// ...
    /// 004038A4  mov ecx, [esi + 0x88]              ; 鼠标格 x
    /// 004038AA  mov eax, 0xFFFFFFFE                ; -2 = 不在棋盘上
    /// 004038AF  cmp ecx, eax
    /// 004038B1  jne 0x4038ED                       ; 在棋盘上 → 槽 3（惊讶）
    /// 004038BB  push ... / push 0x68               ; 不在棋盘（按在 HUD 上）→ 槽 4（平脸）
    /// ```
    ///
    /// **胜利 / 失败分支同构**：按下 + 指针不在棋盘 → 也是槽 4。
    ///
    /// 也就是说：**只要在 HUD（棋盘外）按下鼠标，笑脸一律换成槽 4「平脸」**。
    /// 槽 4（图集 x=104）没有白色高光、也没有 128 阴影 —— 视觉上就是
    /// 「按钮被按进去」的凹陷效果，与槽 0 的凸起版构成 raised/pressed 配对
    /// （和棋盘格 `.coveredCell` / `.blankPlate` 是同一个设计语言）。
    ///
    /// ⚠️ 早前实现完全没有这个状态：`mouseDown` 里**立即**触发重开，
    ///    于是按下的一瞬间游戏就重置了，用户永远看不到这个凹陷反馈。
    public var isFacePressed: Bool = false {
        didSet { if oldValue != isFacePressed { needsDisplay = true } }
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(160 * scale), height: CGFloat(Self.height * scale))
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none

        let ledW = CGFloat(TileRenderer.ledTileWidth * scale)
        let ledH = CGFloat(TileRenderer.ledTileHeight * scale)
        let faceSize = CGFloat(Self.faceSize * scale)
        let height = CGFloat(Self.height * scale)

        // LED 底边（视图坐标，y 向上）= HUD 高 − 顶边内缩 − LED 高
        // ⚠️ 全程整数坐标，避免半像素抗锯齿（见 ledTopInset 注释）
        let ledBottomY = height - CGFloat(Self.ledTopInset * scale) - ledH

        // ── 左侧：地雷计数器（3 位七段，左边界 6）──
        drawLEDNumber(remainingMines, digits: 3,
                      originX: CGFloat(Self.minesLeftInset * scale), originY: ledBottomY)

        // ── 中间：表情按钮 ──
        //
        // 按下态（在 HUD 上按下鼠标）→ 槽 4「平脸」= 凹陷效果。
        // 见 `isFacePressed` 的类型注释（三条反汇编分支一致确证）。
        let faceX = (bounds.width - faceSize) / 2
        let faceImage: FaceExpression = isFacePressed ? .idle : expression
        renderer.image(for: .face(faceImage)).draw(
            in: CGRect(x: faceX, y: height - CGFloat(Self.faceTopInset * scale) - faceSize,
                       width: faceSize, height: faceSize),
            from: .zero, operation: .sourceOver, fraction: 1.0
        )

        // ── 右侧：计时器（秒.十分之一秒）──
        //
        // 布局：**3 个连续 LED 槽**（13px 步进，红底连成一整条）
        //   [秒十位][秒个位][十分之一秒]
        //
        // ## 关键依据
        //
        // 1. **原版 LED 贴图是 13px 连续步进的**（反汇编 `0x403520`：
        //    目标 x 依次 16D−71 / −58 / −45 / −32 / −19，中间无任何空隙），
        //    且**每一次贴图的都是数字图块**（源 x = 13 × 某一位的数字），
        //    **全程没有单独绘制小数点的代码** → 原版**没有小数点图形**。
        //
        // 2. **图集里也不可能有小数点位置可画**：区域 B 的 10 个数字槽，
        //    逐像素穷举后**没有任何一个像素对全部 10 个数字都是纯红底**
        //    （七段字形占满了槽）—— 所以小数点既无图块、也无处安放。
        //
        // 3. 因此**正确形态就是「一排全是数字的槽」**，与左上角雷数计数器
        //    完全同构（同样是 3 槽、39px、红底贯通）。
        //
        // ## 为什么没有小数点图形
        //
        // - [已确证] 原版 `0x403520` 的 5 次 LED 贴图**全部是数字图块**，
        //   全程**没有任何单独绘制小数点的代码** → 原版就没有小数点图形。
        // - [已确证] 图集区域 B 也**无处安放**小数点：
        //   逐像素穷举 10 个数字槽，**没有任何一个像素对全部 10 个数字都是纯红底**
        //   （七段字形占满了槽），且没有小数点图块。
        //
        // 所以正确形态就是**一排全是数字的槽** —— 与左上角雷数计数器完全同构。
        // 计时语义为「秒.十分之一秒」：第 1–2 位是秒，第 3 位是十分之一秒位。
        // 位数按难度：初级 3 位、其他 5 位（见 `timerColumns` 的类型注释）
        let digitCount = timerDigitCount
        let timerW = ledW * CGFloat(digitCount)
        let timerX = bounds.width - timerW - CGFloat(Self.timerRightInset * scale)

        // 显示值 = 十分之一秒总数，截到本难度能表示的位数。
        // ⚠️ 初级 3 位放不下 100 秒以上 → 按原版语义**回绕**（原版取的是各位数，
        //    高位直接不画）。其他难度 5 位可表示到 9999.9 秒，实际不会溢出。
        let capacity = digitCount == 3 ? 1000 : 100_000
        let shown = elapsedDeciseconds % capacity
        drawLEDNumber(shown, digits: digitCount, originX: timerX, originY: ledBottomY)
    }

    /// 绘制一组右对齐的七段数字。
    ///
    /// 数字位数不足时在左侧补空白（对应图集区域 B 的第 11 槽）。
    private func drawLEDNumber(_ value: Int, digits: Int, originX: CGFloat, originY: CGFloat) {
        let ledW = CGFloat(TileRenderer.ledTileWidth * scale)
        let ledH = CGFloat(TileRenderer.ledTileHeight * scale)

        // ⚠️ 必须按位数**钳制**：`%0*d` 不会截断超长值。
        //    早前 123.4 秒时 seconds=123 会画 3 个槽，正好压掉十分之一秒那位，
        //    表现为「123.4 秒显示成 123」（实测复现过）。
        let capacity = Int(pow(10.0, Double(digits))) - 1
        let text = String(format: "%0*d", digits, min(max(value, 0), capacity))
        let chars = Array(text)

        for (i, ch) in chars.enumerated() {
            let digit: Int? = ch.wholeNumberValue
            let image = renderer.image(for: .ledDigit(digit))
            let x = originX + CGFloat(i) * ledW
            image.draw(in: CGRect(x: x, y: originY, width: ledW, height: ledH),
                       from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }

    /// 表情按钮的命中矩形（视图坐标）。
    ///
    /// ⚠️ 必须与 `draw` 里的绘制矩形**完全一致**。
    /// 早前绘制在 y=2、命中区按 y=3 算，两者差 1px。
    private var faceRect: CGRect {
        let faceSize = CGFloat(Self.faceSize * scale)
        return CGRect(x: (bounds.width - faceSize) / 2,
                      y: bounds.height - CGFloat(Self.faceTopInset * scale) - faceSize,
                      width: faceSize, height: faceSize)
    }

    /// 鼠标按下：进入**按下态**（凹陷），但**不触发**重开。
    ///
    /// 原版是「按下凹陷 → 松开执行」的标准按钮行为；
    /// 早前实现在 `mouseDown` 里直接重开，导致按下态永远看不见。
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isFacePressed = faceRect.contains(point)
    }

    /// 鼠标拖动：拖出按钮则弹回凸起，拖回则再次凹陷。
    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isFacePressed = faceRect.contains(point)
    }

    /// 鼠标松开：在按钮内才触发重开。无论是否命中都要复位按下态。
    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inside = faceRect.contains(point)
        isFacePressed = false
        if inside {
            onFaceClicked?()
        }
    }
}
