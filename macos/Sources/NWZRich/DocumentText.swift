import Foundation

extension RichDoc {
    public var plainText: String {
        var lines: [String] = []
        walk { block in
            switch block {
            case .para(let content), .heading(_, let content, _): lines.append(RichInline.plain(content))
            case .code(_, let text): lines.append(text)
            case .opaque(let value): lines.append(value.label)
            default: break
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public mutating func absolutize(baseURL: String) {
        func fix(_ value: String) -> String { value.hasPrefix("/") && !value.hasPrefix("//") ? baseURL + value : value }
        func inline(_ values: [RichInline]) -> [RichInline] {
            values.map { value in
                switch value {
                case .text(let text, let marks, let link, let color): return .text(text, marks, link: link.map(fix), color: color)
                case .image(var image):
                    image.src = fix(image.full ?? image.src); image.full = nil
                    return .image(image)
                default: return value
                }
            }
        }
        func convert(_ values: [RichBlock]) -> [RichBlock] {
            values.map { block in
                switch block {
                case .para(let content): .para(inline(content))
                case .heading(let level, let content, let id): .heading(level: level, inline(content), id: id)
                case .list(let ordered, let start, let items): .list(ordered: ordered, start: start, items: items.map { .init(task: $0.task, blocks: convert($0.blocks)) })
                case .quote(let nested): .quote(convert(nested))
                case .panel(let kind, let title, let nested): .panel(kind: kind, title: title, blocks: convert(nested))
                case .table(let rows): .table(rows.map { row in .init(cells: row.cells.map { .init(head: $0.head, blocks: convert($0.blocks), colspan: $0.colspan, rowspan: $0.rowspan) }) })
                default: block
                }
            }
        }
        blocks = convert(blocks)
    }
}
