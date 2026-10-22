import AppKit
import Testing
@testable import Mine2000

/// HUD 布局的**像素级**回归测试。
///
/// ## 背景
///
/// 用户三次实测反馈，逐条把布局钉死：
/// 1. 「右上角的计时器没有像左上角一样在一个框里，割裂开了」
/// 2. 「左边（雷数）这样是对的，右边你改的还是不对」
/// 3. 「右上角的时间……感觉特别快，应该不是按秒跳的吧」
///
/// ## 第 3 条查出来的规格（反汇编 `0x403520` 确证）
///
/// **计时器位数按难度自适应**：
///
/// ```
/// 00403648  mov eax, [棋盘列数]
/// 0040364E  cmp eax, 8
/// 00403651  jle 0x4036B3     ; ≤ 8（初级）→ 跳过前两位，只画 3 位
///                            ; 否则 → 画满 5 位（万/千/百/十/个）
/// ```
///
/// **雷数永远 3 位**（`0x403B52`–`0x403B76` 只有 3 次贴图，x = 6/19/32）。
///
/// 所以原版左右本来就**不等宽**：中级以上计时器 5 位（65px）比雷数 3 位（39px）宽。
///
/// 单位始终是**十分之一秒**（`0x401C46` 用 `(now − baseline) / 100`），
/// 所以最右位每 0.1 秒跳一次 —— 这是设计，不是 bug。
///
/// ## 边距（原版实测值）
///
/// | 项 | 值 | 依据 |
/// |---|---|---|
/// | 雷数左边界 | **6** | `0x403B58` 的 `push 6` |
/// | 计时器右边界 | **6** | 末位 x = `16D − 19`，+13 → 右边界 `16D − 6` |
/// | LED 顶边内缩 | 4 | `0x403520` 的 `push 4` |
///
/// 校核：中级 256 宽 → 计时器起点 = 256 − 65 − 6 = **185** = `16D − 71` ✓
/// 初级 128 宽 → 计时器起点 = 128 − 39 − 6 = **83** = `8×16 − 45` ✓
///
/// ## 坐标系约定
///
/// | 坐标系 | 原点 | y 方向 |
/// |---|---|---|
/// | AppKit 视图 | 左下 | 向上 |
/// | `NSBitmapImageRep.colorAt` | 左上 | 向下 |
///
/// 换算：`位图 y = 视图高度 − 视图 y`。LED 占视图 y = 5…28，位图 y = 4…26。
@MainActor
@Suite("HUD 布局")
struct HUDLayoutTests {

