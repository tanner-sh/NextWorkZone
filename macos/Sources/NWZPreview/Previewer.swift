import Foundation
import CoreFoundation

public enum Previewer {
    static let maxTextBytes = 2 * 1024 * 1024, maxRows = 2_000, maxColumns = 80, maxSheets = 30, maxParagraphs = 5_000
    static let textExtensions: Set<String> = ["txt", "log", "out", "err", "trace", "md", "json", "xml", "yaml", "yml", "sql", "ini", "conf", "cfg", "properties", "java", "js", "ts", "tsx", "jsx", "py", "rs", "go", "c", "h", "cpp", "cs", "kt", "sh", "bat", "cmd", "ps1", "html", "htm", "css", "vue", "toml", "gradle", "jsp"]
    public static func canPreview(filename: String, mime: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["xlsx", "xlsm", "xlsb", "xls", "ods", "csv", "tsv", "docx", "zip", "jar", "war"].contains(ext) || textExtensions.contains(ext) || mime.hasPrefix("text/") || ["application/json", "application/xml"].contains(mime)
    }
    public static func preview(filename: String, mime: String, data: Data) -> AttachmentPreview {
        let ext = (filename as NSString).pathExtension.lowercased()
        do {
            switch ext {
            case "xlsx", "xlsm": return try Workbook.preview(data)
            case "xlsb": return try BinaryWorkbook.preview(data)
            case "xls": return try LegacyWorkbook.preview(data)
            case "ods": return try OpenDocument.preview(data)
            case "csv", "tsv":
                let text = decode(data).text
                return .sheet([sheet(name: filename, rows: parseDelimited(text, separator: ext == "tsv" ? "\t" : detectSeparator(text)))])
            case "docx": return try WordDocument.preview(data)
            case "zip", "jar", "war":
                let archive = try ZIPArchive(data: data)
                return .archive(entries: archive.entries.prefix(5_000).map { .init(name: $0.name, size: $0.size, dir: $0.directory) }, truncated: archive.entries.count > 5_000)
            case "doc", "ppt", "pptx", "pdf": return .unsupported("这种文件暂不支持在应用内预览")
            default:
                guard canPreview(filename: filename, mime: mime) || looksTextual(data) else { return .unsupported("这种文件暂不支持在应用内预览") }
                let result = decode(data)
                return .text(text: result.text, truncated: result.truncated, encoding: result.encoding)
            }
        } catch { return .unsupported(error.localizedDescription) }
    }
    static func looksTextual(_ data: Data) -> Bool {
        let head = data.prefix(8192)
        return !head.isEmpty && !head.contains(0) && head.filter { $0 < 9 || $0 > 13 && $0 < 32 }.count * 100 < head.count
    }
    public static func decode(_ data: Data) -> (text: String, encoding: String, truncated: Bool) {
        let bytes = Array(data.prefix(maxTextBytes)), truncated = data.count > maxTextBytes
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { return (String(decoding: bytes.dropFirst(3), as: UTF8.self), "UTF-8", truncated) }
        if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) {
            let little = bytes[0] == 0xff
            let words = stride(from: 2, to: bytes.count - 1, by: 2).map { index in little ? UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8 : UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]) }
            return (String(decoding: words, as: UTF16.self), little ? "UTF-16LE" : "UTF-16BE", truncated)
        }
        if let text = String(bytes: bytes, encoding: .utf8) { return (text, "UTF-8", truncated) }
        if let prefix = incompleteUTF8Prefix(bytes) { return (String(decoding: bytes.prefix(prefix), as: UTF8.self), "UTF-8", truncated) }
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let text = String(data: Data(bytes), encoding: String.Encoding(rawValue: encoding)) ?? String(decoding: bytes, as: UTF8.self)
        return (text, "GB18030", truncated)
    }
    private static func incompleteUTF8Prefix(_ bytes: [UInt8]) -> Int? {
        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            if first < 0x80 { index += 1; continue }
            let length: Int
            switch first { case 0xc2...0xdf: length = 2; case 0xe0...0xef: length = 3; case 0xf0...0xf4: length = 4; default: return nil }
            let available = min(length, bytes.count - index)
            for offset in 1..<available {
                let byte = bytes[index + offset]
                guard byte >= 0x80 && byte <= 0xbf else { return nil }
                if offset == 1 && (first == 0xe0 && byte < 0xa0 || first == 0xed && byte >= 0xa0 || first == 0xf0 && byte < 0x90 || first == 0xf4 && byte >= 0x90) { return nil }
            }
            if available < length { return index }
            index += length
        }
        return nil
    }
    static func detectSeparator(_ text: String) -> Character {
        let first = text.split(whereSeparator: \.isNewline).first ?? ""
        return [Character(","), ";", "\t"].enumerated().max { a, b in
            let countA = first.filter { $0 == a.element }.count, countB = first.filter { $0 == b.element }.count
            return countA == countB ? a.offset < b.offset : countA < countB
        }?.element ?? ","
    }
    static func parseDelimited(_ text: String, separator: Character) -> [[String]] {
        let chars = Array(text), delimiter = separator
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, index = 0
        while index < chars.count {
            let character = chars[index]; index += 1
            if quoted {
                if character == "\"" && index < chars.count && chars[index] == "\"" { field.append("\""); index += 1 }
                else if character == "\"" { quoted = false }
                else { field.append(character) }
                continue
            }
            if character == "\"" && field.isEmpty { quoted = true }
            else if character == "\r" { continue }
            else if character == "\n" || character == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
            else if character == delimiter { row.append(field); field = "" }
            else { field.append(character) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
    static func trimRows(_ input: [[String]]) -> [[String]] {
        var rows = input
        while rows.last?.allSatisfy(\.isEmpty) == true { rows.removeLast() }
        let width = rows.map { ($0.lastIndex(where: { !$0.isEmpty }) ?? -1) + 1 }.max() ?? 0
        return rows.map { Array($0.prefix(width)) }
    }
    static func sheet(name: String, rows: [[String]]) -> PreviewSheet {
        .init(name: name, rows: trimRows(rows.prefix(maxRows).map { Array($0.prefix(maxColumns)) }), totalRows: rows.count, totalCols: rows.map(\.count).max() ?? 0)
    }
}
