import AppKit
import Foundation

/// 图集（`tiles_144x81.bmp`）的图块索引表。
///
/// ────────────────────────────────────────────────────────────────────────
/// **图集真实结构**（由 `Tools/tiles_inspect.py` 像素实测 + 反汇编交叉验证）
///
/// 图集 **不是** 均匀的 9×5 个 16×16 网格，而是 3 个不同规格的子图集纵向拼接：
///
/// ```
/// y = 0 .. 31    区域 A：9 列 × 2 行 × 16×16  —— 格子图块
/// y = 32 .. 54   区域 B：11 个 × 13×23      —— 七段 LED 数字（计数器/计时器）
/// y = 55 .. 80   区域 C：5 个 × 26×26       —— 笑脸（表情按钮）
/// ```
///
/// 各区域在原版反汇编中的证据：
/// * 区域 A：格子步进一律 `shl eax, 4`（×16），见 `0x401E1B`。
/// * 区域 B：BitBlt 宽度 `0x0D`(13)、高度 `0x17`(23)、`ySrc=0x20`(32)、
///   `xSrc = 13*k`，见 `0x403660`–`0x403678`。
/// * 区域 C：BitBlt 宽高均 `0x1A`(26)、`ySrc=0x37`(55)、
///   `xSrc ∈ {0, 0x34(52), 0x4E(78), 0x68(104)}`，见 `0x403890`–`0x403978`。
///
/// 七段数字经「段几何中心点检测」严格解码，槽位依次为 0–9 与空白。
/// ────────────────────────────────────────────────────────────────────────
public enum TileIndex: Equatable, Hashable, Sendable {

    // ── 区域 A：格子图块（16×16）──

    /// 区域 A 第 0 行（y=0）：空白底板（第 0 列），非格子本身。
    case blankPlate
    /// 区域 A 第 0 行：数字 1–8（列 1–8，y=0）。
    case digit(Int)
    /// 区域 A 第 1 行（y=16）：未翻开格（灰色 3D 凸起）。
    case coveredCell
    /// 区域 A 第 1 行：红旗。
    case flag
    /// 区域 A 第 1 行：地雷。
    case mine
    /// 区域 A 第 1 行：地雷 + 红底高亮（踩雷瞬间）。
    case mineHighlighted
    /// 区域 A 第 1 行：插错旗的地雷（X 标记）。
    case mineWithX

    // ── 区域 B：七段 LED 数字（13×23）──

    /// 区域 B：七段数字 0–9，或 `nil` 表示空白。
    case ledDigit(Int?)

    // ── 区域 C：笑脸（26×26）──

    /// 区域 C：5 种表情之一。
    case face(FaceExpression)
}

/// 图集加载与图块切取。
///
/// 切块在**像素层面**完成（不走 `NSImage` 往返），因此结果完全确定、
/// 与绘制时的缩放/插值无关；绘制时统一 `interpolationQuality = .none`，
/// 保证像素级保真。
public final class TileRenderer {

    /// 原始图集（自上而下的 RGBA 像素）。
    private let decoded: DecodedImage

    /// 缓存切好的图块，避免重复切图。
    ///
    /// 缓存的是 `TileBitmap`（位图 + 其底层缓冲），
    /// 以保证位图的生命周期内像素缓冲始终有效。
    private var cache: [TileIndex: TileBitmap] = [:]

    /// 格子图块的边长（像素）。
    public static let cellTileSize = 16

    /// 七段数字图块的宽（像素）。
    public static let ledTileWidth = 13
    /// 七段数字图块的高（像素）。
    public static let ledTileHeight = 23

    /// 笑脸图块的边长（像素）。
    public static let faceTileSize = 26

    // MARK: - 加载

    /// 从 SPM 资源包加载图集。
    public convenience init() throws {
        try self.init(bundle: Bundle.module)
    }

    /// 从指定资源包加载图集。
    ///
    /// 注意：资源是从 EXE `.rsrc` 段直接抽出的**裸 DIB**（无 `BM` 文件头），
    /// AppKit 的 `NSBitmapImageRep(data:)` 不接受，故使用 `DIBImageLoader` 自行解析。
    public init(bundle: Bundle) throws {
        guard let url = bundle.url(forResource: "tiles_144x81", withExtension: "bmp") else {
            throw TileRendererError.resourceNotFound
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TileRendererError.resourceNotFound
        }
        do {
            decoded = try DIBImageLoader.decode(data: data)
        } catch {
            throw TileRendererError.dibLoadFailed("\(error)")
        }
        guard decoded.width == 144, decoded.height == 81 else {
            throw TileRendererError.unexpectedAtlasSize(
                width: decoded.width, height: decoded.height
            )
        }
    }

    // MARK: - 取图

    /// 取得某个图块的位图。
    public func bitmap(for index: TileIndex) -> NSBitmapImageRep {
        tile(for: index).rep
    }