    /// 渲染 HUD 并返回位图。
    ///
    /// - Parameters:
    ///   - width: HUD 逻辑宽度（= 棋盘宽）。
    ///   - columns: 棋盘列数，决定计时器位数（≤8 → 3 位，否则 5 位）。
    ///   - mines: 雷数。
    ///   - deciseconds: 已用时（十分之一秒）。
    private func renderHUD(width: Int, columns: Int, mines: Int,
                           deciseconds: Int) -> NSBitmapImageRep? {
        let renderer = try? TileRenderer()
        guard let renderer else { return nil }
        let hud = HUDView(renderer: renderer)
        hud.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(HUDView.height))
        hud.timerColumns = columns
        hud.remainingMines = mines
        hud.elapsedDeciseconds = deciseconds

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: HUDView.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        rep?.size = NSSize(width: CGFloat(width), height: CGFloat(HUDView.height))
        guard let rep, let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        hud.draw(hud.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// 读一个像素的 sRGB 分量。
    private func rgb(_ rep: NSBitmapImageRep, x: Int, y: Int) -> (r: Int, g: Int, bl: Int)? {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    /// 计时器起始 x（视图坐标）。宽度 = 位数 × 13，右边距 6。
    private func timerOriginX(width: Int, digits: Int) -> Int {
        width - digits * TileRenderer.ledTileWidth - HUDView.timerRightInset
    }

    /// LED 在位图里占的第一行（顶边框行）。
    private var bitmapTopRow: Int { HUDView.ledTopInset }

    /// 把渲染出的某个槽与图集里的数字图块逐像素比对，返回不一致像素数。
    private func mismatchCount(rep: NSBitmapImageRep, renderer: TileRenderer,
                               slotX: Int, digit: Int) -> (count: Int, firstBad: String) {
        let ledW = TileRenderer.ledTileWidth
        let ledH = TileRenderer.ledTileHeight
        let (tw, th, atlas) = renderer.rawPixels(for: .ledDigit(digit))
        var count = 0
        var firstBad = ""
        for row in 0..<th {
            let bitmapY = bitmapTopRow + row
            for col in 0..<tw {
                let a = Int(atlas[(row * tw + col) * 4])
                let b = Int(atlas[(row * tw + col) * 4 + 1])
                let c = Int(atlas[(row * tw + col) * 4 + 2])
                guard let actual = rgb(rep, x: slotX + col, y: bitmapY) else {
                    count += 1
                    if firstBad.isEmpty { firstBad = "(\(slotX + col),\(bitmapY)) 无像素" }
                    continue
                }
                if abs(actual.r - a) > 2 || abs(actual.g - b) > 2 || abs(actual.bl - c) > 2 {
                    count += 1
                    if firstBad.isEmpty {
                        firstBad = "(\(slotX + col),\(bitmapY)) 期望(\(a),\(b),\(c))"
                            + " 实际(\(actual.r),\(actual.g),\(actual.bl))"
                    }
                }
            }
        }
        return (count, firstBad)
    }

    /// 逐槽比对一串数字。
    private func expectSlots(_ digits: [Int], originX: Int,
                             rep: NSBitmapImageRep, renderer: TileRenderer,
                             label: String) {
        let ledW = TileRenderer.ledTileWidth
        for (index, digit) in digits.enumerated() {
            let slotX = originX + index * ledW
            let (count, firstBad) = mismatchCount(rep: rep, renderer: renderer,
                                                 slotX: slotX, digit: digit)
            #expect(count == 0,
                    "\(label) 槽 \(index + 1)（数字 \(digit)）有 \(count) 个像素与图集不一致，首个：\(firstBad)")
        }
    }

    // MARK: - 位数规则

    /// **初级 3 位、其他难度 5 位**（原版 `0x403520` 的 `cmp 8` 分支）。
    @Test("计时器位数：初级 3 位、其他难度 5 位")
    func timerDigitCountFollowsDifficulty() {
        let renderer = try? TileRenderer()
        guard let renderer else { Issue.record("图集加载失败"); return }

        func digits(columns: Int) -> Int {
            let hud = HUDView(renderer: renderer)
            hud.timerColumns = columns
            return hud.timerDigitCount
        }
        #expect(digits(columns: 8) == 3, "初级 8 列 → 3 位")
        #expect(digits(columns: 16) == 5, "中级 16 列 → 5 位")
        #expect(digits(columns: 30) == 5)
        #expect(digits(columns: 48) == 5)
        #expect(digits(columns: 64) == 5)
    }

    /// **边距必须与原版一致**：雷数左 6、计时器右 6。
    @Test("左右边距均为 6px")
    func insetsMatchOriginal() {
        #expect(HUDView.minesLeftInset == 6, "原版 0x403B58 的 push 6")
        #expect(HUDView.timerRightInset == 6, "原版末位 x = 16D − 19，右边界 = 16D − 6")
        // 中级 256 宽、5 位 → 起点 185，与原版 16D − 71 = 185 吻合
        #expect(timerOriginX(width: 256, digits: 5) == 185)
        // 初级 128 宽、3 位 → 起点 83，与原版 8×16 − 45 = 83 吻合
        #expect(timerOriginX(width: 128, digits: 3) == 83)
    }

    // MARK: - 像素判据

    /// **中级：5 位全部与图集一致**（`1234` → `01234`）。
    @Test("中级计时器 5 位与图集数字图块逐像素一致")
    func middleTimerMatchesAtlas() {
        guard let rep = renderHUD(width: 256, columns: 16, mines: 40, deciseconds: 1234),
              let renderer = try? TileRenderer() else {
            Issue.record("无法渲染 HUD"); return
        }
        let origin = timerOriginX(width: 256, digits: 5)
        expectSlots([0, 1, 2, 3, 4], originX: origin, rep: rep, renderer: renderer, label: "中级计时")
    }

    /// **初级：3 位且与图集一致**（`508` → 50.8 秒）。
    @Test("初级计时器 3 位与图集数字图块逐像素一致")
    func beginnerTimerMatchesAtlas() {
        guard let rep = renderHUD(width: 128, columns: 8, mines: 10, deciseconds: 508),
              let renderer = try? TileRenderer() else {
            Issue.record("无法渲染 HUD"); return
        }
        let origin = timerOriginX(width: 128, digits: 3)
        expectSlots([5, 0, 8], originX: origin, rep: rep, renderer: renderer, label: "初级计时")
    }

    /// **初级超过 99.9 秒时按原版语义回绕**（只取后 3 位）。
    ///
    /// 原版 3 位只画百/十/个位，高位直接不画 —— 所以 `1234` 显示为 `234`。
    /// 这是「彻底不溢出」的另一种表现：不会挤掉别的位置。
    @Test("初级超 99.9 秒回绕为后 3 位，不压掉其他槽")
    func beginnerWrapsInsteadOfOverflowing() {
        guard let rep = renderHUD(width: 128, columns: 8, mines: 10, deciseconds: 1234),
              let renderer = try? TileRenderer() else {
            Issue.record("无法渲染 HUD"); return
        }
        let origin = timerOriginX(width: 128, digits: 3)
        // 1234 % 1000 = 234
        expectSlots([2, 3, 4], originX: origin, rep: rep, renderer: renderer, label: "初级回绕")
    }

    /// **5 位在 9999.9 秒内绝不溢出** —— 这修掉了「123.4 秒显示成 123」的 bug。
    @Test("中级 5 位在 999.9 秒内不溢出（回归：曾显示成 3 位）")
    func middleNeverOverflows() {
        guard let rep = renderHUD(width: 256, columns: 16, mines: 40, deciseconds: 9999),
              let renderer = try? TileRenderer() else {
            Issue.record("无法渲染 HUD"); return
        }
        let origin = timerOriginX(width: 256, digits: 5)
        // 9999 十分之一秒 = 999.9 秒 → "09999"
        expectSlots([0, 9, 9, 9, 9], originX: origin, rep: rep, renderer: renderer, label: "中级上限")
    }

    /// **雷数计数器始终 3 位、与图集一致**（对照组）。
    @Test("雷数计数器 3 槽与图集数字图块逐像素一致")
    func mineSlotsMatchAtlasTiles() {
        guard let rep = renderHUD(width: 256, columns: 16, mines: 40, deciseconds: 51),
              let renderer = try? TileRenderer() else {
            Issue.record("无法渲染 HUD"); return
        }
        let x0 = HUDView.minesLeftInset
        expectSlots([0, 4, 0], originX: x0, rep: rep, renderer: renderer, label: "雷数")
    }

    /// **LED 垂直定位必须是整数**（避免抗锯齿）。
    @Test("LED 垂直定位为整数（顶边内缩 4px）")
    func ledVerticalPositionIsIntegral() {
        #expect(HUDView.ledTopInset == 4, "原版 BitBlt 的 yDest = 4（反汇编 0x403520）")
        let bottom = HUDView.height - HUDView.ledTopInset - TileRenderer.ledTileHeight
        #expect(bottom == 5)
        #expect(Double(bottom).truncatingRemainder(dividingBy: 1) == 0)
    }

    /// **雷数为负（超插旗）时钳到 0，不画出多余槽位**。
    @Test("雷数为负时钳制为 000")
    func negativeMineCountStaysInThreeSlots() {
        guard let rep = renderHUD(width: 256, columns: 16, mines: -3, deciseconds: 0),
              let renderer = try? TileRenderer() else {
            Issue.record("无法渲染 HUD"); return
        }
        let x0 = HUDView.minesLeftInset
        expectSlots([0, 0, 0], originX: x0, rep: rep, renderer: renderer, label: "雷数(负值钳制)")
    }
}
