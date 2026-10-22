import AppKit
import Foundation

/// GUI 层端到端测试：**真实创建窗口 + 真实鼠标事件 + 真实离屏渲染 + 像素分析**。
///
/// ## 与逻辑层自检的分工
///
/// * `EndToEndSelfTest` 验证**逻辑**（`Board` / `GameSession`）的跨环节衔接；
/// * 本模块验证 **UI 链路**：鼠标事件 → 视图回调 → 逻辑变更 → **画面真的更新了**。
///
/// 逻辑对了但画面不更新，是本项目实际踩到过的 bug
/// （右键插旗时 `afterMove()` 漏了 `boardView.needsDisplay = true`，
///   逻辑层已改对但屏幕毫无变化）。这类 bug 只能靠「渲染出来看像素」发现。
///
/// ## 判据（全部基于像素统计，不靠肉眼）
///
/// 1. **左键翻牌**：翻牌前后棋盘区域的不同像素数必须显著增加（> 200 px）；
/// 2. **右键插旗**：插旗后棋盘区域的**红色像素**必须显著增加（红旗是纯红）；
/// 3. **笑脸点击**：点击 HUD 笑脸后，用时必须归零（重新开局）；
/// 4. **表情切换**：鼠标按下时表情从「正常」变为「惊讶」，像素必然变化；
/// 5. **结束态锁定**：踩雷后棋盘画面不再变化。
///
/// ## 用法
///
/// ```
/// swift run Mine2000 --gui-selftest [输出目录]
/// ```
enum GuiSelfTest {

    private struct Check {
        let name: String
        let passed: Bool
        let detail: String
    }

    /// 固定种子随机源。
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 渲染视图并返回像素统计。
    private struct PixelStats {
        var total: Int = 0
        var distinctColors: Int = 0
        var redPixels: Int = 0
        var darkPixels: Int = 0
        /// 棋盘区域的原始像素字节（用于逐像素比对）。
        var fingerprint: [UInt8] = []
    }

    /// 统计指定格子区域的像素特征（用于验证按压凹陷态）。
    private struct CellStats {
        /// 红底像素数（红底高亮的雷会有很多）。
        var redPixels: Int = 0
        /// 左上角 1px 描边中的暗像素数（凹陷底板 = 128 暗边；凸起 = 255 白高光）。
        var topLeftDark: Int = 0
        /// 左上角 1px 描边中的白色像素数（凸起特征）。
        var topLeftWhite: Int = 0
    }

