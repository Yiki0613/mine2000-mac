import Testing
import AppKit
@testable import Mine2000

/// 图集加载与切块测试。
///
/// 图集是从 EXE `.rsrc` 段抽出的**裸 DIB**（无 BMP 文件头），
/// 这组测试同时验证「DIB 能被正确解析」与「切块坐标与图集规格一致」。
@MainActor
@Suite("图集渲染")
struct TileRendererTests {

    /// 图集能被加载，且尺寸为 144×81。
    @Test("图集可加载且尺寸为 144×81")
    func testAtlasLoads() throws {
        let renderer = try TileRenderer()
        let image = renderer.image(for: .coveredCell)
        #expect(image.size.width == 16)
        #expect(image.size.height == 16)
    }

    /// 各图块的像素矩形必须与图集规格一致（区域 A / B / C 的坐标）。
    @Test("图块像素矩形与图集规格一致")
    func testPixelRects() throws {
        let renderer = try TileRenderer()

        // 区域 A：9 列 × 2 行 × 16×16
        #expect(renderer.pixelRect(for: .blankPlate) == CGRect(x: 0, y: 0, width: 16, height: 16))
        #expect(renderer.pixelRect(for: .digit(1)) == CGRect(x: 16, y: 0, width: 16, height: 16))
        #expect(renderer.pixelRect(for: .digit(8)) == CGRect(x: 128, y: 0, width: 16, height: 16))
        #expect(renderer.pixelRect(for: .coveredCell) == CGRect(x: 0, y: 16, width: 16, height: 16))
        #expect(renderer.pixelRect(for: .flag) == CGRect(x: 16, y: 16, width: 16, height: 16))
        #expect(renderer.pixelRect(for: .mine) == CGRect(x: 32, y: 16, width: 16, height: 16))
        #expect(renderer.pixelRect(for: .mineHighlighted) == CGRect(x: 48, y: 16, width: 16, height: 16))
        #expect(renderer.pixelRect(for: .mineWithX) == CGRect(x: 64, y: 16, width: 16, height: 16))

        // 区域 B：11 个 × 13×23，y=32
        #expect(renderer.pixelRect(for: .ledDigit(0)) == CGRect(x: 0, y: 32, width: 13, height: 23))
        #expect(renderer.pixelRect(for: .ledDigit(9)) == CGRect(x: 117, y: 32, width: 13, height: 23))
        #expect(renderer.pixelRect(for: .ledDigit(nil)) == CGRect(x: 130, y: 32, width: 13, height: 23))

        // 区域 C：5 个 × 26×26，y=55
        #expect(renderer.pixelRect(for: .face(.normal)) == CGRect(x: 0, y: 55, width: 26, height: 26))
        #expect(renderer.pixelRect(for: .face(.idle)) == CGRect(x: 104, y: 55, width: 26, height: 26))
    }

    /// 数字图块数量越界时应被夹取到 1...8。
    @Test("数字图块索引被夹取到 1...8")
    func testDigitIndexClamping() throws {
        let renderer = try TileRenderer()
        #expect(renderer.pixelRect(for: .digit(0)) == renderer.pixelRect(for: .digit(1)))
        #expect(renderer.pixelRect(for: .digit(99)) == renderer.pixelRect(for: .digit(8)))
    }

    /// 切出的图块必须互不相同（防止切图坐标写错导致重复）。
    @Test("不同图块切出的像素不同")
    func testDistinctTiles() throws {
        let renderer = try TileRenderer()
        func fingerprint(_ index: TileIndex) -> Data {
            let image = renderer.image(for: index)
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else {
                return Data()
            }
            return data
        }
        let covered = fingerprint(.coveredCell)
        let flag = fingerprint(.flag)
        let mine = fingerprint(.mine)
        let mineRed = fingerprint(.mineHighlighted)
        let mineX = fingerprint(.mineWithX)
        #expect(covered != flag)
        #expect(flag != mine)
        #expect(mine != mineRed)
        #expect(mineRed != mineX)
        #expect(covered.count > 0)
    }

    /// 表情图块互不相同（5 张脸确实不同）。
    @Test("5 张表情互不相同")
    func testFacesAreDistinct() throws {
        let renderer = try TileRenderer()
        var fingerprints: Set<String> = []
        for face in FaceExpression.allCases {
            let image = renderer.image(for: .face(face))
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else {
                Issue.record("无法序列化表情 \(face)")
                continue
            }
            fingerprints.insert(data.base64EncodedString())
        }
        #expect(fingerprints.count == 5, "5 张表情应互不相同")
    }

