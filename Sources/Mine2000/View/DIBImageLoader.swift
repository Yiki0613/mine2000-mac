import AppKit
import CoreGraphics
import Foundation

/// 裸 DIB（`BITMAPINFOHEADER` + 像素数据）解码结果。
///
/// 提供**自上而下**的原始 RGBA 像素缓冲，
/// 供 `TileRenderer` 做确定性的像素级切块。
public struct DecodedImage {

    /// 像素宽。
    public let width: Int
    /// 像素高。
    public let height: Int
    /// 自上而下、逐行排列的 RGBA 字节（每像素 4 字节，行内无填充）。
    public let rgba: [UInt8]

    /// 取某点的 RGBA（坐标自上而下）。
    public func pixel(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * width + x) * 4
        return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]), Int(rgba[i + 3]))
    }

    /// 构造 `CGImage`（自上而下的像素缓冲）。
    public func makeCGImage() -> CGImage? {
        var buffer = rgba
        guard let provider = CGDataProvider(data: Data(buffer) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { return nil }
        buffer.removeAll()
        return image
    }
}

/// 裸 DIB（`BITMAPINFOHEADER` + 像素数据）加载器。
///
/// ────────────────────────────────────────────────────────────────────────
/// **为什么需要它**
///
/// 从原版 EXE 的 `.rsrc` 段提取出来的位图资源是**裸 DIB**，
/// 而不是带 `BITMAPFILEHEADER` 的标准 `.bmp` 文件：
///
/// ```
/// 28 00 00 00 90 00 00 00 51 00 00 00 01 00 18 00
/// └─ biSize=40  └─ biWidth=144  └─ biHeight=81 ┘ └bpp=24
/// ```
///
/// 标准 BMP 应以 `42 4D`（"BM"）开头，这里没有 —— 它就是资源段里的原始字节。
/// 因此：
/// * `NSBitmapImageRep(data:)` 会直接返回 **nil**（AppKit 不接受裸 DIB）；
/// * Pillow 则能容忍并正确读出（其 BMP 插件有裸 DIB 回退路径）。
///
/// 本加载器自行解析 DIB 头并按 BGR(BGRA) 逐像素还原，
/// **不重新编码、不做任何颜色变换**，保证像素级与原版资源完全一致。
///
/// ────────────────────────────────────────────────────────────────────────
/// **底向上存储的处理**
///
/// `biHeight` 为正表示像素自下而上存储（BMP 惯例）。
/// 本加载器在解码时就把行序翻转为**自上而下**，
/// 因此后续所有取图坐标（y 向下增长）都直接对应最终画面。
public enum DIBImageLoader {

    /// 加载错误。
    public enum LoadError: Error, CustomStringConvertible {
        case tooShort
        case unsupportedHeaderSize(Int)
        case unsupportedBitDepth(Int)
        case unsupportedCompression(Int)
        case truncatedPixelData(expected: Int, actual: Int)
        case cgImageCreationFailed

        public var description: String {
            switch self {
            case .tooShort:
                return "DIB 数据过短"
            case .unsupportedHeaderSize(let s):
                return "不支持的 DIB 头长度 \(s)（仅支持 BITMAPINFOHEADER=40）"
            case .unsupportedBitDepth(let b):
                return "不支持的位深 \(b)（仅支持 24bpp / 32bpp）"
            case .unsupportedCompression(let c):
                return "不支持的压缩方式 \(c)（仅支持 BI_RGB=0）"
            case .truncatedPixelData(let e, let a):
                return "像素数据不足，期望 \(e) 字节，实际 \(a) 字节"
            case .cgImageCreationFailed:
                return "无法构造 CGImage"
            }
        }
    }

    /// 解析裸 DIB（或标准 BMP），返回自上而下的像素缓冲。
    public static func decode(data: Data) throws -> DecodedImage {
        let bytes = [UInt8](data)

        // ── 定位 BITMAPINFOHEADER ──
        var offset = 0
        if bytes.count >= 2, bytes[0] == 0x42, bytes[1] == 0x4D {
            // 标准 BMP：跳过 14 字节 BITMAPFILEHEADER
            offset = 14
        }
        guard bytes.count >= offset + 40 else { throw LoadError.tooShort }

        func u32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8)
                | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
        }
        func i32(_ at: Int) -> Int32 { Int32(bitPattern: u32(at)) }
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8) }

        let headerSize = Int(u32(offset))
        guard headerSize == 40 else { throw LoadError.unsupportedHeaderSize(headerSize) }

        let width = Int(i32(offset + 4))
        let heightRaw = i32(offset + 8)
        let bitCount = Int(u16(offset + 14))
        let compression = Int(u32(offset + 16))

        guard bitCount == 24 || bitCount == 32 else {
            throw LoadError.unsupportedBitDepth(bitCount)
        }
        guard compression == 0 else {
            throw LoadError.unsupportedCompression(compression)
        }

        // 负的 biHeight 表示自上而下存储
        let isTopDown = heightRaw < 0
        let height = abs(Int(heightRaw))
        guard width > 0, height > 0 else { throw LoadError.tooShort }

        // 每行按 4 字节对齐
        let rowBytes = ((width * bitCount + 31) / 32) * 4
        let bytesPerPixel = bitCount / 8
        let pixelBytes = rowBytes * height

        let pixelStart = offset + headerSize
        guard bytes.count >= pixelStart + pixelBytes else {
            throw LoadError.truncatedPixelData(
                expected: pixelBytes,
                actual: bytes.count - pixelStart
            )
        }

        // ── 逐行翻转为自上而下，同时把 BGR(A) 转为 RGBA ──
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for outRow in 0..<height {
            // 源行：自上而下存储时顺序相同，否则倒序
            let srcRow = isTopDown ? outRow : (height - 1 - outRow)
            let srcBase = pixelStart + srcRow * rowBytes
            let dstBase = outRow * width * 4
            for x in 0..<width {
                let s = srcBase + x * bytesPerPixel
                let d = dstBase + x * 4
                rgba[d + 0] = bytes[s + 2]      // R
                rgba[d + 1] = bytes[s + 1]      // G
                rgba[d + 2] = bytes[s + 0]      // B
                rgba[d + 3] = bitCount == 32 ? bytes[s + 3] : 255  // A
            }
        }

        return DecodedImage(width: width, height: height, rgba: rgba)
    }

    /// 解析裸 DIB（或标准 BMP）并直接返回 `CGImage`。
    public static func load(data: Data) throws -> CGImage {
        let decoded = try decode(data: data)
        guard let image = decoded.makeCGImage() else {
            throw LoadError.cgImageCreationFailed
        }
        return image
    }
}