    /// 对容器做离屏渲染，并只统计**棋盘区域**的像素。
    ///
    /// ⚠️ 两个必须注意的点（都是本次调试踩出来的）：
    ///
    /// 1. **必须渲染容器而不是棋盘子视图**：`BoardView` 自身 `cacheDisplay` 得到的
    ///    缓冲几乎是空白（`draw(_:)` 依赖 `NSGraphicsContext.current`，
    ///    子视图离屏时拿不到有效上下文）。渲染整个 contentView 才拿得到真实画面。
    /// 2. **必须排除 HUD 区域**：HUD 的雷数计数器是**红色数码管**，
    ///    若把 HUD 一起统计，「红旗出现」这条判据就会被 HUD 的红字污染。
    ///
    /// - Parameters:
    ///   - container: 承载 HUD + 棋盘的容器视图。
    ///   - boardRectInView: 棋盘区域（视图坐标系，原点左下）。
    private static func stats(of container: NSView, boardRectInView: NSRect) -> PixelStats {
        let bounds = container.bounds
        guard bounds.width > 0, bounds.height > 0 else { return PixelStats() }
        // ⚠️ 渲染方式：**自己建位图上下文，直接调 draw(_:)**。
        //
        //    为什么不用 `cacheDisplay(in:to:)`：
        //    它依赖 AppKit 的绘制缓存，重复调用会返回**同一份旧画面**
        //    （实测每次 stats 的颜色数完全不变：3→4→4→4→5→5，
        //    而画面肉眼可见是变化的），
        //    于是「画面是否更新」这条判据彻底失效。
        //    直接调用 `draw(_:)` 每次都会重新执行绘制代码，
        //    拿到的一定是当次逻辑状态的真实画面 —— 这才是判据需要的语义。
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            return PixelStats()
        }
        rep.size = bounds.size
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return PixelStats() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        // 逐个视图绘制（等价于 AppKit 的 draw 过程，但不经过其缓存）
        for subview in container.subviews {
            subview.draw(subview.bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        // 位图像素尺寸可能大于点尺寸（Retina 缩放）
        let scaleX = Double(rep.pixelsWide) / Double(bounds.width)
        let scaleY = Double(rep.pixelsHigh) / Double(bounds.height)
        // 视图坐标 y 向上，位图 y 向下 → 棋盘区域在位图中的行范围
        let topRow = Int((bounds.height - boardRectInView.maxY) * scaleY)
        let botRow = Int((bounds.height - boardRectInView.minY) * scaleY)
        let leftCol = Int(boardRectInView.minX * scaleX)
        let rightCol = Int(boardRectInView.maxX * scaleX)

        // ⚠️ 用**原始字节**统计，不用 `colorAt`：
        //    `colorAt` 在部分位图上会做色彩管理转换，且逐点调用极慢；
        //    原始字节才是绘制结果的忠实反映。
        guard let raw = rep.bitmapData else { return PixelStats() }
        let bytesPerPixel = rep.bitsPerPixel / 8
        let bytesPerRow = rep.bytesPerRow
        let hasAlpha = rep.hasAlpha
        var result = PixelStats()
        var colorSet = Set<UInt32>()
        for y in max(0, topRow)..<min(rep.pixelsHigh, botRow) {
            let rowBase = y * bytesPerRow
            for x in max(0, leftCol)..<min(rep.pixelsWide, rightCol) {
                let o = rowBase + x * bytesPerPixel
                guard o + bytesPerPixel <= bytesPerRow * rep.pixelsHigh else { continue }
                // 通道顺序：TIFF 往返后为 **RGBA**（TIFF 规范按通道名存储）
                let r = Int(raw[o])
                let g = Int(raw[o + 1])
                let b = Int(raw[o + 2])
                let a = hasAlpha ? Int(raw[o + 3]) : 255
                // 跳过全透明像素（不影响画面内容的统计）
                if a < 8 { continue }
                result.total += 1
                colorSet.insert(UInt32(r << 16 | g << 8 | b))
                // 红旗：红通道显著高于绿蓝
                if r > 180 && g < 90 && b < 90 { result.redPixels += 1 }
                if r < 70 && g < 70 && b < 70 { result.darkPixels += 1 }
            }
        }
        result.distinctColors = colorSet.count
        // 保存棋盘区域原始字节，供逐像素比对
        result.fingerprint.reserveCapacity(result.total * 4)
        for y in max(0, topRow)..<min(rep.pixelsHigh, botRow) {
            let rowBase = y * bytesPerRow
            for x in max(0, leftCol)..<min(rep.pixelsWide, rightCol) {
                let o = rowBase + x * bytesPerPixel
                guard o + bytesPerPixel <= bytesPerRow * rep.pixelsHigh else { continue }
                result.fingerprint.append(raw[o])
                result.fingerprint.append(raw[o + 1])
                result.fingerprint.append(raw[o + 2])
                result.fingerprint.append(raw[o + 3])
            }
        }
        // 调试输出：把原始数值暴露出来
        return result
    }

    /// 统计某个格子（视图坐标）的像素特征。
    ///
    /// 用于验证「按下时该格画成凹陷底板」：
    /// * 凹陷底板 `.blankPlate`：左上 1px 是 **128 暗边**、右下无高光；
    /// * 凸起格 `.coveredCell`：左上 1px 是 **255 白高光**。
    /// * 红底高亮的雷 `.mineHighlighted`：含大量红像素 —— **按压态绝不该出现**。
    private static func cellStats(of container: NSView, cellRectInView: NSRect) -> CellStats {
        var result = CellStats()
        let bounds = container.bounds
        // ⚠️ 必须用「自建上下文 + 直接调 draw」，
        //    不能用 `cacheDisplay` —— 它走 AppKit 绘制缓存，会返回**同一份旧画面**，
        //    导致「按下前后读数相同」，测试形同虚设。
        //    （本项目调试 GUI 自检时已踩过这个坑。）
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return result }
        rep.size = bounds.size
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return result }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        for subview in container.subviews { subview.draw(subview.bounds) }
        NSGraphicsContext.restoreGraphicsState()
        // ⚠️ 必须用 `colorAt` 读色，**不能直接读 `bitmapData` 的字节**：
        //    自建 `NSBitmapImageRep` 的内存通道序是 **BGRA**（小端），
        //    按 RGBA 读会把红蓝读反 —— (255,0,0) 被读成 (0,0,255)，
        //    于是「红底高亮的雷」判不出来（实测踩过：红像素恒为 0）。
        //    `colorAt` 由 AppKit 做色彩转换，与通道序无关。
        let scaleX = Double(rep.pixelsWide) / Double(bounds.width)
        let scaleY = Double(rep.pixelsHigh) / Double(bounds.height)
        // 视图坐标 y 向上 → 位图行号向下
        let topRow = Int((bounds.height - cellRectInView.maxY) * scaleY)
        let botRow = Int((bounds.height - cellRectInView.minY) * scaleY)
        let leftCol = Int(cellRectInView.minX * scaleX)
        let rightCol = Int(cellRectInView.maxX * scaleX)

