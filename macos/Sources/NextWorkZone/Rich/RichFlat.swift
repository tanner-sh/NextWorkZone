import AppKit

/// 编辑时的扁平段落：每个段落带着类型和所在的层级（引用、列表项、表格单元格等）。
/// 结构操作（回车、缩进、切换列表或标题、表格增删行列）都在扁平段落上完成，再组装成文档模型重新排版。
struct FlatPara {
    var kind: RichEditor.Kind
    var path: [RichEditor.Level]
    var inl: [RichInline] = []
    /// 代码块的文字
    var code = ""

    static func para(_ path: [RichEditor.Level] = [], _ inl: [RichInline] = []) -> FlatPara {
        FlatPara(kind: .para, path: path, inl: inl)
    }

    /// 内容的长度（与排版后的字符数一致）。
    var contentLength: Int {
        switch kind {
        case .code: return (code as NSString).length
        case .rule, .opaque, .marker: return 0
        default: return RichFlat.length(inl)
        }
    }

    var isEmpty: Bool { contentLength == 0 && !isAtomic }
    var isAtomic: Bool {
        switch kind {
        case .rule, .opaque, .marker: true
        default: false
        }
    }

    /// 最内层的列表项层级的位置。
    var itemDepth: Int? { path.lastIndex { if case .listItem = $0 { true } else { false } } }
    /// 最内层的单元格层级的位置。
    var cellDepth: Int? { path.lastIndex { if case .cell = $0 { true } else { false } } }
}

/// 段落在文字中的位置。
struct ParaSpan {
    var range: NSRange
    /// 内容开始的位置（列表项标记之后）
    var contentStart: Int
    var contentEnd: Int
}

/// 段落中的位置：第几个段落、内容中的偏移。
struct FlatPos: Equatable {
    var para: Int
    var offset: Int
}

@MainActor
enum RichFlat {
    // MARK: 文字 → 扁平段落

    /// 按段落拆分文字，读出每段的类型、层级和内容。
    static func parse(_ text: NSAttributedString) -> (paras: [FlatPara], spans: [ParaSpan]) {
        let ns = text.string as NSString
        var paras: [FlatPara] = []
        var spans: [ParaSpan] = []
        var start = 0
        while start < ns.length {
            let nl = ns.range(of: "\n", options: [], range: NSRange(location: start, length: ns.length - start))
            let end = nl.location == NSNotFound ? ns.length : nl.location
            let full = NSRange(location: start, length: (nl.location == NSNotFound ? ns.length : nl.location + 1) - start)
            // 内容开始于列表项标记之后
            var contentStart = start
            while contentStart < end, text.attribute(.nwzPrefix, at: contentStart, effectiveRange: nil) != nil { contentStart += 1 }
            let probe = start < ns.length ? start : max(0, start - 1)
            let info = text.attribute(.nwzBlock, at: probe, effectiveRange: nil) as? RichEditor.BlockInfo
            var p = FlatPara(kind: info?.kind ?? .para, path: info?.path ?? [])
            // 列表项标记被删掉时按普通段落处理
            if case .itemFirst = p.kind, contentStart == start, p.itemDepth != nil {
                p.kind = .para
            }
            let content = NSRange(location: contentStart, length: end - contentStart)
            switch p.kind {
            case .code:
                p.code = ns.substring(with: content).replacingOccurrences(of: "\u{2028}", with: "\n")
            case .rule, .opaque, .marker:
                // 原子块中输入的文字作为下一个段落
                let extra = inlines(text, content).filter { if case .opaque = $0 { false } else if case .marker = $0 { false } else { true } }
                paras.append(p)
                spans.append(ParaSpan(range: full, contentStart: contentStart, contentEnd: end))
                if !extra.isEmpty && RichInline.plain(extra).trimmingCharacters(in: .whitespaces).count > 0 {
                    paras.append(FlatPara.para(p.path, extra))
                    spans.append(ParaSpan(range: NSRange(location: end, length: 0), contentStart: end, contentEnd: end))
                }
                start = full.upperBound
                continue
            default:
                p.inl = inlines(text, content)
            }
            paras.append(p)
            spans.append(ParaSpan(range: full, contentStart: contentStart, contentEnd: end))
            start = full.upperBound
        }
        return (paras, spans)
    }