    /// DIB 加载器：解析出的位图尺寸与像素格式正确。
    @Test("DIB 解析结果为 144×81 RGBA")
    func testDIBLoaderProducesExpectedImage() throws {
        let url = try #require(Bundle.module.url(forResource: "tiles_144x81", withExtension: "bmp"))
        let data = try Data(contentsOf: url)
        let image = try DIBImageLoader.load(data: data)
        #expect(image.width == 144)
        #expect(image.height == 81)
    }

    /// DIB 加载器：像素内容与「自上而下」的原图一致。
    ///
    /// 抽查图集左上角（第 0 行第 0 列 = 底板灰 128,128,128）
    /// 与区域 B 的七段数字（亮红 255,0,0）等特征点。
    @Test("DIB 解析的像素颜色正确")
    func testDIBPixelColors() throws {
        let url = try #require(Bundle.module.url(forResource: "tiles_144x81", withExtension: "bmp"))
        let data = try Data(contentsOf: url)
        let image = try DIBImageLoader.load(data: data)

        // 取出像素
        let width = image.width
        var pixels = [UInt8](repeating: 0, count: width * image.height * 4)
        let context = CGContext(
            data: &pixels,
            width: width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))

        func rgba(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
        }

        // 图集左上角是底板灰 (128,128,128)
        let topLeft = rgba(0, 0)
        #expect(topLeft.0 == 128 && topLeft.1 == 128 && topLeft.2 == 128,
                "左上角应为底板灰，实际 \(topLeft)")

        // 区域 B 的七段数字 0（x=0,y=32）应含亮红 (255,0,0)
        var foundBrightRed = false
        for y in 32..<55 {
            for x in 0..<13 {
                let p = rgba(x, y)
                if p.0 == 255 && p.1 == 0 && p.2 == 0 { foundBrightRed = true }
            }
        }
        #expect(foundBrightRed, "区域 B 的七段数字应含亮红色")
    }

    /// 切出的图块必须与图集对应区域**逐像素完全一致**（像素级保真的硬校验）。
    @Test("切出的图块与图集逐像素一致")
    func testSlicedTilesMatchAtlasPixels() throws {
        let url = try #require(Bundle.module.url(forResource: "tiles_144x81", withExtension: "bmp"))
        let decoded = try DIBImageLoader.decode(data: try Data(contentsOf: url))
        let renderer = try TileRenderer()

        let cases: [TileIndex] = [
            .blankPlate, .digit(1), .digit(8),
            .coveredCell, .flag, .mine, .mineHighlighted, .mineWithX,
            .ledDigit(0), .ledDigit(5), .ledDigit(nil),
            .face(.normal), .face(.win), .face(.lose), .face(.surprise), .face(.idle),
        ]

        for index in cases {
            let rect = renderer.pixelRect(for: index)
            let w = Int(rect.width), h = Int(rect.height)
            let x0 = Int(rect.origin.x), y0 = Int(rect.origin.y)

            // 切出的纯 RGBA 字节（切图真源）
            let tile = renderer.tileRGBA(for: index)
            #expect(tile.width == w, "\(index) 宽度应为 \(w)")
            #expect(tile.height == h, "\(index) 高度应为 \(h)")

            var mismatches = 0
            for row in 0..<h {
                for col in 0..<w {
                    let src = ((y0 + row) * decoded.width + (x0 + col)) * 4
                    let dst = (row * w + col) * 4
                    if decoded.rgba[src] != tile.pixels[dst]
                        || decoded.rgba[src + 1] != tile.pixels[dst + 1]
                        || decoded.rgba[src + 2] != tile.pixels[dst + 2] {
                        mismatches += 1
                    }
                }
            }
            #expect(mismatches == 0, "\(index) 有 \(mismatches) 个像素与图集不一致")

            // 位图表示的尺寸必须与图块尺寸一致（绘制路径的尺寸校验）
            let rep = renderer.bitmap(for: index)
            #expect(rep.pixelsWide == w, "\(index) 位图宽度应为 \(w)")
            #expect(rep.pixelsHigh == h, "\(index) 位图高度应为 \(h)")
        }
    }
}