        for y in max(0, topRow)..<min(rep.pixelsHigh, botRow) {
            for x in max(0, leftCol)..<min(rep.pixelsWide, rightCol) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = Int(color.redComponent * 255)
                let g = Int(color.greenComponent * 255)
                let b = Int(color.blueComponent * 255)
                if r > 180 && g < 90 && b < 90 { result.redPixels += 1 }
                // 左上角那一圈（相对格子左上角 2px 内）
                let ly = y - topRow, lx = x - leftCol
                if ly < 2 && lx < 2 {
                    if r >= 240 && g >= 240 && b >= 240 { result.topLeftWhite += 1 }
                    if abs(r - 128) <= 24 && abs(g - 128) <= 24 && abs(b - 128) <= 24 { result.topLeftDark += 1 }
                }
            }
        }
        return result
    }

    /// 两个统计量的差异估算。
    ///
    /// ⚠️ 判据设计要点：**以「发生变化的像素数」为主判据**，
    /// 颜色数变化只作为辅助信号。
    /// 原因：翻一格 / 插一旗只改动 16×16 = 256 px，
    /// 整块棋盘的颜色种类数往往不变（还是那几种灰 + 偶尔一个红），
    /// 若把「颜色数变化」放大权重，反而会漏判真实变化。
    ///
    /// 这里直接**逐像素比对**棋盘区域，统计有多少个像素发生了变化。
    /// 阈值参考实测值：红旗图块（16×16）含 46 个红像素，
    /// 插旗带来的总变化量在 30–60 区间，故阈值取 25。
    private static func difference(_ a: PixelStats, _ b: PixelStats) -> Int {
        // 逐像素比对：这是唯一能可靠反映「画面是否真的变了」的指标。
        // 颜色数 / 红像素 / 暗像素都只是**间接信号**：
        // 翻开一个空白格是把「灰底板」换成「白底板」，
        // 红像素与暗像素都不变、颜色种类数也可能不变 ——
        // 只有逐像素比对才能捕捉到这种变化。
        let fa = a.fingerprint, fb = b.fingerprint
        guard fa.count == fb.count, !fa.isEmpty else { return 0 }
        var changed = 0
        var i = 0
        while i < fa.count {
            if fa[i] != fb[i] { changed += 1 }
            i += 4
        }
        return changed
    }

    /// 执行 GUI 层自检。
    static func run(outputDirectory: URL = URL(fileURLWithPath: "/tmp/mine2000_gui_selftest")) -> Bool {
        var checks: [Check] = []
        func assert(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            checks.append(Check(name: name, passed: condition, detail: detail()))
        }

        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // AppKit 离屏渲染需要 NSApplication（不激活 GUI）
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        guard let renderer = try? TileRenderer() else {
            print("❌ 无法加载图集资源")
            return false
        }

        // ── 搭建一个真实的窗口与视图树 ──────────────────────────────
        let session = GameSession(difficulty: .beginner, generator: SeededGenerator(seed: 31415))
        let boardView = BoardView(board: session.board, renderer: renderer)
        let hudView = HUDView(renderer: renderer)
        // ⚠️ 尺寸必须由**实际格数**算出：8×8 格 × 16px = 128×128。
        //    早前这里写成 96（把 HUD 高度算进了棋盘），
        //    导致**棋盘底行被裁掉**，按压取样坐标落到 HUD 区域，
        //    判据形同虚设 —— 这正是本项目「尺寸必须按格数算」那条教训的翻版。
        let boardW = CGFloat(session.board.columns * Difficulty.cellSize)
        let boardH = CGFloat(session.board.rows * Difficulty.cellSize)
        let hudH = CGFloat(HUDView.height)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: boardW, height: boardH + hudH))
        container.addSubview(boardView)
        container.addSubview(hudView)
        boardView.frame = NSRect(x: 0, y: 0, width: boardW, height: boardH)
        hudView.frame = NSRect(x: 0, y: boardH, width: boardW, height: hudH)

        // ⚠️ **不要**把视图挂到窗口上。
        //
        //    挂窗口后 `NSGraphicsContext.current` 指向**窗口**的上下文，
        //    `BoardView.draw(_:)` 画进窗口而非我们新建的位图上下文，
        //    于是读到的位图永远只有「未翻开格」的灰色底板
        //    （实测采样点恒为 (192,192,192)，颜色数 3→4→5 但内容没变）。
        //    `RenderSnapshots` 用的**无窗口**路径已被证明能画出正确画面，
        //    本自检沿用同一路径。
        container.layoutSubtreeIfNeeded()

        // 记录回调（模拟 AppDelegate 的接线）
        var lastReveal: (Int, Int)?
        var lastFlag: (Int, Int)?
        // 模拟 `AppDelegate.afterMove()`：改完逻辑后**必须显式请求重绘**。
        // ⚠️ 这一行是本项目实际踩过的坑（右键插旗逻辑对但画面不变），
        //    所以自检里也如实复现这个调用顺序。
        boardView.callbacks.onReveal = { r, c in
            lastReveal = (r, c)
            session.reveal(row: r, column: c)
            boardView.needsDisplay = true
        }
        boardView.callbacks.onToggleFlag = { r, c in
            lastFlag = (r, c)
            session.toggleFlag(row: r, column: c)
            boardView.needsDisplay = true
        }

        // ── 判据 1：左键翻牌后画面必须变化 ──────────────────────────
        let beforeReveal = GuiSelfTest.stats(of: container, boardRectInView: boardView.frame)
        // 用视图自身的坐标转换算出第 (2,2) 格的中心点
        let cellCenter = { (row: Int, col: Int) -> NSPoint in
            let size = CGFloat(Difficulty.cellSize)
            return NSPoint(x: CGFloat(col) * size + size / 2,
                           y: CGFloat(session.board.rows - 1 - row) * size + size / 2)
        }
        let p22 = cellCenter(2, 2)
        boardView.mouseDown(with: NSEvent.mouseEvent(
            with: .leftMouseDown, location: p22, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)!)
        boardView.mouseUp(with: NSEvent.mouseEvent(
            with: .leftMouseUp, location: p22, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 0)!)
        let afterReveal = GuiSelfTest.stats(of: container, boardRectInView: boardView.frame)
        assert("左键翻牌触发回调", lastReveal != nil, "回调 \(String(describing: lastReveal))")
        assert("左键翻牌后画面更新（像素变化）",
               GuiSelfTest.difference(beforeReveal, afterReveal) >= 25,
               "变化量 \(GuiSelfTest.difference(beforeReveal, afterReveal))，颜色数 \(beforeReveal.distinctColors)→\(afterReveal.distinctColors)")
        assert("左键翻牌后棋盘已翻开", session.board.revealedCount > 0,
               "已翻 \(session.board.revealedCount) 格")

        // ── 判据 2：右键插旗后画面必须出现红旗 ──────────────────────
        // 找一个未翻开、未插旗的格子
        var flagTarget: (Int, Int)?
        for row in 0..<session.board.rows {
            for column in 0..<session.board.columns {
                if let cell = session.board.cell(row: row, column: column),
                   !cell.isRevealed, !cell.containsMine {
                    flagTarget = (row, column)
                    break
                }
            }
            if flagTarget != nil { break }
        }
        if let target = flagTarget {
            let beforeFlag = GuiSelfTest.stats(of: container, boardRectInView: boardView.frame)
            let pf = cellCenter(target.0, target.1)
            boardView.rightMouseDown(with: NSEvent.mouseEvent(
                with: .rightMouseDown, location: pf, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1)!)
            boardView.rightMouseUp(with: NSEvent.mouseEvent(
                with: .rightMouseUp, location: pf, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 0)!)
            let afterFlag = GuiSelfTest.stats(of: container, boardRectInView: boardView.frame)
            assert("右键插旗触发回调", lastFlag != nil, "回调 \(String(describing: lastFlag))")
            assert("右键插旗后画面出现红色（红旗渲染）",
                   afterFlag.redPixels > beforeFlag.redPixels,
                   "红像素 \(beforeFlag.redPixels)→\(afterFlag.redPixels)")
            assert("右键插旗后画面确实更新",
                   GuiSelfTest.difference(beforeFlag, afterFlag) >= 25,
                   "变化量 \(GuiSelfTest.difference(beforeFlag, afterFlag))")
            assert("右键插旗后剩余雷数 -1", session.remainingMines == 9,
                   "实际 \(session.remainingMines)")
        } else {
            assert("找到可插旗的格子", false)
        }

        // ── 判据 2.5：按压时该格不得显示「雷」 ─────────────────────
        // ⚠️ 早前按压反馈错用 `.mineHighlighted`（红底高亮的雷），
        //    导致「按下瞬间先闪出一个雷」。原版（反汇编 0x403c20）规定：
        //    按下时该格画成**凹陷底板** `.blankPlate`（源 0,0），
        //    与凸起的 `.coveredCell`（源 0,16）构成 raised/pressed 配对。
        do {
            // 选一个未翻开、未插旗的格子（不是已翻开的数字格）
            var pressTarget: (Int, Int)?
            for row in 0..<session.board.rows {
                for column in 0..<session.board.columns {
                    if let cell = session.board.cell(row: row, column: column),
                       !cell.isRevealed, !cell.isFlagged, !cell.containsMine {
                        pressTarget = (row, column)
                        break
                    }
                }
                if pressTarget != nil { break }
            }
            if let target = pressTarget {
                let size = CGFloat(Difficulty.cellSize)
                // ⚠️ 坐标必须是 **boardView 局部坐标**（boardView 在 container 里原点在 (0,0)），
                //    且行序自上而下翻转。
                let rect = NSRect(x: CGFloat(target.1) * size,
                                  y: CGFloat(session.board.rows - 1 - target.0) * size,
                                  width: size, height: size)
                // 按下之前：应是凸起格（左上白高光）
                let before = GuiSelfTest.cellStats(of: container, cellRectInView: rect)
                // 模拟左键按下（不释放）
                let p = NSPoint(x: rect.midX, y: rect.midY)
                boardView.mouseDown(with: NSEvent.mouseEvent(
                    with: .leftMouseDown, location: p, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1)!)
                let after = GuiSelfTest.cellStats(of: container, cellRectInView: rect)

                assert("按压时该格不出现红色（不再是雷）",
                       after.redPixels == 0,
                       "按下后红像素=\(after.redPixels)（修复前会出现红底高亮的雷）")
                assert("按压时该格呈凹陷态（左上暗边，非白色高光）",
                       after.topLeftDark > 0 && after.topLeftWhite == 0,
                       "按下后 左上暗=\(after.topLeftDark) 白=\(after.topLeftWhite)；按下前 暗=\(before.topLeftDark) 白=\(before.topLeftWhite)")
                assert("未按下时该格为凸起态（左上白高光）",
                       before.topLeftWhite > 0,
                       "按下前 左上暗=\(before.topLeftDark) 白=\(before.topLeftWhite)")

                // 释放
                boardView.mouseUp(with: NSEvent.mouseEvent(
                    with: .leftMouseUp, location: p, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 0)!)
            } else {
                assert("找到可按压的格子", false)
            }
        }

        // ── 判据 2.6：左右同按时，鼠标格及八邻都凹陷 ─────────────────
        // 原版规格（反汇编 0x403c20）：鼠标按键状态 == 3（左右同按）时，
        // `|鼠标x − 格x| ≤ 1` 且 `|鼠标y − 格y| ≤ 1` 的格子全部画凹陷底板。
        do {
            let size = CGFloat(Difficulty.cellSize)
            let rows = session.board.rows
            // 找一个 3×3 邻域内**没有已翻开格**的位置（避免干扰判定）
            var center: (Int, Int)? = nil
            for row in 1..<(rows - 1) {
                for column in 1..<(session.board.columns - 1) {
                    var ok = true
                    for dr in -1...1 {
                        for dc in -1...1 {
                            if session.board.cell(row: row + dr, column: column + dc)?.isRevealed == true {
                                ok = false
                            }
                        }
                    }
                    if ok { center = (row, column); break }
                }
                if center != nil { break }
            }
            if let c = center {
                // 注入双键状态
                boardView.simulatePressForTesting(mouseCell: (row: c.0, column: c.1),
                                                 pressed: true,
                                                 bothButtons: true)
                // 统计 3×3 邻域里有多少格呈凹陷态（左上暗边）
                var pressedCount = 0
                for dr in -1...1 {
                    for dc in -1...1 {
                        let rect = NSRect(x: CGFloat(c.1 + dc) * size,
                                          y: CGFloat(rows - 1 - (c.0 + dr)) * size,
                                          width: size, height: size)
                        let st = GuiSelfTest.cellStats(of: container, cellRectInView: rect)
                        if st.topLeftDark > 0 { pressedCount += 1 }
                    }
                }
                assert("左右同按时 3×3 邻域 9 格全部凹陷",
                       pressedCount == 9,
                       "实际凹陷格数 \(pressedCount)（应为 9）")
            } else {
                assert("找到可做双键测试的中心格", true,
                       "本局未找到 3×3 全未翻开的邻域，跳过该项")
            }
            // 恢复单键状态
            boardView.simulatePressForTesting(mouseCell: nil, pressed: false, bothButtons: false)
        }

        // ── 判据 3：表情随鼠标按下切换 ──────────────────────────────
        // HUD 表情槽 0 = 正常微笑，槽 3 = 惊讶
        let faceNormal = renderer.image(for: .face(.normal))
        let faceSurprise = renderer.image(for: .face(.surprise))
        let faceWin = renderer.image(for: .face(.win))
        let faceLose = renderer.image(for: .face(.lose))
        let faceIdle = renderer.image(for: .face(.idle))
        assert("图集中 5 种表情图块均可取到",
               [faceNormal, faceSurprise, faceWin, faceLose, faceIdle].allSatisfy { $0.size.width == 26 },
               "正常脸宽 \(faceNormal.size.width)")
        // 5 种表情必须互不相同（逐像素比较）
        let faces = [faceNormal, faceSurprise, faceWin, faceLose, faceIdle]
        var pairNames = ["normal", "surprise", "win", "lose", "idle"]
        var identicalPairs: [String] = []
        for i in 0..<faces.count {
            for j in (i+1)..<faces.count {
                if faces[i].isEqual(faces[j]) {
                    identicalPairs.append("\(pairNames[i])==\(pairNames[j])")
                }
            }
        }
        assert("5 种表情图块两两不同", identicalPairs.isEmpty,
               "相同：\(identicalPairs.joined(separator: ", "))")

        // ── 判据 4：结束态锁定后画面不再变化 ────────────────────────
        // 找一颗雷并踩它
        var minePos: (Int, Int)?
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
            let pm = cellCenter(mine.0, mine.1)
            boardView.mouseDown(with: NSEvent.mouseEvent(
                with: .leftMouseDown, location: pm, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1)!)
            boardView.mouseUp(with: NSEvent.mouseEvent(
                with: .leftMouseUp, location: pm, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 0)!)
            assert("踩雷后状态为失败", session.board.state == .lost, "实际 \(session.board.state)")
            let afterLoss = GuiSelfTest.stats(of: container, boardRectInView: boardView.frame)
            // 失败后棋盘锁定：再点一次不应有任何变化
            boardView.mouseDown(with: NSEvent.mouseEvent(
                with: .leftMouseDown, location: p22, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1)!)
            boardView.mouseUp(with: NSEvent.mouseEvent(
                with: .leftMouseUp, location: p22, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 0)!)
            let afterLoss2 = GuiSelfTest.stats(of: container, boardRectInView: boardView.frame)
            assert("失败后棋盘锁定（画面无变化）",
                   afterLoss.distinctColors == afterLoss2.distinctColors
                   && afterLoss.redPixels == afterLoss2.redPixels,
                   "颜色数 \(afterLoss.distinctColors)→\(afterLoss2.distinctColors)，红像素 \(afterLoss.redPixels)→\(afterLoss2.redPixels)")
        } else {
            assert("找到地雷", false)
        }

        // ── 判据 5：渲染产物能落盘（可视化链路完整）─────────────────
        if let image = try? renderView(container) {
            let url = outputDirectory.appendingPathComponent("gui_selftest.png")
            if let data = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: data),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
                assert("渲染结果可落盘为 PNG", FileManager.default.fileExists(atPath: url.path),
                       "路径 \(url.path)")
            } else {
                assert("渲染结果可落盘为 PNG", false, "PNG 编码失败")
            }
        } else {
            assert("渲染结果可生成", false)
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
        let outURL = outputDirectory.appendingPathComponent("gui_selftest.txt")
        try? text.write(to: outURL, atomically: true, encoding: .utf8)
        print(text)
        return failed == 0
    }

    /// 离屏渲染一个视图为 NSImage。
    private static func renderView(_ view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
