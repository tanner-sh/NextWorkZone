import Foundation
import CLibXML2

/// 解析结束前复制节点数据，C 指针从不离开调用栈，也不跨并发边界。
public struct HTMLNode: Sendable {
    public var tag: String
    public var attributes: [String: String]
    public var children: [HTMLNode]
    public var text: String
    public var isText: Bool { tag.isEmpty }
    public var content: String { isText ? text : children.map(\.content).joined() }
    public var trimmed: String { content.trimmingCharacters(in: .whitespacesAndNewlines) }
    public func attribute(_ name: String) -> String? { attributes[name].flatMap { $0.isEmpty ? nil : $0 } }
    public func hasClass(_ value: String) -> Bool { attributes["class"]?.split(whereSeparator: \.isWhitespace).contains(Substring(value)) == true }
    public func descendants(where predicate: (HTMLNode) -> Bool) -> [HTMLNode] {
        children.flatMap { node in (predicate(node) ? [node] : []) + node.descendants(where: predicate) }
    }
    public func first(where predicate: (HTMLNode) -> Bool) -> HTMLNode? {
        for child in children { if predicate(child) { return child }; if let node = child.first(where: predicate) { return node } }
        return nil
    }
    public static func parse(_ html: String) -> HTMLNode {
        let empty = HTMLNode(tag: "body", attributes: [:], children: [], text: "")
        guard html.utf8.count <= Int(Int32.max) else { return empty }
        let options = Int32(HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NONET.rawValue)
        guard let document = htmlReadMemory(html, Int32(html.utf8.count), nil, "UTF-8", options) else { return empty }
        defer { xmlFreeDoc(document) }
        guard let root = xmlDocGetRootElement(document) else { return empty }
        let tree = copy(root, document: document)
        return tree.tag == "body" ? tree : tree.first { $0.tag == "body" } ?? tree
    }
    private static func copy(_ pointer: xmlNodePtr, document: xmlDocPtr) -> HTMLNode {
        let raw = pointer.pointee
        if raw.type == XML_TEXT_NODE || raw.type == XML_CDATA_SECTION_NODE {
            return .init(tag: "", attributes: [:], children: [], text: raw.content.map { String(cString: $0) } ?? "")
        }
        var attributes: [String: String] = [:], property = raw.properties
        while let current = property {
            let name = String(cString: current.pointee.name)
            if let value = xmlNodeListGetString(document, current.pointee.children, 1) {
                attributes[name] = String(cString: value); nwz_xml_free(value)
            }
            property = current.pointee.next
        }
        var children: [HTMLNode] = [], child = raw.children
        while let current = child {
            if current.pointee.type == XML_ELEMENT_NODE || current.pointee.type == XML_TEXT_NODE || current.pointee.type == XML_CDATA_SECTION_NODE { children.append(copy(current, document: document)) }
            child = current.pointee.next
        }
        return .init(tag: raw.name.map { String(cString: $0).lowercased() } ?? "", attributes: attributes, children: children, text: "")
    }
}