    /// 一段文字中的行内内容。
    static func inlines(_ text: NSAttributedString, _ range: NSRange) -> [RichInline] {
        var out: [RichInline] = []
        var lastBox: RichEditor.InlineBox?
        let ns = text.string as NSString
        text.enumerateAttributes(in: range) { attrs, r, _ in
            if let box = attrs[.nwzInline] as? RichEditor.InlineBox {
                if box !== lastBox { out.append(box.inline) }
                lastBox = box
                return
            }
            lastBox = nil
            if attrs[.attachment] != nil { return }
            let s = ns.substring(with: r)
            let marks = Marks(rawValue: attrs[.nwzMarks] as? Int ?? 0)
            let link = attrs[.nwzHref] as? String
            let color = attrs[.nwzColor] as? String
            let parts = s.components(separatedBy: "\u{2028}")
            for (i, part) in parts.enumerated() {
                if i > 0 { out.append(.br) }
                if part.isEmpty { continue }
                // 与前一段格式相同时合并
                if case .text(let prev, let m, let l, let c)? = out.last, m == marks, l == link, c == color {
                    out[out.count - 1] = .text(prev + part, marks, link: link, color: color)
                } else {
                    out.append(.text(part, marks, link: link, color: color))
                }
            }
        }
        return out
    }

    nonisolated static func length(_ inl: [RichInline]) -> Int {
        // 与渲染后的字符数一致：只在需要定位时使用，近似即可
        inl.reduce(0) { n, i in
            switch i {
            case .text(let s, _, _, _): n + (s as NSString).length
            case .br: n + 1
            case .issue(let k): n + (k as NSString).length
            case .status(let t, _): n + (t as NSString).length + 2
            case .mention(let name, _): n + (name as NSString).length + 1
            case .attachment(let f): n + (f as NSString).length + 3
            default: n + 1
            }
        }
    }

    // MARK: 扁平段落 → 文档模型

    static func build(_ paras: [FlatPara]) -> RichDoc {
        RichDoc(blocks: build(paras[...], depth: 0))
    }

    /// 单元格位置回到前面（例如下一个表格的第一格）：相邻的两个表格，不能合成一个。
    static func startsNewTable(_ prev: FlatPara, _ next: FlatPara, depth d: Int) -> Bool {
        guard prev.path.count > d, next.path.count > d,
              case .cell(let r1, let c1, _, _, _) = prev.path[d], case .cell(let r2, let c2, _, _, _) = next.path[d] else { return false }
        return r2 < r1 || (r2 == r1 && c2 < c1)
    }

    private static func sameGroup(_ a: RichEditor.Level, _ b: RichEditor.Level) -> Bool {
        switch (a, b) {
        case (.quote, .quote): true
        case let (.panel(k1, t1), .panel(k2, t2)): k1 == k2 && t1 == t2
        case let (.listItem(o1, _), .listItem(o2, _)): o1 == o2
        case (.cell, .cell): true
        default: false
        }
    }

    private static func leaf(_ p: FlatPara) -> RichBlock? {
        switch p.kind {
        case .para, .itemFirst: return .para(p.inl)
        case .heading(let level): return .heading(level: level, p.inl, id: nil)
        case .code(let lang): return .code(lang: lang, text: p.code)
        case .rule: return .rule
        case .opaque(let o): return .opaque(o)
        case .marker(let n): return .marker(n)
        case .panelTitle: return nil
        }
    }

