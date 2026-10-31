import SwiftUI

/// 界面的统一外观：圆角、底色，以及筛选框、分组卡片这类常用样式。
///
/// 玻璃（`.glassEffect`）只用于浮在内容上的一层：窗口工具栏、⌘K、提示条、浮动面板、编辑器的格式栏；
/// 正文、列表、卡片用这里的淡色底，不用玻璃（整片玻璃上的文字不好读）。
enum Theme {
    /// 输入框、小标签、代码块等控件的圆角
    static let controlRadius: CGFloat = 8
    /// 卡片、分组的圆角
    static let cardRadius: CGFloat = 12
    /// 浮动面板（⌘K、剪贴板面板、快速记录窗口）的圆角
    static let panelRadius: CGFloat = 22

    /// 输入区域（筛选框、多行输入框）的底色
    static var fieldFill: some ShapeStyle { .quaternary.opacity(0.5) }
    /// 分组、卡片的底色
    static var groupFill: some ShapeStyle { .quaternary.opacity(0.35) }
    /// 小标签（分支名、已选项）的底色
    static var chipFill: some ShapeStyle { .quaternary.opacity(0.6) }

    /// 浮动面板的外形
    static var panelShape: RoundedRectangle { RoundedRectangle(cornerRadius: panelRadius) }

    /// 与所在容器（浮动面板、窗口、表单）同心的圆角：离容器边缘越近，圆角越接近容器的圆角减去间距，
    /// 离得远的不小于 `minimum`。手算“面板圆角 − 内边距”在改了内边距后就对不上了，交给系统算。
    static func concentric(minimum: CGFloat = controlRadius) -> ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(minimum)), isUniform: true)
    }
}

extension View {
    /// 浮动面板（⌘K、剪贴板面板、快速记录窗口）：玻璃底，并把面板的外形告诉其中的内容，
    /// 里面用 `Theme.concentric()` 的选中底色、卡片随面板圆角同心。
    func floatingPanel(_ glass: Glass = .regular) -> some View {
        containerShape(Theme.panelShape)
            .glassEffect(glass, in: Theme.panelShape)
    }
}

/// 淡色底：开启“增强对比度”时加深并加一圈分隔线（玻璃由系统处理，这里只管自己画的底色）。
private struct ThemeFill<S: Shape>: ViewModifier {
    var style: AnyShapeStyle
    var opacity: Double
    var shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let high = contrast == .increased
        content.background {
            shape.fill(style.opacity(high ? min(opacity * 2.5, 1) : opacity))
                .overlay { if high { shape.stroke(Color(nsColor: .separatorColor)) } }
        }
    }
}

extension View {
    /// 输入区域的底色：多行输入框、自己画的输入框。
    func fieldBackground() -> some View {
        modifier(ThemeFill(style: AnyShapeStyle(.quaternary), opacity: 0.5, shape: RoundedRectangle(cornerRadius: Theme.controlRadius)))
    }

    /// 分组、卡片的底色。
    func groupBackground(radius: CGFloat = Theme.cardRadius) -> some View {
        modifier(ThemeFill(style: AnyShapeStyle(.quaternary), opacity: 0.35, shape: RoundedRectangle(cornerRadius: radius)))
    }

    /// 带颜色的分组底色（未读、新评论、已解决等需要区分的分组）；`tint` 为 nil 时与 `groupBackground` 相同。
    func groupBackground(tint: Color?, radius: CGFloat = Theme.cardRadius) -> some View {
        modifier(ThemeFill(style: tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.quaternary), opacity: tint == nil ? 0.35 : 0.07, shape: RoundedRectangle(cornerRadius: radius)))
    }

    /// 提示、警告、错误条的底色。
    func noticeBackground(_ tint: Color) -> some View {
        modifier(ThemeFill(style: AnyShapeStyle(tint), opacity: 0.1, shape: RoundedRectangle(cornerRadius: Theme.cardRadius)))
    }

    /// 小标签的胶囊底色。
    func chipBackground() -> some View {
        modifier(ThemeFill(style: AnyShapeStyle(.quaternary), opacity: 0.6, shape: Capsule()))
    }

    /// 选中项的底色（候选列表、格式按钮的开启状态）。
    func selectionBackground(_ selected: Bool, radius: CGFloat = 6) -> some View {
        background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: radius))
    }
}

extension View {
    /// 贴在列表顶上的筛选框、输入框：列表可以滚到它们下面，滚过去的内容由系统渐隐（滚动边缘效果）。
    /// `inset`：左右留白（列表本身占满宽度时与列表行对齐）。
    func listHeader(inset: CGFloat = 0, @ViewBuilder _ content: () -> some View) -> some View {
        scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaBar(edge: .top) {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, inset)
                    .padding(.bottom, 8)
            }
    }
}

/// 页面内的筛选、搜索框：放大镜（加载中时为进度圈）、输入框、有内容时的清除按钮，胶囊形底色。
struct FilterField: View {
    var prompt: String
    @Binding var text: String
    var loading = false
    var focus: FocusState<Bool>.Binding? = nil
    /// 右侧的说明，例如列表条数
    var trailing = ""
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            if loading { ProgressView().controlSize(.small) } else { Image(systemName: "magnifyingglass").foregroundStyle(.secondary) }
            field
            if !trailing.isEmpty {
                Text(trailing).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            if !text.isEmpty {
                Button {
                    text = ""
                    onSubmit?()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清空")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .modifier(ThemeFill(style: AnyShapeStyle(.quaternary), opacity: 0.5, shape: Capsule()))
    }

    @ViewBuilder
    private var field: some View {
        let input = TextField(prompt, text: $text).textFieldStyle(.plain).onSubmit { onSubmit?() }
        if let focus { input.focused(focus) } else { input }
    }
}

extension View {
    /// 刷新按钮加载时图标持续旋转（SF Symbols 的旋转动效）。
    func refreshing(_ active: Bool) -> some View {
        symbolEffect(.rotate, options: .repeat(.continuous), isActive: active)
    }
}
