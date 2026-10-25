import Foundation

public enum RichEdit {
    public struct Segment: Codable, Hashable, Sendable {
        public var source: String
        public var count: Int
        public init(source: String, count: Int) { self.source = source; self.count = count }
    }
    public struct Load: Codable, Hashable, Sendable {
        public var doc: RichDoc
        public var segments: [Segment]
        public init(doc: RichDoc, segments: [Segment]) { self.doc = doc; self.segments = segments }
    }

    public static func load(_ html: String) -> Load {
        var splitter = Splitter()
        splitter.split(html)
        if !splitter.pending.isEmpty {
            if splitter.segments.isEmpty { splitter.segments.append(.init(source: splitter.pending, count: 0)) }
            else { splitter.segments[splitter.segments.count - 1].source += splitter.pending }
        }
        return Load(doc: RichDoc(blocks: splitter.blocks), segments: splitter.segments)
    }

    public static func xhtml(segments: [Segment], baseline: RichDoc, edited: RichDoc) -> String {
        guard segments.allSatisfy({ $0.count >= 0 }), segments.map(\.count).reduce(0, +) == baseline.blocks.count else { return XHTML.write(edited) }
        if baseline == edited { return segments.map(\.source).joined() }
        let base = baseline.blocks, new = edited.blocks
        // CollectionDifference 使用 Myers 对齐，避免整页替换时分配平方大小的矩阵。
        let difference = new.difference(from: base)
        var removed: Set<Int> = [], inserted: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        let remaining = base.indices.filter { !removed.contains($0) }
        var matched: [Int?] = Array(repeating: nil, count: new.count), n = 0
        for i in new.indices where !inserted.contains(i) { matched[i] = remaining[n]; n += 1 }
        var segmentOf: [Int] = [], starts: [Int] = []
        for (s, segment) in segments.enumerated() {
            starts.append(segmentOf.count)
            segmentOf += Array(repeating: s, count: segment.count)
        }
        var out = "", e = 0
        while e < new.count {
            if let b = matched[e] {
                let s = segmentOf[b], count = segments[s].count
                if b == starts[s], (0..<count).allSatisfy({ e + $0 < new.count && matched[e + $0] == b + $0 }) {
                    out += segments[s].source
                    e += count
                    continue
                }
            }
            out += XHTML.write(RichDoc(blocks: [new[e]]))
            e += 1
        }
        return out
    }

    private static func container(_ doc: MarkupSource, _ i: Int) -> Bool {
        ["div", "span"].contains(doc.tokens[i].name) && (MarkupSource.rawAttribute(doc.tag(i), "class") ?? "").split(separator: " ").contains("nwz-container")
    }

    public static func placeholders(_ source: String) -> String {
        guard let doc = try? MarkupSource(source, html: true) else { return source }
        var out = "", pos = 0, i = 0
        while i < doc.tokens.count {
            let t = doc.tokens[i]
            if t.kind == .start, let close = t.close {
                if let n = MarkupSource.rawAttribute(doc.tag(i), "data-nwz") {
                    out += doc.string(pos..<t.span.lowerBound) + "<!--nwz:\(n)-->"
                    pos = doc.tokens[close].span.upperBound; i = close + 1
                    continue
                }
                if container(doc, i) {
                    let open = MarkupSource.rawAttribute(doc.tag(i), "data-nwz-open") ?? ""
                    let end = MarkupSource.rawAttribute(doc.tag(i), "data-nwz-close") ?? ""
                    out += doc.string(pos..<t.span.lowerBound) + "<!--nwz:\(open)-->" + placeholders(doc.string(doc.inner(i))) + "<!--nwz:\(end)-->"
                    pos = doc.tokens[close].span.upperBound; i = close + 1
                    continue
                }
            }
            i += 1
        }
        return out + doc.string(pos..<doc.bytes.count)
    }

    private struct Splitter {
        var blocks: [RichBlock] = []
        var segments: [Segment] = []
        var pending = ""
        static let blockTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table", "div", "blockquote", "pre", "hr"]

        mutating func push(_ source: String, _ produced: [RichBlock]) {
            guard !produced.isEmpty else { pending += source; return }
            segments.append(Segment(source: pending + source, count: produced.count))
            pending = ""
            blocks += produced
        }
        mutating func pushHTML(_ html: String) {
            if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pending += html }
            else { push(placeholders(html), HTML.parse(html).blocks) }
        }
        mutating func split(_ html: String) {
            guard let doc = try? MarkupSource(html, html: true) else { pushHTML(html); return }
            var pos = 0, i = 0, run: Int?
            while i < doc.tokens.count {
                let t = doc.tokens[i]
                let isTag = t.kind == .start || t.kind == .empty
                let block = isTag && Self.blockTags.contains(t.name) && MarkupSource.rawAttribute(doc.tag(i), "data-nwz") == nil
                if !block {
                    if run == nil { run = pos }
                    pos = doc.outer(i).upperBound
                    i = (t.close ?? i) + 1
                    continue
                }
                pushHTML(doc.string((run ?? pos)..<t.span.lowerBound))
                run = nil
                if container(doc, i) {
                    if let n = MarkupSource.rawAttribute(doc.tag(i), "data-nwz-open").flatMap(Int.init) { push("<!--nwz:\(n)-->", [.marker(n)]) }
                    split(doc.string(doc.inner(i)))
                    if let n = MarkupSource.rawAttribute(doc.tag(i), "data-nwz-close").flatMap(Int.init) { push("<!--nwz:\(n)-->", [.marker(n)]) }
                } else { pushHTML(doc.string(doc.outer(i))) }
                pos = doc.outer(i).upperBound
                i = (t.close ?? i) + 1
            }
            pushHTML(doc.string((run ?? pos)..<doc.bytes.count))
        }
    }
}