    private static func build(_ paras: ArraySlice<FlatPara>, depth d: Int) -> [RichBlock] {
        var out: [RichBlock] = []
        var i = paras.startIndex
        while i < paras.endIndex {
            let p = paras[i]
            if p.path.count <= d {
                // 相邻的同一个代码块（回车产生的）合并
                if case .code(let lang) = p.kind, case .code(let l2, let t2)? = out.last, lang == l2 {
                    out[out.count - 1] = .code(lang: lang, text: t2 + "\n" + p.code)
                } else if let b = leaf(p) {
                    out.append(b)
                }
                i += 1
                continue
            }
            let level = p.path[d]
            var j = i + 1
            while j < paras.endIndex, paras[j].path.count > d, sameGroup(paras[j].path[d], level), !RichFlat.startsNewTable(paras[j - 1], paras[j], depth: d) { j += 1 }
            let group = paras[i..<j]
            switch level {
            case .quote:
                out.append(.quote(build(group, depth: d + 1)))
            case .panel(let kind, _):
                let title = group.first { $0.path.count == d + 1 && $0.kind == .panelTitle }.map { RichInline.plain($0.inl) } ?? ""
                out.append(.panel(kind: kind, title: title, blocks: build(group.filter { !($0.path.count == d + 1 && $0.kind == .panelTitle) }[...], depth: d + 1)))
            case .listItem(let ordered, _):
                var items: [RichItem] = []
                var k = group.startIndex
                while k < group.endIndex {
                    var e = k + 1
                    while e < group.endIndex, !(group[e].path.count == d + 1 && group[e].kind == .itemFirst) { e += 1 }
                    let first = group[k]
                    var task: RichTask?
                    if case .listItem(_, let t) = first.path[d] { task = t }
                    var blocks: [RichBlock] = []
                    var rest = group[(k + 1)..<e]
                    if first.path.count == d + 1, first.kind == .itemFirst {
                        blocks.append(.para(first.inl))
                    } else {
                        rest = group[k..<e]
                    }
                    blocks += build(rest, depth: d + 1)
                    items.append(RichItem(task: task, blocks: blocks))
                    k = e
                }
                out.append(.list(ordered: ordered, start: 0, items: items))
            case .cell:
                var rows: [Int: [(Int, RichCell)]] = [:]
                var k = group.startIndex
                while k < group.endIndex {
                    guard case .cell(let row, let col, let head, let colspan, let rowspan) = group[k].path[d] else { k += 1; continue }
                    var e = k + 1
                    while e < group.endIndex, case .cell(let r2, let c2, _, _, _) = group[e].path[d], r2 == row, c2 == col { e += 1 }
                    let blocks = build(group[k..<e], depth: d + 1)
                    rows[row, default: []].append((col, RichCell(head: head, blocks: blocks, colspan: colspan, rowspan: rowspan)))
                    k = e
                }
                out.append(.table(rows.keys.sorted().map { r in RichRow(cells: rows[r]!.sorted { $0.0 < $1.0 }.map(\.1)) }))
            }
            i = j
        }
        return out
    }

    // MARK: 文档模型 → 扁平段落（插入粘贴的内容时使用）

    static func flatten(_ blocks: [RichBlock], path: [RichEditor.Level] = []) -> [FlatPara] {
        var out: [FlatPara] = []
        for b in blocks {
            switch b {
            case .para(let inl): out.append(.para(path, inl))
            case .heading(let level, let inl, _): out.append(FlatPara(kind: .heading(level), path: path, inl: inl))
            case .code(let lang, let text): out.append(FlatPara(kind: .code(lang), path: path, code: text))
            case .rule: out.append(FlatPara(kind: .rule, path: path))
            case .opaque(let o): out.append(FlatPara(kind: .opaque(o), path: path))
            case .marker(let n): out.append(FlatPara(kind: .marker(n), path: path))
            case .quote(let bs): out += flatten(bs.isEmpty ? [.para([])] : bs, path: path + [.quote])
            case .panel(let kind, let title, let bs):
                let p = path + [.panel(kind, title)]
                if !title.isEmpty { out.append(FlatPara(kind: .panelTitle, path: p, inl: [.text(title, [], link: nil, color: nil)])) }
                out += flatten(bs.isEmpty ? [.para([])] : bs, path: p)
            case .list(let ordered, _, let items):
                for item in items {
                    let p = path + [.listItem(ordered: ordered, task: item.task)]
                    var bs = item.blocks
                    var first: [RichInline] = []
                    if case .para(let inl) = bs.first {
                        first = inl
                        bs.removeFirst()
                    }
                    out.append(FlatPara(kind: .itemFirst, path: p, inl: first))
                    out += flatten(bs, path: p)
                }
            case .table(let rows):
                for (r, row) in rows.enumerated() {
                    for (c, cell) in row.cells.enumerated() {
                        out += flatten(cell.blocks.isEmpty ? [.para([])] : cell.blocks, path: path + [.cell(row: r, col: c, head: cell.head, colspan: cell.colspan, rowspan: cell.rowspan)])
                    }
                }
            }
        }
        return out
    }

    // MARK: 行内内容的拆分

    /// 在内容偏移处拆成两段。
    static func split(_ inl: [RichInline], at offset: Int) -> ([RichInline], [RichInline]) {
        var left: [RichInline] = []
        var right: [RichInline] = []
        var pos = 0
        for i in inl {
            let len = length([i])
            if pos + len <= offset {
                left.append(i)
            } else if pos >= offset {
                right.append(i)
            } else if case .text(let s, let m, let l, let c) = i {
                let ns = s as NSString
                let cut = offset - pos
                left.append(.text(ns.substring(to: cut), m, link: l, color: c))
                right.append(.text(ns.substring(from: cut), m, link: l, color: c))
            } else {
                left.append(i)
            }
            pos += len
        }
        return (left, right)
    }
}

