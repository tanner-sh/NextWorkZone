import SwiftUI

/// 页面在窗口标题栏中的部分：工具栏按钮和副标题。
///
/// 保留的页面（见 KeptPages）隐藏后仍然会向窗口提供工具栏项目，所以不显示的页面把自己的项目隐藏起来。
/// 隐藏而不是去掉：去掉的话每次切换页面都要重新创建这些项目，切换一次多花 50 毫秒左右。
/// `ToolbarSpacer` 不受 `hidden` 影响，但隐藏页面的间隔落在中间的弹性空白里，看不出来；
/// 也不要按页面是否显示加减间隔，那样每次切换整条工具栏都会重建。
/// 醒目的按钮用 `.borderedProminent`（工具栏中显示为着色的玻璃）；`.glassProminent` 放在工具栏中会让整个窗口的内容画不出来。
/// 标题由 RootView 按当前页面统一设置（几个页面都设置标题时，窗口显示的是最后更新的那个，不一定是正在显示的页面）。
private struct PageToolbar<Items: ToolbarContent>: ViewModifier {
    @Environment(\.pageActive) private var active
    let items: () -> Items

    func body(content: Content) -> some View {
        content.toolbar {
            items().hidden(!active)
        }
    }
}

/// 各页面的副标题（例如“4 条”），显示在窗口标题下方。
@MainActor @Observable
final class PageTitles {
    static let shared = PageTitles()
    var subtitles: [PageID: String] = [:]
}

extension View {
    /// 页面的工具栏按钮：页面显示时才出现在窗口工具栏中。
    func pageToolbar<Items: ToolbarContent>(@ToolbarContentBuilder _ items: @escaping () -> Items) -> some View {
        modifier(PageToolbar(items: items))
    }

    /// 页面的副标题：显示在窗口标题下方，空字符串表示不显示。
    func pageSubtitle(_ page: PageID, _ text: String) -> some View {
        onChange(of: text, initial: true) { _, t in
            if PageTitles.shared.subtitles[page] != t { PageTitles.shared.subtitles[page] = t }
        }
    }
}
