import AppKit

/// 富文本编辑：NSTextView 中的内容与文档模型之间的转换。
enum RichEditor {
    /// 段落所在的层级（从外到内）。
    enum Level: Hashable {
        case quote
        case panel(String, String)
        case listItem(ordered: Bool, task: RichTask?)
        case cell(row: Int, col: Int, head: Bool, colspan: Int, rowspan: Int)
    }

    enum Kind: Hashable {
        case para
        case heading(Int)
        case code(String)
        case rule
        case opaque(RichOpaque)
        case marker(Int)
        /// 列表项的第一个段落（前面有列表标记）
        case itemFirst
        case panelTitle
    }

    /// 段落所属的块。
    final class BlockInfo: NSObject {
        let kind: Kind
        let path: [Level]

        init(kind: Kind, path: [Level]) {
            self.kind = kind
            self.path = path
        }
    }

    /// 行内的特殊内容（问题、提及、占位块等），整体作为一个单元。
    final class InlineBox: NSObject {
        let inline: RichInline
        init(_ inline: RichInline) { self.inline = inline }
    }
}