    /// 取得某个图块的**原始 RGBA 像素**（自上而下，行内无填充）。
    ///
    /// 这是像素级保真的权威依据：切块结果与图集对应区域逐字节相同，
    /// 不经过 AppKit 的色彩管理 / 预乘等处理。
    public func rawPixels(for index: TileIndex) -> (width: Int, height: Int, rgba: [UInt8]) {
        let rect = pixelRect(for: index)
        let w = Int(rect.width)
        let h = Int(rect.height)
        let x0 = Int(rect.origin.x)
        let y0 = Int(rect.origin.y)

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            let srcBase = ((y0 + row) * decoded.width + x0) * 4
            let dstBase = row * w * 4
            for col in 0..<w {
                let s = srcBase + col * 4
                let d = dstBase + col * 4
                pixels[d + 0] = decoded.rgba[s + 0]
                pixels[d + 1] = decoded.rgba[s + 1]
                pixels[d + 2] = decoded.rgba[s + 2]
                pixels[d + 3] = decoded.rgba[s + 3]
            }
        }
        return (w, h, pixels)
    }

    /// 取得某个图块的图像（供绘制用）。
    public func image(for index: TileIndex) -> NSImage {
        let rep = bitmap(for: index)
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    /// 取得某个图块在图集中的像素矩形（自上而下坐标）。
    public func pixelRect(for index: TileIndex) -> CGRect {
        switch index {
        case .blankPlate:
            return CGRect(x: 0, y: 0, width: 16, height: 16)
        case .digit(let n):
            let col = min(max(n, 1), 8)
            return CGRect(x: CGFloat(col) * 16, y: 0, width: 16, height: 16)
        case .coveredCell:
            return CGRect(x: 0, y: 16, width: 16, height: 16)
        case .flag:
            return CGRect(x: 16, y: 16, width: 16, height: 16)
        case .mine:
            return CGRect(x: 32, y: 16, width: 16, height: 16)
        case .mineHighlighted:
            return CGRect(x: 48, y: 16, width: 16, height: 16)
        case .mineWithX:
            return CGRect(x: 64, y: 16, width: 16, height: 16)
        case .ledDigit(let n):
            guard let n else { return CGRect(x: 130, y: 32, width: 13, height: 23) }
            let slot = min(max(n, 0), 9)
            return CGRect(x: CGFloat(slot) * 13, y: 32, width: 13, height: 23)
        case .face(let expression):
            return CGRect(
                x: CGFloat(expression.rawValue) * 26,
                y: 55,
                width: 26,
                height: 26
            )
        }
    }

    /// 从图集像素缓冲中切出一个图块，返回纯 RGBA 字节（与 AppKit 无关，可精确断言）。
    ///
    /// 这是切图的**唯一真源**：绘制用的位图由它派生，
    /// 因此「切图正确性」与「绘制」解耦，可用逐像素断言验证。
    public func tileRGBA(for index: TileIndex) -> (width: Int, height: Int, pixels: [UInt8]) {
        let rect = pixelRect(for: index)
        let w = Int(rect.width)
        let h = Int(rect.height)
        let x0 = Int(rect.origin.x)
        let y0 = Int(rect.origin.y)

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            let srcBase = ((y0 + row) * decoded.width + x0) * 4
            let dstBase = row * w * 4
            for col in 0..<w {
                let s = srcBase + col * 4
                let d = dstBase + col * 4
                pixels[d + 0] = decoded.rgba[s + 0]
                pixels[d + 1] = decoded.rgba[s + 1]
                pixels[d + 2] = decoded.rgba[s + 2]
                pixels[d + 3] = decoded.rgba[s + 3]
            }
        }
        return (w, h, pixels)
    }

    /// 取得（并缓存）某个图块的位图及其底层缓冲。
    private func tile(for index: TileIndex) -> TileBitmap {
        if let cached = cache[index] { return cached }
        let (w, h, pixels) = tileRGBA(for: index)
        let created = TileBitmap(pixels: pixels, width: w, height: h)
        cache[index] = created
        return created
    }
}

/// 图块位图的持有者。
///
/// `NSBitmapImageRep` 不会复制 `bitmapDataPlanes` 指向的内存，
/// 因此必须让底层缓冲与位图**同生命周期**，故用本类把两者绑在一起。
private final class TileBitmap {

    /// 底层 RGBA 缓冲（32 位，行内无填充）。
    let buffer: UnsafeMutablePointer<UInt8>

    /// 对应的位图表示。
    let rep: NSBitmapImageRep

    /// 由 RGBA 字节构造位图。
    init(pixels: [UInt8], width: Int, height: Int) {
        buffer = .allocate(capacity: max(pixels.count, 1))
        buffer.update(from: pixels, count: pixels.count)
        var planes: [UnsafeMutablePointer<UInt8>?] = [buffer]
        rep = NSBitmapImageRep(
            bitmapDataPlanes: &planes,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) ?? NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
    }

    /// 便捷构造。
    static func make(pixels: [UInt8], width: Int, height: Int) -> NSBitmapImageRep {
        TileBitmap(pixels: pixels, width: width, height: height).rep
    }

    deinit {
        buffer.deallocate()
    }
}

/// 图集加载错误。
public enum TileRendererError: Error, CustomStringConvertible {
    case resourceNotFound
    case dibLoadFailed(String)
    case unexpectedAtlasSize(width: Int, height: Int)

    public var description: String {
        switch self {
        case .resourceNotFound:
            return "找不到图集资源 tiles_144x81.bmp"
        case .dibLoadFailed(let reason):
            return "图集（DIB）解析失败：\(reason)"
        case .unexpectedAtlasSize(let w, let h):
            return "图集尺寸异常，期望 144×81，实际 \(w)×\(h)"
        }
    }
}
