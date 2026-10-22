import AppKit
import Foundation

// ── 图集解析（裸 DIB，无 BM 头，行自下而上）──
// 默认取仓库内的运行时资源（相对仓库根目录，由 build.sh 保证 CWD）。
// 可用环境变量 MINE2000_ATLAS 覆盖，便于指向自己解包的图集。
let atlasPath = ProcessInfo.processInfo.environment["MINE2000_ATLAS"]
    ?? "Sources/Mine2000/Resources/tiles_144x81.bmp"
let data = try! Data(contentsOf: URL(fileURLWithPath: atlasPath))
let aw = 144, ah = 81, aoff = 40
let arow = ((aw * 24 / 8) + 3) / 4 * 4

/// 取图集某矩形（参数是**左上原点**坐标），返回 NSImage（AppKit 会自动处理方向）
func atlasTile(x0: Int, y0: Int, w: Int, h: Int) -> NSImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    var buf = [UInt8](repeating: 255, count: w * h * 4)
    for row in 0..<h {
        // 左上原点的第 row 行 → DIB 物理行（DIB 第 0 行是图像底部）
        let srcY = ah - 1 - (y0 + row)
        for col in 0..<w {
            let o = aoff + srcY * arow + (x0 + col) * 3
            let d = (row * w + col) * 4
            buf[d + 0] = data[o + 2]     // R
            buf[d + 1] = data[o + 1]     // G
            buf[d + 2] = data[o + 0]     // B
            buf[d + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(buf) as CFData)!
    let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                     bytesPerRow: w * 4, space: cs,
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                     provider: provider, decode: nil, shouldInterpolate: false,
                     intent: .defaultIntent)!
    return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
}

let covered = atlasTile(x0: 0, y0: 16, w: 16, h: 16)
let flagged = atlasTile(x0: 16, y0: 16, w: 16, h: 16)
/// 旗子本体（去掉格子边框，只取中间 10×10 的旗+杆+底座）
let flagPart = atlasTile(x0: 18, y0: 19, w: 10, h: 10)

// ── 画布（标准左下原点，不翻转）──
let S = 1024
let outSize = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1024 : 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: outSize, pixelsHigh: outSize,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let nsc = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsc
let cg = nsc.cgContext
cg.interpolationQuality = .none
// 按目标尺寸缩放（逻辑坐标仍按 1024 写）
if outSize != S {
    let k = CGFloat(outSize) / CGFloat(S)
    cg.scaleBy(x: k, y: k)
}

// ── 背景：深灰圆角方形 ──
let inset: CGFloat = 100
let bg = CGRect(x: inset, y: inset, width: CGFloat(S) - inset * 2, height: CGFloat(S) - inset * 2)
let bgPath = CGPath(roundedRect: bg, cornerWidth: 185, cornerHeight: 185, transform: nil)
cg.saveGState()
cg.addPath(bgPath)
cg.clip()
// 左下原点：maxY 是顶部
let topColor = NSColor(srgbRed: 0.26, green: 0.28, blue: 0.34, alpha: 1).cgColor
let botColor = NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1).cgColor
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [botColor, topColor] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: bg.minY),
                      end: CGPoint(x: 0, y: bg.maxY), options: [])
cg.restoreGState()

// 内缘高光
cg.saveGState()
cg.addPath(bgPath)
cg.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor)
cg.setLineWidth(3)
cg.strokePath()
cg.restoreGState()

// ── 3×3 网格：中心红旗 ──
let cell = 200
let gap = 28
let gridW = cell * 3 + gap * 2
let originX = CGFloat(S - gridW) / 2
let originY = CGFloat(S - gridW) / 2

for row in 0..<3 {
    for col in 0..<3 {
        let x = originX + CGFloat(col * (cell + gap))
        // 视图坐标左下原点：第 0 行在最上 → y 反过来
        let y = originY + CGFloat((2 - row) * (cell + gap))
        let rect = CGRect(x: x, y: y, width: CGFloat(cell), height: CGFloat(cell))
        if row == 1 && col == 1 {
            // 中心格：投影 + 盖子 + 放大旗子
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 10), blur: 26,
                         color: NSColor(white: 0, alpha: 0.55).cgColor)
            cg.setFillColor(NSColor(white: 0.75, alpha: 1).cgColor)
            cg.fill(rect)
            cg.restoreGState()
            covered.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0,
                         respectFlipped: false,
                         hints: [.interpolation: NSImageInterpolation.none.rawValue])
            let fs = CGFloat(cell) * 0.82
            let fx = rect.midX - fs / 2
            let fy = rect.midY - fs / 2 - CGFloat(cell) * 0.03
            flagPart.draw(in: CGRect(x: fx, y: fy, width: fs, height: fs),
                          from: .zero, operation: .sourceOver, fraction: 1.0,
                          respectFlipped: false,
                          hints: [.interpolation: NSImageInterpolation.none.rawValue])
        } else {
            covered.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0,
                         respectFlipped: false,
                         hints: [.interpolation: NSImageInterpolation.none.rawValue])
            // 周围 8 格压暗，让中心格成为焦点
            cg.setFillColor(NSColor(white: 0, alpha: 0.28).cgColor)
            cg.fill(rect)
        }
    }
}

NSGraphicsContext.restoreGraphicsState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon/AppIcon_1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("已输出 \(out)")