// MARK: - 结构操作

/// 对扁平段落的修改：返回修改后的段落和新的光标位置。
@MainActor
enum RichOps {
    typealias Result = (paras: [FlatPara], selection: (FlatPos, FlatPos))

    /// 回车：拆分段落。列表项拆成两项，标题末尾回车得到普通段落，空列表项回车退出列表。
    /// `left`、`right` 是光标前后的内容。
    static func newline(_ paras: [FlatPara], at pos: FlatPos, left: [RichInline], right: [RichInline]) -> Result? {
        var ps = paras
        let p = ps[pos.para]
        switch p.kind {
        case .itemFirst where p.isEmpty:
            return lift(ps, range: pos.para...pos.para, caret: pos)
        case .code:
            return nil
        case .rule, .opaque, .marker:
            ps.insert(.para(p.path), at: pos.para + 1)
            let c = FlatPos(para: pos.para + 1, offset: 0)
            return (ps, (c, c))
        default:
            break
        }
        var a = p
        a.inl = left
        var b = p
        b.inl = right
        switch p.kind {
        case .heading:
            if right.isEmpty { b.kind = .para }
            // 在标题开头回车：上面插入空段落
            if left.isEmpty && !right.isEmpty { a.kind = .para }
        case .panelTitle:
            b.kind = .para
        case .itemFirst:
            // 新的列表项：勾选状态清空
            if let d = p.itemDepth, case .listItem(let ordered, let task) = p.path[d] {
                b.path[d] = .listItem(ordered: ordered, task: task.map { _ in RichTask(done: false) })
            }
        default:
            break
        }
        ps[pos.para] = a
        ps.insert(b, at: pos.para + 1)
        let c = FlatPos(para: pos.para + 1, offset: 0)
        return (ps, (c, c))
    }

    /// 代码块最后一个空行回车：退出代码块。
    static func exitCode(_ paras: [FlatPara], at index: Int) -> Result {
        var ps = paras
        ps[index].code = String(ps[index].code.dropLast())
        ps.insert(.para(ps[index].path), at: index + 1)
        let c = FlatPos(para: index + 1, offset: 0)
        return (ps, (c, c))
    }

    /// 列表项所属的段落：从列表项的第一段到下一个同级列表项之前。
    static func itemRange(_ paras: [FlatPara], _ index: Int, depth d: Int) -> Range<Int> {
        var e = index + 1
        while e < paras.count, paras[e].path.count > d + 1 || (paras[e].path.count == d + 1 && paras[e].kind != .itemFirst && sameItemPrefix(paras[e], paras[index], d)) { e += 1 }
        return index..<e
    }

    private static func sameItemPrefix(_ a: FlatPara, _ b: FlatPara, _ d: Int) -> Bool {
        a.path.count > d && b.path.count > d && Array(a.path[..<d]) == Array(b.path[..<d])
    }

    /// 退出最内层的列表（Shift-Tab、空列表项回车、行首退格）。
    static func lift(_ paras: [FlatPara], range: ClosedRange<Int>, caret: FlatPos) -> Result {
        var ps = paras
        var i = range.lowerBound
        while i <= min(range.upperBound, ps.count - 1) {
            guard let d = ps[i].itemDepth, ps[i].kind == .itemFirst, ps[i].path.count == d + 1 else { i += 1; continue }
            let r = itemRange(ps, i, depth: d)
            let parent = ps[i].path[..<d].lastIndex { if case .listItem = $0 { true } else { false } }
            for k in r {
                if let parent {
                    // 成为上一级列表中的一项
                    ps[k].path.remove(at: parent)
                } else {
                    ps[k].path.remove(at: d)
                    if k == i { ps[k].kind = .para }
                }
            }
            i = r.upperBound
        }
        return (ps, (caret, caret))
    }

