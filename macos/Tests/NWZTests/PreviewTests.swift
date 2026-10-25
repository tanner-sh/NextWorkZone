import Foundation
import Testing
@testable import NWZPreview

struct PreviewTests {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")))
    }
    @Test func decodesUTF8AndGB18030() throws {
        #expect(Previewer.decode(Data("你好".utf8)).text == "你好")
        let result = Previewer.decode(try fixture("sample-gb18030.txt"))
        #expect(result.text == "报错信息" && result.encoding == "GB18030")
        #expect(Previewer.decode(Data([0xef, 0xbb, 0xbf, 97, 98, 99])).text == "abc")
        #expect(Previewer.decode(Data([0xff, 0xfe, 0x2d, 0x4e, 0x87, 0x65])).text == "中文")
    }
    @Test func parsesCSVWithQuotesAndCRLF() {
        #expect(Previewer.parseDelimited("a,b\r\n\"x,1\",\"say \"\"hi\"\"\"\n\"多\n行\",3\n", separator: ",") == [["a", "b"], ["x,1", "say \"hi\""], ["多\n行", "3"]])
        #expect(Previewer.detectSeparator("a;b;c\n1;2;3") == ";")
    }
    @Test func previewsCSVLogsAndBinary() {
        guard case .sheet(let sheets) = Previewer.preview(filename: "data.csv", mime: "", data: Data("h1,h2\n1,2\n".utf8)) else { Issue.record("缺少表格"); return }
        #expect(sheets[0].rows == [["h1", "h2"], ["1", "2"]])
        #expect(Previewer.preview(filename: "app.log", mime: "", data: Data("ERROR x".utf8)) == .text(text: "ERROR x", truncated: false, encoding: "UTF-8"))
        guard case .unsupported = Previewer.preview(filename: "a.bin", mime: "", data: Data([0, 1, 2, 3])) else { Issue.record("二进制不应当作文本"); return }
    }
    @Test func extractsDOCXParagraphs() throws {
        #expect(Previewer.preview(filename: "sample.docx", mime: "", data: try fixture("sample.docx")) == .document(paragraphs: ["第一段 A&B", "", "第二段\t列\n下一行"], truncated: false))
    }
    @Test func listsZIPEntries() throws {
        guard case .archive(let entries, let truncated) = Previewer.preview(filename: "sample.zip", mime: "", data: try fixture("sample.zip")) else { Issue.record("缺少文件列表"); return }
        #expect(entries.map(\.name) == ["lib/", "lib/补丁.class", "stored.txt"])
        #expect(entries[0].dir && entries[1].size == 3 && !truncated)
    }
    @Test func trimsEmptyCells() {
        #expect(Previewer.trimRows([["a", ""], ["", ""]]) == [["a"]])
    }
    @Test func workbookStringsDatesBooleansAndCachedFormulas() throws {
        guard case .sheet(let sheets) = Previewer.preview(filename: "sample.xlsx", mime: "", data: try fixture("sample.xlsx")) else { Issue.record("缺少工作表"); return }
        #expect(sheets.count == 1 && sheets[0].name == "验收表")
        #expect(sheets[0].totalRows == 3 && sheets[0].totalCols == 4)
        #expect(sheets[0].rows[1] == ["多段文字", "2024-01-01", "2024-01-01 12:00:00", "true"])
        #expect(sheets[0].rows[2][0] == "3")
        #expect(sheets[0].rows[2][2].contains("DIV"))
    }
    @Test func textTruncationKeepsUTF8Boundary() {
        var data = Data(repeating: 97, count: 2 * 1024 * 1024 - 1)
        data.append(Data("中文".utf8))
        let result = Previewer.decode(data)
        #expect(result.truncated && result.encoding == "UTF-8" && result.text.count == 2 * 1024 * 1024 - 1)
    }
    @Test(arguments: ["xls", "xlsb"]) func binaryWorkbooksReadDatesAndSharedStrings(_ extensionName: String) throws {
        let name = "sample." + extensionName
        guard case .sheet(let sheets) = Previewer.preview(filename: name, mime: "", data: try fixture(name)) else { Issue.record("缺少二进制工作表"); return }
        #expect(sheets[0].name == "验收表")
        #expect(sheets[0].rows == [["名称", ""], ["2024-01-01", "true"]])
    }
    @Test func openDocumentExpandsRepeatedRows() throws {
        guard case .sheet(let sheets) = Previewer.preview(filename: "sample.ods", mime: "", data: try fixture("sample.ods")) else { Issue.record("缺少工作表"); return }
        #expect(sheets[0].rows == [["名称", ""], ["42", "true"], ["42", "true"]])
    }
    @Test func zipReaderHandlesDeflateAndRejectsCorruption() throws {
        let data = try fixture("sample.zip"), zip = try ZIPArchive(data: data)
        #expect(try zip.read("lib/补丁.class") == Data("abc".utf8))
        #expect(throws: (any Error).self) { try ZIPArchive(data: Data([1, 2, 3])) }
        var corrupt = data
        let entry = zip.entries[1]
        corrupt[entry.offset + 30 + entry.name.utf8.count] ^= 0xff
        #expect(throws: (any Error).self) { let archive = try ZIPArchive(data: corrupt); _ = try archive.read("lib/补丁.class") }
    }
}
