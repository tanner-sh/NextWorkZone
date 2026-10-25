import Foundation
import NWZCore

internal enum Workbook {
    static func preview(_ data: Data) throws -> AttachmentPreview {
        let archive = try ZIPArchive(data: data)
        let book = BookReader(), relationships = RelationshipsReader(), strings = StringsReader(), styles = StylesReader()
        try book.parse(archive.read("xl/workbook.xml"))
        try relationships.parse(archive.read("xl/_rels/workbook.xml.rels"))
        if archive.entries.contains(where: { $0.name == "xl/sharedStrings.xml" }) { try strings.parse(archive.read("xl/sharedStrings.xml")) }
        if archive.entries.contains(where: { $0.name == "xl/styles.xml" }) { try styles.parse(archive.read("xl/styles.xml")) }
        var sheets: [PreviewSheet] = []
        for sheet in book.sheets.prefix(Previewer.maxSheets) {
            guard let target = relationships.paths[sheet.id] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : NSString(string: "xl/" + target).standardizingPath
            let reader = SheetReader(strings: strings.values, styles: styles, date1904: book.date1904)
            guard let xml = try? archive.read(path), (try? reader.parse(xml)) != nil else { continue }
            sheets.append(reader.result(name: sheet.name))
        }
        guard !sheets.isEmpty else { throw NWZError.other("表格中没有可显示的工作表") }
        return .sheet(sheets)
    }
    static func number(_ value: String) -> String {
        guard let number = Double(value), number.isFinite else { return value }
        if number.rounded() == number && abs(number) < 1e15 { return String(Int64(number)) }
        return String(number)
    }
    static func date(_ value: String, date1904: Bool) -> String {
        guard var serial = Double(value), serial.isFinite, abs(serial) < 3_000_000 else { return value }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let base = calendar.date(from: DateComponents(year: date1904 ? 1904 : 1899, month: date1904 ? 1 : 12, day: date1904 ? 1 : 30)) else { return value }
        if !date1904 && serial < 60 { serial += 1 }
        let date = base.addingTimeInterval((serial * 86_400).rounded())
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let text = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        if parts.hour == 0 && parts.minute == 0 && parts.second == 0 { return text }
        return text + String(format: " %02d:%02d:%02d", parts.hour!, parts.minute!, parts.second!)
    }
    static func isDateFormat(_ format: String) -> Bool {
        var quoted = false, bracketed = false, escaped = false, tokens = ""
        for character in format.lowercased() {
            if escaped { escaped = false; continue }
            if character == "\\" || character == "_" || character == "*" { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if quoted { continue }
            if character == "[" { bracketed = true; continue }
            if character == "]" { bracketed = false; continue }
            if !bracketed { tokens.append(character) }
        }
        return tokens.contains(where: { "ymdhs".contains($0) })
    }
}

private final class BookReader: XMLReader {
    var sheets: [(name: String, id: String)] = [], date1904 = false
    override func start(_ name: String, attributes: [String: String]) {
        if name == "workbookPr" { date1904 = ["1", "true"].contains(attributes["date1904"] ?? "") }
        if name == "sheet", let title = attributes["name"], let id = attributes["r:id"] { sheets.append((title, id)) }
    }
}
private final class RelationshipsReader: XMLReader {
    var paths: [String: String] = [:]
    override func start(_ name: String, attributes: [String: String]) {
        if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"], attributes["TargetMode"] != "External" { paths[id] = target }
    }
}
private final class StringsReader: XMLReader {
    var values: [String] = [], current = ""
    override func start(_ name: String, attributes: [String: String]) { if name == "si" { current = "" } }
    override func text(_ value: String) { if stack.last == "t" && !stack.contains("rPh") { current += value } }
    override func end(_ name: String) { if name == "si" { values.append(current) } }
}
private final class StylesReader: XMLReader {
    var formats: [Int: String] = [:], dates: [Bool] = []
    override func start(_ name: String, attributes: [String: String]) {
        if name == "numFmt", let id = attributes["numFmtId"].flatMap(Int.init), let format = attributes["formatCode"] { formats[id] = format }
        if name == "xf" && stack.contains("cellXfs") {
            let id = attributes["numFmtId"].flatMap(Int.init) ?? 0
            dates.append((14...22).contains(id) || (27...36).contains(id) || (45...47).contains(id) || (50...58).contains(id) || formats[id].map(Workbook.isDateFormat) == true)
        }
    }
}
private final class SheetReader: XMLReader {
    let strings: [String], styles: StylesReader, date1904: Bool
    var values: [Int: [Int: String]] = [:]
    var row = 0, column = 0, nextColumn = 0, style = 0, kind = "", value = "", inline = ""
    var minRow = Int.max, minColumn = Int.max, maxRow = -1, maxColumn = -1
    init(strings: [String], styles: StylesReader, date1904: Bool) { self.strings = strings; self.styles = styles; self.date1904 = date1904 }
    override func start(_ name: String, attributes: [String: String]) {
        if name == "row" { row = max(0, (attributes["r"].flatMap(Int.init) ?? row + 1) - 1); nextColumn = 0 }
        if name == "c" {
            column = attributes["r"].flatMap(Self.cellColumn) ?? nextColumn
            nextColumn = column + 1
            kind = attributes["t"] ?? "n"; style = attributes["s"].flatMap(Int.init) ?? 0; value = ""; inline = ""
        }
    }
    override func text(_ text: String) {
        if stack.last == "v" { value += text }
        if stack.last == "t" && stack.contains("is") { inline += text }
    }
    override func end(_ name: String) {
        guard name == "c" else { return }
        let text: String
        switch kind {
        case "s": text = Int(value).flatMap { strings.indices.contains($0) ? strings[$0] : nil } ?? ""
        case "inlineStr": text = inline
        case "b": text = value == "1" ? "true" : "false"
        case "str", "d", "e": text = value
        default: text = styles.dates.indices.contains(style) && styles.dates[style] ? Workbook.date(value, date1904: date1904) : Workbook.number(value)
        }
        guard !text.isEmpty, row < 1_048_576, column < 16_384 else { return }
        minRow = min(minRow, row); minColumn = min(minColumn, column); maxRow = max(maxRow, row); maxColumn = max(maxColumn, column)
        if row - minRow < Previewer.maxRows && column - minColumn < Previewer.maxColumns { values[row, default: [:]][column] = text }
    }
    func result(name: String) -> PreviewSheet {
        guard maxRow >= minRow && maxColumn >= minColumn else { return .init(name: name, rows: [], totalRows: 0, totalCols: 0) }
        let width = min(Previewer.maxColumns, maxColumn - minColumn + 1)
        let rows = (minRow...min(maxRow, minRow + Previewer.maxRows - 1)).map { row in (minColumn..<(minColumn + width)).map { values[row]?[$0] ?? "" } }
        return .init(name: name, rows: Previewer.trimRows(rows), totalRows: maxRow - minRow + 1, totalCols: maxColumn - minColumn + 1)
    }
    private static func cellColumn(_ reference: String) -> Int? {
        var column = 0
        for scalar in reference.uppercased().unicodeScalars {
            guard scalar.value >= 65 && scalar.value <= 90 else { break }
            column = column * 26 + Int(scalar.value - 64)
            if column > 16_384 { return nil }
        }
        return column > 0 ? column - 1 : nil
    }
}
