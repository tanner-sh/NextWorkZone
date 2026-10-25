import AppKit
import SwiftUI

/// 左右分栏：左栏宽度可以拖动分隔条调整，并按 `key` 记住。
///
/// 不用 HSplitView：页面切走后保留但隐藏时，它会把分隔条重置到左栏最小宽度，切回来时先经过一个很窄的宽度再恢复，
/// 右栏宽度每次切换都变化两三次，其中的长文（例如长 Wiki 页面）每次都要整篇重新排版，切换一次要几百毫秒。
struct SplitPane<Leading: View, Trailing: View>: View {
    private let key: String
    private let minWidth: CGFloat
    private let maxWidth: CGFloat
    /// 右栏至少保留的宽度
    private let trailingMin: CGFloat
    private let leading: Leading
    private let trailing: Trailing
    @State private var width: CGFloat
    @State private var dragStart: CGFloat?
    @State private var hovering = false

    init(_ key: String, minWidth: CGFloat, idealWidth: CGFloat, maxWidth: CGFloat, trailingMin: CGFloat = 480, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.key = key
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.trailingMin = trailingMin
        self.leading = leading()
        self.trailing = trailing()
        let saved = (AppPreferences.shared.object(forKey: "nextworkzone.split.\(key)") as? Double).map { CGFloat($0) }
        _width = State(initialValue: min(max(saved ?? idealWidth, minWidth), maxWidth))
    }

    var body: some View {
        GeometryReader { geo in
            // 窗口较窄时先压缩左栏，保证右栏的最小宽度
            let shown = max(minWidth, min(width, geo.size.width - trailingMin - 1))
            HStack(spacing: 0) {
                leading.frame(width: shown).frame(maxHeight: .infinity)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .overlay {
                        // 可拖动的区域比分隔线宽一些
                        Color.clear
                            .frame(width: 9)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                guard inside != hovering else { return }
                                hovering = inside
                                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { value in
                                        let start = dragStart ?? shown
                                        dragStart = start
                                        width = min(max(start + value.translation.width, minWidth), maxWidth)
                                    }
                                    .onEnded { _ in
                                        dragStart = nil
                                        AppPreferences.shared.set(Double(width), forKey: "nextworkzone.split.\(key)")
                                    }
                            )
                    }
                trailing.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
    }
}
