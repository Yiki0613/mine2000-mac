import AppKit
import Foundation

/// 离屏渲染工具：把各难度的棋盘渲染成 PNG，用于**视觉验证**。
///
/// ────────────────────────────────────────────────────────────────────────
/// **用途**
///
/// 证明「图集切块 → 棋盘贴图 → HUD 绘制」这条链路真的能画出东西，
/// 而不仅仅是「代码能编译」。在无 GUI 的环境下也能跑：
/// 用 `NSBitmapImageRep` + `cacheDisplay(in:to:)` 做**离屏渲染**，
/// 不需要弹出窗口。
///
/// **用法**
///
/// ```bash
/// swift run Mine2000 --render-snapshots [输出目录]
/// ```
///
/// 默认输出到 `docs/research/渲染验证/`。
/// ────────────────────────────────────────────────────────────────────────
public enum RenderSnapshots {

    /// 默认输出目录（相对于包根目录）。
    public static var defaultOutputDirectory: URL {
        URL(fileURLWithPath: #filePath)          // Sources/Mine2000/App/RenderSnapshots.swift
            .deletingLastPathComponent()        // App
            .deletingLastPathComponent()        // Mine2000
            .deletingLastPathComponent()        // Sources
            .deletingLastPathComponent()        // 移植实现
            .appendingPathComponent("docs/research/渲染验证", isDirectory: true)
    }

    /// 渲染全部 5 档难度。
    ///
    /// 每张图都是 **HUD + 棋盘** 的合成图，且棋盘刻意做成「有内容」的状态：
    /// 已翻开的数字格、插了旗的格子、踩雷后揭示的地雷，
    /// 以便肉眼验证「图集切块 → 贴图 → HUD 绘制」整条链路。
    ///
    /// - Parameter outputDirectory: PNG 输出目录。
    /// - Throws: 图集加载失败或写文件失败。
    public static func renderAll(to outputDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )

        // AppKit 在离屏渲染时需要一个 NSApplication 实例（但不激活 GUI）
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let renderer = try TileRenderer()

        for difficulty in Difficulty.allCases {
            let url = outputDirectory
                .appendingPathComponent("难度_\(difficulty.menuTitle).png")

            // 棋盘用固定种子，保证每次渲染结果一致、便于回归对比
            let board = Board(difficulty: difficulty, generator: SeededGenerator(seed: 20_240_917))
            // 摆一个有代表性的局面，使数字 / 红旗 / 地雷三类图块同时出现
            dressBoardForRendering(board)

            let image = try renderHUDAndBoard(board: board, renderer: renderer)
            try writePNG(image, to: url)
            print("已渲染 \(url.lastPathComponent)  (\(image.size.width)×\(image.size.height))")
        }

        // 额外渲染一张「进行中」的展示图：不踩雷、笑脸正常，
        // 用于 README / 文档首图（上面五张刻意踩雷，是为了兜出全部图块）
        let showcaseBoard = Board(
            difficulty: .expert,
            generator: SeededGenerator(seed: 20_261_022)
        )
        dressBoardForRendering(showcaseBoard, revealMine: false)
        let showcaseImage = try renderHUDAndBoard(board: showcaseBoard, renderer: renderer)
        let showcaseURL = outputDirectory.appendingPathComponent("展示_进行中.png")
        try writePNG(showcaseImage, to: showcaseURL)
        print("已渲染 \(showcaseURL.lastPathComponent)  (\(showcaseImage.size.width)×\(showcaseImage.size.height))")

        // 额外渲染一张「游戏进行中」的 HUD 快照，展示表情与计时器
        try renderHUDAndBoard(renderer: renderer, to: outputDirectory)
    }