    /// 缩进：成为上一个列表项的子项（Tab）。
    static func sink(_ paras: [FlatPara], range: ClosedRange<Int>, caret: (FlatPos, FlatPos)) -> Result? {
        var ps = paras
        var changed = false
        var i = range.lowerBound
        while i <= min(range.upperBound, ps.count - 1) {
            guard let d = ps[i].itemDepth, ps[i].kind == .itemFirst, ps[i].path.count == d + 1 else { i += 1; continue }
            let r = itemRange(ps, i, depth: d)
            // 上一个同级列表项
            guard let prev = (0..<i).last(where: { ps[$0].path.count == d + 1 && ps[$0].kind == .itemFirst && Array(ps[$0].path[..<d]) == Array(ps[i].path[..<d]) }),
                  (prev + 1..<i).allSatisfy({ ps[$0].path.count > d }) else { i = r.upperBound; continue }
            let level = ps[prev].path[d]
            for k in r { ps[k].path.insert(level, at: d) }
            changed = true
            i = r.upperBound
        }
        return changed ? (ps, caret) : nil
    }

    /// 标题、正文切换。
    static func setHeading(_ paras: [FlatPara], range: ClosedRange<Int>, level: Int?, caret: (FlatPos, FlatPos)) -> Result {
        var ps = paras
        for i in range {
            switch ps[i].kind {
            case .para, .heading:
                ps[i].kind = level.map { .heading($0) } ?? .para
            default:
                break
            }
        }
        return (ps, caret)
    }

    enum ListKind {
        case bullet, ordered, task
    }

    /// 切换列表：都已是这种列表时取消列表，否则改为（或包进）这种列表。
    static func toggleList(_ paras: [FlatPara], range: ClosedRange<Int>, kind: ListKind, caret: (FlatPos, FlatPos)) -> Result {
        var ps = paras
        func matches(_ p: FlatPara) -> Bool {
            guard let d = p.itemDepth, case .listItem(let ordered, let task) = p.path[d] else { return false }
            switch kind {
            case .bullet: return !ordered && task == nil
            case .ordered: return ordered
            case .task: return task != nil
            }
        }
        let level = RichEditor.Level.listItem(ordered: kind == .ordered, task: kind == .task ? RichTask(done: false) : nil)
        let targets = range.filter { i in
            switch ps[i].kind {
            case .para, .heading, .itemFirst: true
            default: false
            }
        }
        if !targets.isEmpty, targets.allSatisfy({ matches(ps[$0]) }) {
            return lift(ps, range: range, caret: caret.0)
        }
        for i in targets {
            if let d = ps[i].itemDepth, ps[i].kind == .itemFirst {
                // 已是列表项：改变列表类型
                let r = itemRange(ps, i, depth: d)
                for k in r { ps[k].path[d] = level }
            } else if case .itemFirst = ps[i].kind {
                continue
            } else {
                // 列表项中的后续段落也成为新的一项（同一层）
                ps[i].path.append(level)
                ps[i].kind = .itemFirst
            }
        }
        return (ps, caret)
    }

    static func toggleQuote(_ paras: [FlatPara], range: ClosedRange<Int>, caret: (FlatPos, FlatPos)) -> Result {
        var ps = paras
        let all = range.allSatisfy { ps[$0].path.contains(.quote) }
        for i in range {
            if all {
                if let q = ps[i].path.lastIndex(of: .quote) { ps[i].path.remove(at: q) }
            } else if !ps[i].path.contains(.quote) {
                // 列表整体放进引用：引用放在最外层的列表之前
                let at = ps[i].path.firstIndex { if case .listItem = $0 { true } else { false } } ?? ps[i].path.count
                ps[i].path.insert(.quote, at: at)
            }
        }
        return (ps, caret)
    }

    /// 选中的段落合成一个代码块；已是代码块时拆回段落。
    static func toggleCode(_ paras: [FlatPara], range: ClosedRange<Int>) -> Result {
        var ps = paras
        if case .code = ps[range.lowerBound].kind {
            let p = ps[range.lowerBound]
            let lines = p.code.components(separatedBy: "\n")
            ps.replaceSubrange(range.lowerBound...range.lowerBound, with: lines.map { FlatPara.para(p.path, $0.isEmpty ? [] : [.text($0, [], link: nil, color: nil)]) })
            let c = FlatPos(para: range.lowerBound, offset: 0)
            return (ps, (c, c))
        }
        let selected = range.filter { !ps[$0].isAtomic }
        let text = selected.map { i -> String in
            if case .code = ps[i].kind { return ps[i].code }
            return RichInline.plain(ps[i].inl)
        }.joined(separator: "\n")
        let first = ps[range.lowerBound]
        var code = FlatPara(kind: .code(""), path: first.path)
        code.code = text
        if first.kind == .itemFirst {
            // 列表项中的代码块：放在该项的第一段之后
            ps.replaceSubrange(range, with: [FlatPara(kind: .itemFirst, path: first.path), code])
            let c = FlatPos(para: range.lowerBound + 1, offset: (text as NSString).length)
            return (ps, (c, c))
        }
        ps.replaceSubrange(range, with: [code])
        let c = FlatPos(para: range.lowerBound, offset: (text as NSString).length)
        return (ps, (c, c))
    }

