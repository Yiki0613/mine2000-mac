import AppKit
import Testing
@testable import Mine2000

/// 笑脸按钮「按下凹陷」的像素级回归测试。
///
/// ## 背景
///
/// 用户实测反馈：「你改没了一个东西，就是笑脸按键按下去的时候，那个凹凸质感的效果」。
///
/// 查证后发现是**两条问题叠加**：
///
/// 1. **按下态从来没实现**：`mouseDown` 里立即触发重开，游戏在按下的一瞬间就重置了，
///    用户永远看不到按下这一帧的视觉反馈。
/// 2. **垂直定位被 v1.4 改错**：为了消除 LED 的半像素问题，
///    把表情的 y 也套用了 LED 的 `ledTopInset = 4`（→ y = 2），
///    而原版表情的 `BitBlt` yDest 是 **3**（见下）。
///
/// ## 原版机制（反汇编确证）
///
/// 三条状态分支（`0x40388E` / `0x40391F` / `0x403978`）结构完全一致：
///
/// ```
/// cmp dword ptr [esi + 0x90], 1     ; 鼠标按键 == 1（未按下）？
/// jne  <按压分支>
///     → 各状态自己的表情（normal / win / lose）  ← 凸起版
/// <按压分支>:
///     mov ecx, [esi + 0x88]         ; 鼠标格 x
///     cmp ecx, -2                   ; -2 = 不在棋盘上
///     jne  → 在棋盘上按下：normal 态用 surprise，win/lose 用自身
///     （不在棋盘上，即按在 HUD 上）
///     → push 0x68 → 槽 4「idle」     ← 平脸 = 凹陷版
/// ```
///
/// 所有表情共用的贴图尾部 `0x4039A4`：
///
/// ```
/// 004039AE  shl eax, 4        ; 客户区宽 × 16
/// 004039BC  sar eax, 1        ; /2 → 水平中心
/// 004039BE  push 3            ; ★ yDest = 3
/// 004039C0  sub eax, 0xd      ; xDest = 中心 − 13
/// 004039C5  call [0x40800c]   ; BitBlt
/// ```
///
/// ## 槽 0 与槽 4 的像素差异（这就是「凹凸质感」的来源）
///
/// | 槽 | 图集 x | 左上 2px | 右下 | 观感 |
/// |---|---|---|---|---|
/// | 0 `normal` | 0 | **白 (255,255,255) 高光** | 128 阴影 | **凸起** |
/// | 4 `idle` | 104 | 纯黑边框（无高光） | 192 平面（无阴影） | **平/凹陷** |
///
/// 与棋盘格 `.coveredCell`（凸起）/ `.blankPlate`（凹陷）是同一套设计语言。
@MainActor
@Suite("笑脸按钮按下态")
struct FaceButtonTests {

    /// HUD 宽度（与真实初级棋盘同宽）。
    private let hudWidth = 256

    /// 构造一个 HUD（不挂窗口，供离屏渲染）。
    private func makeHUD() -> HUDView? {
        guard let renderer = try? TileRenderer() else { return nil }
        let hud = HUDView(renderer: renderer)
        hud.frame = NSRect(x: 0, y: 0,
                           width: CGFloat(hudWidth), height: CGFloat(HUDView.height))
        hud.scale = 1
        hud.remainingMines = 35
        hud.elapsedDeciseconds = 51
        hud.expression = .normal
        return hud
    }