    /// 把棋盘摆成一个「能看出所有图块」的演示局面。
    ///
    /// 目标：让同一张图里同时出现
    /// **未翻开格 / 翻开后的数字 / 红旗 / 地雷**（外加 HUD 的笑脸与数码管）。
    ///
    /// 全部走公开 API，不触碰棋盘内部状态：
    /// 1. 首击翻开一片区域 → 出现数字格；
    /// 2. 在若干未翻开的非雷格插旗 → 出现红旗；
    /// 3. 故意踩一颗雷 → 进入失败态，渲染层会揭示全部地雷 → 出现地雷图块。
    ///
    /// - Parameter revealMine: 是否踩雷进入失败态。
    ///   设为 `false` 时停在「进行中」，用于生成 README 展示图（笑脸保持正常）。
    static func dressBoardForRendering(_ board: Board, revealMine: Bool = true) {
        if revealMine {
            // 1) 首击展开，产生数字格
            board.reveal(row: 0, column: 0)
        } else {
            // 展示图：优先点「0 格」（周围 8 邻无雷），flood fill 能一次展开一大片，
            // 画面才有真实对局的样子；否则专家盘雷密度高，点一格只翻开一格。
            for _ in 0..<6 {
                guard let spot = firstZeroCell(board) else { break }
                board.reveal(row: spot.row, column: spot.column)
            }
        }

        // 2) 插几面旗（只插在未翻开的非雷格上，保证旗子可见）
        var flags = 0
        for row in 0..<board.rows where flags < 3 {
            for column in 0..<board.columns where flags < 3 {
                guard let cell = board.cell(row: row, column: column) else { continue }
                guard !cell.isRevealed, !cell.containsMine else { continue }
                board.toggleFlag(row: row, column: column)
                flags += 1
            }
        }

        guard revealMine else { return }

        // 3) 踩一颗雷 → 失败态（渲染层会揭示全部地雷）
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                guard let cell = board.cell(row: row, column: column) else { continue }
                if cell.containsMine, !cell.isFlagged, !cell.isRevealed {
                    board.reveal(row: row, column: column)
                    return
                }
            }
        }
    }

    /// 找一个尚未翻开、且 8 邻全无雷的格子（即扫雷里的「0 格」）。
    ///
    /// 点这种格子会触发 flood fill，一次展开一大片，最适合生成展示图。
    private static func firstZeroCell(_ board: Board) -> (row: Int, column: Int)? {
        for row in 0..<board.rows {
            for column in 0..<board.columns {
                guard let cell = board.cell(row: row, column: column),
                      !cell.containsMine, !cell.isRevealed else { continue }

                var clear = true
                for dr in -1...1 {
                    for dc in -1...1 where !(dr == 0 && dc == 0) {
                        let r = row + dr
                        let c = column + dc
                        guard r >= 0, r < board.rows, c >= 0, c < board.columns else { continue }
                        if board.cell(row: r, column: c)?.containsMine == true {
                            clear = false
                        }
                    }
                }
                if clear { return (row, column) }
            }
        }
        return nil
    }

    /// 把 HUD 与棋盘叠在一起离屏渲染成一张图。
    ///
    /// - Parameters:
    ///   - board: 要渲染的棋盘。
    ///   - renderer: 图集渲染器。
    /// - Returns: 合成后的图像（HUD 在上、棋盘在下）。
    private static func renderHUDAndBoard(
        board: Board,
        renderer: TileRenderer
    ) throws -> NSImage {
        let boardView = BoardView(board: board, renderer: renderer)
        boardView.frame = NSRect(
            x: 0, y: 0,
            width: CGFloat(board.columns * Difficulty.cellSize),
            height: CGFloat(board.rows * Difficulty.cellSize)
        )

        let hud = HUDView(renderer: renderer)
        hud.frame = NSRect(
            x: 0, y: 0,
            width: CGFloat(board.columns * Difficulty.cellSize),
            height: CGFloat(HUDView.height)
        )
        hud.remainingMines = board.remainingMines
        // 固定用时值，保证渲染结果可复现
        hud.elapsedDeciseconds = 123
        hud.expression = board.state == .lost ? .lose : .normal

        // 用一个容器视图把 HUD 叠在棋盘上方
        let container = NSView(frame: NSRect(
            x: 0, y: 0,
            width: CGFloat(board.columns * Difficulty.cellSize),
            height: CGFloat(HUDView.height + board.rows * Difficulty.cellSize)
        ))
        boardView.frame = NSRect(
            x: 0, y: 0,
            width: boardView.frame.width,
            height: boardView.frame.height
        )
        hud.frame = NSRect(
            x: 0, y: boardView.frame.height,
            width: hud.frame.width,
            height: hud.frame.height
        )
        container.addSubview(boardView)
        container.addSubview(hud)
        container.layoutSubtreeIfNeeded()

        return try offscreenImage(of: container)
    }

    /// 渲染一张包含 HUD + 棋盘的组合图。
    ///
    /// 用于验证「表情 + 计时器 + 剩余雷数」这条 HUD 绘制链路。
    private static func renderHUDAndBoard(renderer: TileRenderer, to outputDirectory: URL) throws {
        let board = Board(difficulty: .middle, generator: SeededGenerator(seed: 20_240_918))
        // 翻开一些格子，让棋盘有内容
        board.reveal(row: 0, column: 0)
        board.reveal(row: 1, column: 1)

        let image = try renderHUDAndBoard(board: board, renderer: renderer)
        let url = outputDirectory.appendingPathComponent("HUD_中級_组合.png")
        try writePNG(image, to: url)
        print("已渲染 \(url.lastPathComponent)  (\(image.size.width)×\(image.size.height))")
    }

    /// 把视图离屏渲染成 `NSImage`。
    private static func offscreenImage(of view: NSView) throws -> NSImage {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw RenderError.cannotCreateBitmap
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// 把 `NSImage` 写成 PNG。
    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.cannotEncodePNG
        }
        try png.write(to: url)
    }

    /// 渲染错误。
    public enum RenderError: Error, CustomStringConvertible {
        case cannotCreateBitmap
        case cannotEncodePNG

        public var description: String {
            switch self {
            case .cannotCreateBitmap: return "无法创建离屏位图"
            case .cannotEncodePNG: return "无法编码为 PNG"
            }
        }
    }
}

/// 确定性随机源：让渲染结果可复现。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed &* 6364136223846793005 &+ 1442695040888963407
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2685821657736338717
    }
}
