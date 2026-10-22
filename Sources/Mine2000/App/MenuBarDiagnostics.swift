import AppKit
import ApplicationServices
import Foundation

/// 菜单栏诊断工具。
///
/// ## 为什么需要它
///
/// AppKit 对 `NSMenu` 顶级项的处理有一条**未公开且反直觉**的规则：
/// **没有 `submenu` 的顶级项会被静默丢弃**。
/// 丢弃后，`mainMenu.items[0]` 变成下一个菜单（例如「ゲーム」），
/// 而 macOS 菜单栏**最左侧的加粗槽位永远渲染 `items[0]`**——
/// 于是「ゲーム」被当成 App 菜单显示，真正的应用名彻底不出现，
/// 且系统自带的 App 菜单（关于 / 隐藏 / 退出）也不存在。
///
/// 这个 bug 只在**真实渲染后**才暴露，而 `NSMenu` 对象的 `items` 数组
/// 无论被不被丢弃都保持原样 —— 也就是说，
/// **只读 `mainMenu.items` 是看不出问题的**，必须看系统实际渲染的结果。
///
/// ## 判据
///
/// `NSApplication` 有一个私有 selector `accessibilityMenuBarAttribute`，
/// 指向本进程在**系统菜单栏**中的 AX 元素。
/// 通过 AXAPI 读它的 children，得到的就是系统真实渲染出来的菜单项标题序列。
///
/// - 期望：第一个元素的标题 = 应用名（`L10n.appName`，即「扫雷 2000」）
/// - 故障态：第一个元素的标题 = `ゲーム`（说明占位项被丢弃）
enum MenuBarDiagnostics {

    /// AX 读取菜单项标题。
    private static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        return text
    }

    /// AX 读取子元素。
    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    /// CFTypeRef → AXUIElement 的强制桥接。
    ///
    /// Swift 6 严格并发检查下，`CFTypeRef`（= `AnyObject`）到 `AXUIElement`
    /// 的条件转换会被判定为「恒成功」而报错，无条件转换又不被允许。
    /// AXUIElement 是 CF class-like 类型，用 `unsafeBitCast` 桥接是标准做法。
    private static func asAXElement(_ value: CFTypeRef) -> AXUIElement {
        unsafeBitCast(value, to: AXUIElement.self)
    }

    /// 读取系统真实渲染的菜单栏标题序列。
    ///
    /// - Returns: 标题数组；读取失败时返回 `nil`。
    static func renderedMenuBarTitles() -> [String]? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, "AXMenuBar" as CFString, &value)
        guard error == .success, let raw = value else { return nil }
        let menuBar = asAXElement(raw)
        return children(of: menuBar).compactMap { title(of: $0) }
    }

    /// 把诊断结果打印到标准输出。
    static func dump() {
        let titles = renderedMenuBarTitles()
        guard let titles else {
            print("[菜单栏诊断] 无法通过 AX 读取系统菜单栏（可能缺少辅助功能权限）")
            return
        }
        print("[菜单栏诊断] 系统真实渲染的菜单栏标题：\(titles)")
        // ⚠️ 首项是系统自带的「Apple」菜单，不是我们的 App 菜单。
        // 我们的应用名应当出现在紧随其后的位置。
        // 故障态（占位项被 AppKit 丢弃）时，列表会是 ["Apple", "游戏", "帮助"]。
        // ⚠️ 2026-10-22 起界面已本地化为中文，期望值同步更新。
        let expected = ["Apple", L10n.appName, "游戏", "帮助"]
        if titles == expected {
            print("[菜单栏诊断] ✅ 应用名正常显示在菜单栏最左（紧随 Apple 菜单）")
        } else {
            print("[菜单栏诊断] ❌ 菜单栏结构不符，期望 \(expected)，实际 \(titles)")
        }
    }
}