    /// 在段落之后插入（表格、分隔线），后面保证有一个可以继续输入的段落。
    static func insertAfter(_ paras: [FlatPara], index: Int, _ blocks: [FlatPara], caretAt: Int) -> Result {
        var ps = paras
        var insert = blocks
        let path = ps.indices.contains(index) ? Array(ps[index].path.prefix { if case .cell = $0 { false } else { true } }) : []
        // 插入的位置：当前段落为空的普通段落时替换它
        var at = index + 1
        if ps.indices.contains(index), ps[index].isEmpty, ps[index].kind == .para {
            at = index
            ps.remove(at: index)
        }
        insert = insert.map { var p = $0; p.path = path + p.path; return p }
        if !(ps.indices.contains(at) && ps[at].kind == .para && ps[at].path == path) {
            insert.append(.para(path))
        }
        ps.insert(contentsOf: insert, at: min(at, ps.count))
        let c = FlatPos(para: at + caretAt, offset: 0)
        return (ps, (c, c))
    }

    static func table(rows: Int, cols: Int) -> [FlatPara] {
        (0..<rows).flatMap { r in (0..<cols).map { c in FlatPara.para([.cell(row: r, col: c, head: r == 0, colspan: 1, rowspan: 1)]) } }
    }

    // MARK: 表格

    enum TableOp {
        case addRow, addCol, deleteRow, deleteCol, deleteTable
    }

    /// 当前段落所在表格的范围和单元格层级的位置。
    static func tableExtent(_ paras: [FlatPara], _ index: Int) -> (Range<Int>, Int)? {
        guard let d = paras[index].cellDepth else { return nil }
        let prefix = Array(paras[index].path[..<d])
        func inTable(_ p: FlatPara) -> Bool {
            guard p.path.count > d, Array(p.path[..<d]) == prefix, case .cell = p.path[d] else { return false }
            return true
        }
        var a = index
        while a > 0, inTable(paras[a - 1]), !RichFlat.startsNewTable(paras[a - 1], paras[a], depth: d) { a -= 1 }
        var b = index + 1
        while b < paras.count, inTable(paras[b]), !RichFlat.startsNewTable(paras[b - 1], paras[b], depth: d) { b += 1 }
        return (a..<b, d)
    }

