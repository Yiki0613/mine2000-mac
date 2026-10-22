import AppKit
import Foundation
import Testing
@testable import Mine2000

/// 按压反馈回归测试。
///
/// ────────────────────────────────────────────────────────────────────
/// **背景（用户实测发现）**
///
/// 「点击某个格子时，按下去的瞬间会先显示一个**雷**」—— 视觉上像踩雷了。
///
/// 根因：按压反馈错用了 `.mineHighlighted`（**红底高亮的雷**），
/// 而该图块的正确用途是**失败态标记刚踩中的那颗雷**。
///
/// ## 原版规格（反汇编 `0x403c20` 画棋盘函数，字节级确证）
///
/// ```
/// 00403d79  mov eax, [ecx+0x90]    ; 鼠标按键状态
/// 00403d7f  cmp eax, 2             ; 状态 2 = 单键按下
/// 00403d84  cmp [ecx+0x88], edx    ; 鼠标 x == 该格 x
/// 00403d8a  jne 0x403d98
/// 00403d8c  mov edx, [esp+0x54]    ; 该格 y
/// 00403d90  cmp [ecx+0x8c], edx    ; 鼠标 y == 该格 y
/// 00403d96  je  0x403dc9           ; → 该格画**凹陷底板**
/// 00403d98  cmp eax, 3             ; 状态 3 = 左右同按
/// 00403d9b  jne 0x403dd5
/// ...  |鼠标x − 格x| ≤ 1            ; 该格及**八邻**都凹陷
/// ...  |鼠标y − 格y| ≤ 1
/// 00403dc9  push 0                  ; 源 y = 0 → 区域 A 第 0 行
/// ```
///
/// 源 (0, 0) 就是 `.blankPlate` —— 与 `.coveredCell`（源 0,16）构成
/// 原版的 **raised / pressed** 配对：
///
/// ```
/// .coveredCell（凸起）        .blankPlate（凹陷）
/// WWWWWWWWWWWWWWW.  白高光    ################  128 暗边
/// WW............##            #...............
/// ```
/// ────────────────────────────────────────────────────────────────────
@MainActor
@Suite("按压反馈")
struct PressFeedbackTests {

    /// 构造一个带棋盘的 `BoardView`（不挂窗口，仅供逻辑判定与渲染测试）。
    ///
    /// 用引用类型包装 `Board` —— `Board` 非 `Sendable`，
    /// 不能放进元组跨并发域返回（Swift 6 会报 data race 风险）。
    /// `@unchecked Sendable`：本夹具只在单线程测试用例内使用，不跨线程共享。
    private final class Fixture: @unchecked Sendable {
        let board: Board
        let view: BoardView
        init() {
            board = Board(difficulty: .beginner, generator: SeededGenerator(seed: 20261022))
            let renderer = try! TileRenderer()
            view = BoardView(board: board, renderer: renderer)
            view.frame = NSRect(x: 0, y: 0,
                                width: CGFloat(board.columns * Difficulty.cellSize),
                                height: CGFloat(board.rows * Difficulty.cellSize))
        }
    }

    /// 构造测试夹具。
    private func makeView() -> Fixture {
        Fixture()
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

    // MARK: - 图元语义

    @Test("`.blankPlate` 与 `.coveredCell` 是原版的凹陷/凸起配对")
    func blankPlateIsPressedPairOfCoveredCell() throws {
        let renderer = try TileRenderer()

        // 凸起格：左上角有白色高光、无暗边像素
        let covered = renderer.tileRGBA(for: .coveredCell)
        #expect(covered.width == 16 && covered.height == 16, "格子图块应为 16×16")
        let coveredTopLeft = pixel(covered, x: 0, y: 0)
        #expect(coveredTopLeft.r >= 240 && coveredTopLeft.g >= 240 && coveredTopLeft.b >= 240,
                ".coveredCell 左上角应为白色高光（凸起），实际 \(coveredTopLeft)")

        // 凹陷底板：左上角是 128 暗边、无白色高光
        let blank = renderer.tileRGBA(for: .blankPlate)
        let blankTopLeft = pixel(blank, x: 0, y: 0)
        #expect(abs(blankTopLeft.r - 128) <= 24 && abs(blankTopLeft.g - 128) <= 24 && abs(blankTopLeft.b - 128) <= 24,
                ".blankPlate 左上角应为 128 暗边（凹陷），实际 \(blankTopLeft)")