    /// 离屏渲染 HUD。
    private func render(_ hud: HUDView) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: hudWidth, pixelsHigh: HUDView.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: CGFloat(hudWidth), height: CGFloat(HUDView.height))
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        hud.draw(hud.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// 把渲染出的表情区域与图集里的某个表情图块**逐像素比对**，返回不一致像素数。
    ///
    /// 坐标系：表情绘制在视图 y = 32−3−26 = **3**，位图原点在左上，
    /// 故映射到位图 y = 3…28（26 行）；x 居中 = (256−26)/2 = **115**。
    private func mismatch(_ rep: NSBitmapImageRep,
                          renderer: TileRenderer,
                          expected face: FaceExpression) -> (count: Int, firstBad: String) {
        let size = TileRenderer.faceTileSize
        let (w, h, atlas) = renderer.rawPixels(for: .face(face))
        let left = (hudWidth - size) / 2
        let top = HUDView.faceTopInset
        var count = 0
        var firstBad = ""
        for row in 0..<h {
            for col in 0..<w {
                let i = (row * w + col) * 4
                let er = Int(atlas[i])
                let eg = Int(atlas[i + 1])
                let eb = Int(atlas[i + 2])
                guard let c = rep.colorAt(x: left + col, y: top + row)?
                    .usingColorSpace(.sRGB) else {
                    count += 1
                    if firstBad.isEmpty { firstBad = "(\(left + col),\(top + row)) 无像素" }
                    continue
                }
                let ar = Int(c.redComponent * 255)
                let ag = Int(c.greenComponent * 255)
                let ab = Int(c.blueComponent * 255)
                if abs(ar - er) > 2 || abs(ag - eg) > 2 || abs(ab - eb) > 2 {
                    count += 1
                    if firstBad.isEmpty {
                        firstBad = "(\(left + col),\(top + row)) 期望(\(er),\(eg),\(eb)) 实际(\(ar),\(ag),\(ab))"
                    }
                }
            }
        }
        return (count, firstBad)
    }

    /// 构造一个鼠标事件（视图坐标直接当窗口坐标用 —— 视图无窗口时 `convert` 恒等）。
    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
        )
    }

    /// 表情按钮中心（视图坐标）。
    private var faceCenter: NSPoint {
        let size = CGFloat(TileRenderer.faceTileSize)
        return NSPoint(x: CGFloat(hudWidth) / 2,
                       y: CGFloat(HUDView.height) - CGFloat(HUDView.faceTopInset) - size / 2)
    }

    // MARK: - 像素判据

    /// **未按下时必须是「凸起版」槽 0（normal）**，与图集逐像素一致。
    @Test("未按下时渲染槽 0（凸起版），与图集逐像素一致")
    func idleStateRendersNormalTile() {
        guard let hud = makeHUD(), let renderer = try? TileRenderer(),
              let rep = render(hud) else {
            Issue.record("无法构造 HUD 或渲染")
            return
        }
        #expect(hud.isFacePressed == false, "初始不应是按下态")
        let (count, firstBad) = mismatch(rep, renderer: renderer, expected: .normal)
        #expect(count == 0, "未按下时表情有 \(count) 个像素与图集 normal 不一致，首个：\(firstBad)")
    }

    /// **按下时必须换成「平脸」槽 4（idle）** —— 这就是用户说的凹凸质感。
    @Test("按下时渲染槽 4（平脸/凹陷），与图集逐像素一致")
    func pressedStateRendersIdleTile() {
        guard let hud = makeHUD(), let renderer = try? TileRenderer() else {
            Issue.record("无法构造 HUD")
            return
        }
        hud.isFacePressed = true
        guard let rep = render(hud) else {
            Issue.record("无法渲染")
            return
        }
        let (count, firstBad) = mismatch(rep, renderer: renderer, expected: .idle)
        #expect(count == 0, "按下时表情有 \(count) 个像素与图集 idle 不一致，首个：\(firstBad)")
    }

    /// **两个槽必须真的不同**（否则上面的两条判据互相矛盾却都能过）。
    ///
    /// 差异集中在左上 2px 的高光（255,255,255）与右下的阴影（128,128,128）：
    /// normal 有、idle 没有 —— 这正是「凸起 vs 凹陷」的视觉来源。
    @Test("槽 0 与槽 4 的像素差异集中在 3D 高光/阴影上")
    func normalAndIdleDifferInBevel() {
        guard let renderer = try? TileRenderer() else {
            Issue.record("无法构造图集")
            return
        }
        let (w, h, a) = renderer.rawPixels(for: .face(.normal))
        let (_, _, b) = renderer.rawPixels(for: .face(.idle))
        var diff = 0
        var whiteInNormal = 0
        var whiteInIdle = 0
        for i in 0..<(w * h) {
            let o = i * 4
            if a[o] != b[o] || a[o + 1] != b[o + 1] || a[o + 2] != b[o + 2] {
                diff += 1
            }
            if a[o] > 240 && a[o + 1] > 240 && a[o + 2] > 240 { whiteInNormal += 1 }
            if b[o] > 240 && b[o + 1] > 240 && b[o + 2] > 240 { whiteInIdle += 1 }
        }
        #expect(diff > 0, "两个表情槽若完全相同，按下态就没有视觉反馈")
        #expect(whiteInNormal > 0, "凸起版（normal）应有白色高光")
        #expect(whiteInIdle == 0, "平脸（idle）不应有白色高光，实际 \(whiteInIdle) 个")
    }

    /// **表情垂直定位必须是原版的 3**（不是 LED 的 4）。
    @Test("表情顶边内缩 = 3（原版 yDest）")
    func faceTopInsetMatchesOriginal() {
        #expect(HUDView.faceTopInset == 3,
                "原版表情 BitBlt 的 yDest = 3（反汇编 0x4039A4 的 push 3）")
        // 上下留白应对称：32 − 3 − 26 = 3
        let bottom = HUDView.height - HUDView.faceTopInset - TileRenderer.faceTileSize
        #expect(bottom == HUDView.faceTopInset, "表情应垂直居中（上下各 3px）")
    }

    // MARK: - 交互判据

    /// **按下只进入凹陷态，不触发重开**；松开才触发。
    ///
    /// 早前实现在 `mouseDown` 里直接 `onFaceClicked?()`，
    /// 于是按下的一瞬间游戏就重置了 —— 凹陷态根本没有机会显示出来。
    @Test("按下不触发重开，松开才触发")
    func pressDoesNotFireUntilMouseUp() {
        guard let hud = makeHUD() else {
            Issue.record("无法构造 HUD")
            return
        }
        var clicks = 0
        hud.onFaceClicked = { clicks += 1 }

        guard let down = mouseEvent(.leftMouseDown, at: faceCenter),
              let up = mouseEvent(.leftMouseUp, at: faceCenter) else {
            Issue.record("无法构造鼠标事件")
            return
        }
        hud.mouseDown(with: down)
        #expect(hud.isFacePressed == true, "按下后应进入凹陷态")
        #expect(clicks == 0, "按下阶段不应触发重开，实际触发 \(clicks) 次")

        hud.mouseUp(with: up)
        #expect(hud.isFacePressed == false, "松开后应复位为凸起态")
        #expect(clicks == 1, "松开应触发一次重开，实际 \(clicks) 次")
    }

    /// **按下后拖出按钮再松开 → 弹回凸起且不触发重开**（标准按钮行为）。
    @Test("拖出按钮后松开：弹回凸起且不触发")
    func dragOutCancelsPress() {
        guard let hud = makeHUD() else {
            Issue.record("无法构造 HUD")
            return
        }
        var clicks = 0
        hud.onFaceClicked = { clicks += 1 }

        let outside = NSPoint(x: 4, y: 4)   // 左下角，远离笑脸按钮
        guard let down = mouseEvent(.leftMouseDown, at: faceCenter),
              let drag = mouseEvent(.leftMouseDragged, at: outside),
              let up = mouseEvent(.leftMouseUp, at: outside) else {
            Issue.record("无法构造鼠标事件")
            return
        }
        hud.mouseDown(with: down)
        #expect(hud.isFacePressed == true)
        hud.mouseDragged(with: drag)
        #expect(hud.isFacePressed == false, "拖出按钮应弹回凸起")
        hud.mouseUp(with: up)
        #expect(clicks == 0, "在按钮外松开不应触发重开，实际 \(clicks) 次")
    }

    /// **按下 HUD 的非按钮区域不应进入凹陷态**。
    @Test("按在 HUD 其他位置不触发凹陷")
    func pressOutsideFaceIsIgnored() {
        guard let hud = makeHUD() else {
            Issue.record("无法构造 HUD")
            return
        }
        var clicks = 0
        hud.onFaceClicked = { clicks += 1 }
        let corner = NSPoint(x: 4, y: 4)
        guard let down = mouseEvent(.leftMouseDown, at: corner),
              let up = mouseEvent(.leftMouseUp, at: corner) else {
            Issue.record("无法构造鼠标事件")
            return
        }
        hud.mouseDown(with: down)
        #expect(hud.isFacePressed == false, "笑脸区外按下不应凹陷")
        hud.mouseUp(with: up)
        #expect(clicks == 0, "笑脸区外松开不应触发重开")
    }
}