    static func table(_ paras: [FlatPara], at index: Int, _ op: TableOp) -> Result? {
        guard let (range, d) = tableExtent(paras, index), case .cell(let row, let col, _, _, _) = paras[index].path[d] else { return nil }
        var ps = paras
        let prefix = Array(paras[index].path[..<d])
        func cell(_ p: FlatPara) -> (Int, Int, Bool) {
            if case .cell(let r, let c, let h, _, _) = p.path[d] { return (r, c, h) }
            return (0, 0, false)
        }
        func setCell(_ p: inout FlatPara, _ r: Int, _ c: Int, _ h: Bool) {
            p.path[d] = .cell(row: r, col: c, head: h, colspan: 1, rowspan: 1)
        }
        var table = Array(ps[range])
        let cols = (table.map { cell($0).1 }.max() ?? 0) + 1
        let rows = (table.map { cell($0).0 }.max() ?? 0) + 1
        var caret = FlatPos(para: index, offset: 0)
        switch op {
        case .deleteTable:
            ps.removeSubrange(range)
            if ps.isEmpty { ps = [.para()] }
            let c = FlatPos(para: min(range.lowerBound, ps.count - 1), offset: 0)
            return (ps, (c, c))
        case .addRow:
            for i in table.indices where cell(table[i]).0 > row { let (r, c, h) = cell(table[i]); setCell(&table[i], r + 1, c, h) }
            let after = (table.lastIndex { cell($0).0 == row } ?? table.count - 1) + 1
            table.insert(contentsOf: (0..<cols).map { c in FlatPara.para(prefix + [.cell(row: row + 1, col: c, head: false, colspan: 1, rowspan: 1)]) }, at: after)
            caret = FlatPos(para: range.lowerBound + after + min(col, cols - 1), offset: 0)
        case .deleteRow:
            guard rows > 1 else { return RichOps.table(paras, at: index, .deleteTable) }
            table.removeAll { cell($0).0 == row }
            for i in table.indices where cell(table[i]).0 > row { let (r, c, h) = cell(table[i]); setCell(&table[i], r - 1, c, h) }
            caret = FlatPos(para: range.lowerBound + min(table.firstIndex { cell($0).0 == min(row, rows - 2) } ?? 0, table.count - 1), offset: 0)
        case .addCol:
            var out: [FlatPara] = []
            for r in 0..<rows {
                let cells = table.filter { cell($0).0 == r }
                for p in cells {
                    var q = p
                    let (_, c, h) = cell(p)
                    if c > col { setCell(&q, r, c + 1, h) }
                    out.append(q)
                }
                // 新列放在当前列最后一个段落之后
                let head = cells.first.map { cell($0).2 } ?? false
                let newCell = FlatPara.para(prefix + [.cell(row: r, col: col + 1, head: head, colspan: 1, rowspan: 1)])
                if let last = out.lastIndex(where: { cell($0).0 == r && cell($0).1 <= col }) {
                    out.insert(newCell, at: last + 1)
                } else {
                    out.append(newCell)
                }
            }
            table = out
            caret = FlatPos(para: range.lowerBound + (table.firstIndex { cell($0).0 == row && cell($0).1 == col + 1 } ?? 0), offset: 0)
        case .deleteCol:
            guard cols > 1 else { return RichOps.table(paras, at: index, .deleteTable) }
            table.removeAll { cell($0).1 == col }
            for i in table.indices where cell(table[i]).1 > col { let (r, c, h) = cell(table[i]); setCell(&table[i], r, c - 1, h) }
            caret = FlatPos(para: range.lowerBound + (table.firstIndex { cell($0).0 == row } ?? 0), offset: 0)
        }
        ps.replaceSubrange(range, with: table)
        caret.para = min(caret.para, ps.count - 1)
        return (ps, (caret, caret))
    }

    /// 勾选或取消任务列表项。
    static func toggleTask(_ paras: [FlatPara], at index: Int) -> [FlatPara]? {
        guard let d = paras[index].itemDepth, case .listItem(let ordered, let task?) = paras[index].path[d] else { return nil }
        var ps = paras
        let level = RichEditor.Level.listItem(ordered: ordered, task: RichTask(done: !task.done, id: task.id))
        for k in itemRange(ps, index, depth: d) where ps[k].path.count > d { ps[k].path[d] = level }
        return ps
    }
}

/// Wiki 编辑保存时保留未修改的内容：编辑器显示后再读出的块与原来的块写法可能不同（例如标题的 id），
/// 所以把原来的每个块单独经过编辑器的显示和读出，得到“未修改时编辑器给出的块”，与片段一一对应。
@MainActor
struct RichEditBaseline {
    var segments: [Rich.Segment]
    var baseline: RichDoc

    init(_ load: Rich.EditLoad) {
        var blocks: [RichBlock] = []
        var segments: [Rich.Segment] = []
        var index = 0
        for seg in load.segments {
            var count = 0
            for b in load.doc.blocks[index..<min(index + seg.count, load.doc.blocks.count)] {
                let normalized = Self.normalize(b)
                blocks += normalized
                count += normalized.count
            }
            index += seg.count
            segments.append(Rich.Segment(source: seg.source, count: count))
        }
        self.segments = segments
        baseline = RichDoc(blocks: blocks)
    }

    static func normalize(_ block: RichBlock) -> [RichBlock] {
        var r = RichRenderer(service: .confluence, editing: true)
        let text = r.render(RichDoc(blocks: [block]))
        return RichFlat.build(RichFlat.parse(text).paras).blocks
    }

    /// 编辑后的文档 → 编辑格式的 XHTML。编辑器在末尾补的空段落没有输入时去掉。
    func xhtml(_ edited: RichDoc) async throws -> String {
        var doc = edited
        let empty = RichBlock.para([])
        if doc.blocks.last == empty && baseline.blocks.last != empty { doc.blocks.removeLast() }
        return try await Rich.editXHTML(segments: segments, baseline: baseline, doc: doc)
    }
}
