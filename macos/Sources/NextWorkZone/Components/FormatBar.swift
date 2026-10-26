import SwiftUI

/// 编辑器的格式栏：按功能分成几组玻璃胶囊，浮在正文上方（正文滚到下面时透过玻璃隐约可见）。
/// 组与组靠得近时玻璃会融在一起，出现、消失的组（例如表格操作）带融合动画。
struct FormatBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 6) { content() }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 格式栏中的一组按钮。
struct FormatGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .glassEffect(.regular, in: Capsule())
    }
}

/// 格式栏中的图标按钮：开启的格式（粗体、当前列表等）显示选中底色。
struct FormatButton: View {
    var icon: String
    var title: String
    var active = false
    var disabled = false
    var action: () -> Void

    init(_ icon: String, _ title: String, _ active: Bool = false, disabled: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.active = active
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 26, height: 24)
                .selectionBackground(active, radius: 12)
        }
        .help(title)
        .disabled(disabled)
    }
}

/// 格式栏中的文字按钮（标题级别、表格操作）。
struct FormatTextButton: View {
    var label: String
    var title: String?
    var active = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 5)
                .frame(minWidth: 26, minHeight: 24)
                .selectionBackground(active, radius: 12)
        }
        .help(title ?? label)
    }
}