        // 两块图元不同
        #expect(covered.pixels != blank.pixels, "凸起与凹陷底板不应是同一块图元")
    }

    @Test("`.mineHighlighted` 是「红底高亮的雷」，不是按压态")
    func mineHighlightedIsRedMineNotPressed() throws {
        let renderer = try TileRenderer()
        let mine = renderer.tileRGBA(for: .mineHighlighted)
        var reds = 0
        for i in stride(from: 0, to: mine.pixels.count, by: 4) {
            let r = Int(mine.pixels[i]), g = Int(mine.pixels[i+1]), b = Int(mine.pixels[i+2])
            if r > 180 && g < 90 && b < 90 { reds += 1 }
        }
        #expect(reds > 100, ".mineHighlighted 应含大量红像素（红底高亮），实际 \(reds)")

        // 按压态用的是 .blankPlate（零红像素）
        let blank = renderer.tileRGBA(for: .blankPlate)
        var blankReds = 0
        for i in stride(from: 0, to: blank.pixels.count, by: 4) {
            let r = Int(blank.pixels[i]), g = Int(blank.pixels[i+1]), b = Int(blank.pixels[i+2])
            if r > 180 && g < 90 && b < 90 { blankReds += 1 }
        }
        #expect(blankReds == 0, "按压用的 .blankPlate 不应含红像素，实际 \(blankReds)")
    }

    @Test("按压渲染用凹陷底板，**绝不含红底**（回归：曾错用红底高亮的雷）")
    func pressedCellRendersBlankPlateNotRedMine() {
        let f = makeView()
        let view = f.view
        // 模拟鼠标在 (0,0) 并按下
        view.simulatePressForTesting(mouseCell: (row: 0, column: 0),
                                     pressed: true,
                                     bothButtons: false)

        // 判定本身必须为真（否则渲染断言无意义）
        #expect(view.shouldRenderPressed(row: 0, column: 0),
                "按压判定应为真（鼠标在 (0,0) 且左键按下）")

        // 把视图离屏渲染出来，读取 (0,0) 格的像素
        let size = CGFloat(Difficulty.cellSize)
        let width = Int(f.board.columns) * Int(size)
        let height = Int(f.board.rows) * Int(size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            Issue.record("无法创建离屏位图")
            return
        }
        rep.size = NSSize(width: width, height: height)
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            Issue.record("无法创建绘图上下文")
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()

        // ⚠️ **坐标系换算**（这里早前算反过，导致测试形同虚设）：
        //    * 视图坐标原点在**左下角**，行序自上而下 → 第 0 行在视图**顶部**
        //      （view y = (rows-1) * 16 .. rows * 16）；
        //    * 位图坐标原点在**左上角**（`colorAt` 的 y=0 是图像最上一行）。
        //    故 (0,0) 格在位图里是**最上面 16 行**（行号 0..15），
        //    它的「左上角」= 位图的**最前两行**、最左两列。
        let cellTop = 0                          // 该格在位图里的起始行
        var reds = 0
        var darkTopLeft = 0
        var whiteTopLeft = 0
        for y in cellTop..<(cellTop + Int(size)) {
            for x in 0..<Int(size) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = Int(color.redComponent * 255)
                let g = Int(color.greenComponent * 255)
                let b = Int(color.blueComponent * 255)
                if r > 180 && g < 90 && b < 90 { reds += 1 }
                // 该格的「左上角」= 位图最前两行 × 最左两列
                if y < cellTop + 2 && x < 2 {
                    if abs(r - 128) <= 24 && abs(g - 128) <= 24 && abs(b - 128) <= 24 {
                        darkTopLeft += 1
                    }
                    if r >= 240 && g >= 240 && b >= 240 { whiteTopLeft += 1
                    }
                }
            }
        }
        #expect(reds == 0, "按压的格子绝不应出现红底（红底=红底高亮的雷），实际红像素 \(reds)")
        #expect(darkTopLeft > 0, "按压的格子应是凹陷底板（左上 128 暗边），实际暗像素 \(darkTopLeft)")
        #expect(whiteTopLeft == 0, "按压的格子左上不应有白色高光（那是凸起态特征），实际白像素 \(whiteTopLeft)")
    }

    // MARK: - 判定逻辑

    @Test("单键按下：仅鼠标所在格凹陷")
    func singleButtonPressOnlyThatCell() {
        let f = makeView()
        let view = f.view
        // 模拟：鼠标在 (3,3)，左键按下
        view.simulatePressForTesting(mouseCell: (row: 3, column: 3),
                                     pressed: true,
                                     bothButtons: false)
        #expect(view.shouldRenderPressed(row: 3, column: 3), "鼠标所在格应凹陷")
        #expect(!view.shouldRenderPressed(row: 3, column: 4), "旁边格不应凹陷")
        #expect(!view.shouldRenderPressed(row: 4, column: 3), "下面格不应凹陷")
        #expect(!view.shouldRenderPressed(row: 0, column: 0), "远处格不应凹陷")
    }

    @Test("左右同按：鼠标格及八邻都凹陷")
    func bothButtonsPressedAffectsNeighborhood() {
        let f = makeView()
        let view = f.view
        view.simulatePressForTesting(mouseCell: (row: 3, column: 3),
                                     pressed: true,
                                     bothButtons: true)
        // 自身
        #expect(view.shouldRenderPressed(row: 3, column: 3), "自身应凹陷")
        // 四邻
        #expect(view.shouldRenderPressed(row: 2, column: 3), "上邻应凹陷")
        #expect(view.shouldRenderPressed(row: 4, column: 3), "下邻应凹陷")
        #expect(view.shouldRenderPressed(row: 3, column: 2), "左邻应凹陷")
        #expect(view.shouldRenderPressed(row: 3, column: 4), "右邻应凹陷")
        // 对角
        #expect(view.shouldRenderPressed(row: 2, column: 2), "左上对角应凹陷")
        #expect(view.shouldRenderPressed(row: 4, column: 4), "右下对角应凹陷")
        // 距离 2 的不凹陷
        #expect(!view.shouldRenderPressed(row: 1, column: 3), "距离 2 的格不应凹陷")
        #expect(!view.shouldRenderPressed(row: 3, column: 5), "距离 2 的格不应凹陷")
    }

    @Test("未按下时不凹陷")
    func noPressNoPressedCell() {
        let f = makeView()
        let view = f.view
        view.simulatePressForTesting(mouseCell: (row: 3, column: 3),
                                     pressed: false,
                                     bothButtons: false)
        #expect(!view.shouldRenderPressed(row: 3, column: 3), "未按下时不应有凹陷格")
    }

    @Test("已翻开的格子不参与按压凹陷")
    func revealedCellNotPressed() {
        let f = makeView()
        let view = f.view
        // 翻开 (2,2)
        f.board.reveal(row: 2, column: 2)
        view.simulatePressForTesting(mouseCell: (row: 2, column: 2),
                                     pressed: true,
                                     bothButtons: false)
        #expect(!view.shouldRenderPressed(row: 2, column: 2),
                "已翻开的格子不参与按压反馈（原版按压分支在未翻开路径内）")
    }

    @Test("鼠标不在棋盘上时不凹陷")
    func mouseOffBoardNoPressedCell() {
        let f = makeView()
        let view = f.view
        view.simulatePressForTesting(mouseCell: nil, pressed: true, bothButtons: false)
        #expect(!view.shouldRenderPressed(row: 0, column: 0), "鼠标不在棋盘上时不应有凹陷格")
    }

    // MARK: - 辅助

    /// 取 RGBA 缓冲中某点的颜色。
    private func pixel(_ buf: (width: Int, height: Int, pixels: [UInt8]), x: Int, y: Int)
        -> (r: Int, g: Int, b: Int) {
        let i = (y * buf.width + x) * 4
        return (Int(buf.pixels[i]), Int(buf.pixels[i + 1]), Int(buf.pixels[i + 2]))
    }
}
