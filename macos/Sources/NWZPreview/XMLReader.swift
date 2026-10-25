import Foundation
import NWZCore

/// XMLParser 的代理只在本次同步解析中使用，外部实体始终关闭。
class XMLReader: NSObject, XMLParserDelegate {
    var stack: [String] = []
    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() else { throw NWZError.other("文档 XML 格式有误") }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        stack.append(elementName)
        start(elementName, attributes: attributeDict)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        end(elementName); _ = stack.popLast()
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text(string) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text(String(decoding: CDATABlock, as: UTF8.self)) }
    func start(_ name: String, attributes: [String: String]) {}
    func end(_ name: String) {}
    func text(_ value: String) {}
}

final class WordDocument: XMLReader {
    var paragraphs: [String] = [], current = "", total = 0
    override func start(_ name: String, attributes: [String: String]) {
        if name == "w:tab" { current += "\t" }
        if name == "w:br" { current += "\n" }
    }
    override func text(_ value: String) { if stack.last == "w:t" && total < Previewer.maxParagraphs { current += value } }
    override func end(_ name: String) {
        if name == "w:p" {
            total += 1
            if total <= Previewer.maxParagraphs { paragraphs.append(current) }
            current = ""
        }
    }
    static func preview(_ data: Data) throws -> AttachmentPreview {
        let reader = WordDocument()
        try reader.parse(ZIPArchive(data: data).read("word/document.xml"))
        var result: [String] = []
        for paragraph in reader.paragraphs {
            if paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && result.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { continue }
            result.append(paragraph)
        }
        return .document(paragraphs: result, truncated: reader.total >= Previewer.maxParagraphs)
    }
}
