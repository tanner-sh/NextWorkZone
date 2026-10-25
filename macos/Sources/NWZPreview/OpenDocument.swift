import Foundation

final class OpenDocument: XMLReader {
    var sheets: [PreviewSheet] = [], name = "", grid = SheetGrid()
    var row = 0, column = 0, rowRepeat = 1, columnRepeat = 1, cell = "", fallback = ""
    override func start(_ name: String, attributes: [String: String]) {
        switch name {
        case "table:table": self.name = attributes["table:name"] ?? ""; grid = SheetGrid(); row = 0
        case "table:table-row": column = 0; rowRepeat = min(1_048_576, max(1, Int(attributes["table:number-rows-repeated"] ?? "1") ?? 1))
        case "table:table-cell", "table:covered-table-cell":
            cell = ""; columnRepeat = min(16_384, max(1, Int(attributes["table:number-columns-repeated"] ?? "1") ?? 1))
            fallback = attributes["office:string-value"] ?? attributes["office:date-value"] ?? attributes["office:boolean-value"] ?? attributes["office:time-value"] ?? attributes["office:value"] ?? ""
        case "text:p": if !cell.isEmpty { cell += "\n" }
        case "text:s": cell += String(repeating: " ", count: min(10_000, max(1, Int(attributes["text:c"] ?? "1") ?? 1)))
        case "text:tab": cell += "\t"
        case "text:line-break": cell += "\n"
        default: break
        }
    }
    override func text(_ value: String) { if stack.contains("text:p") { cell += value } }
    override func end(_ name: String) {
        switch name {
        case "table:table-cell", "table:covered-table-cell":
            let value = cell.isEmpty ? fallback : cell
            if !value.isEmpty {
                grid.include(row: min(1_048_575, row + rowRepeat - 1), column: min(16_383, column + columnRepeat - 1))
                for rowOffset in 0..<min(rowRepeat, Previewer.maxRows) {
                    for columnOffset in 0..<min(columnRepeat, Previewer.maxColumns) { grid.add(row: row + rowOffset, column: column + columnOffset, text: value) }
                }
            }
            column += columnRepeat
        case "table:table-row": row += rowRepeat
        case "table:table": if sheets.count < Previewer.maxSheets { sheets.append(grid.result(name: self.name)) }
        default: break
        }
    }
    static func preview(_ data: Data) throws -> AttachmentPreview {
        let reader = OpenDocument()
        try reader.parse(ZIPArchive(data: data).read("content.xml"))
        return .sheet(reader.sheets)
    }
}

struct SheetGrid {
    var cells: [Int: [Int: String]] = [:]
    var minRow = Int.max, minColumn = Int.max, maxRow = -1, maxColumn = -1
    mutating func include(row: Int, column: Int) {
        minRow = min(minRow, row); minColumn = min(minColumn, column); maxRow = max(maxRow, row); maxColumn = max(maxColumn, column)
    }
    mutating func add(row: Int, column: Int, text: String) {
        guard !text.isEmpty, row >= 0, row < 1_048_576, column >= 0, column < 16_384 else { return }
        include(row: row, column: column)
        if row - minRow < Previewer.maxRows && column - minColumn < Previewer.maxColumns { cells[row, default: [:]][column] = text }
    }
    func result(name: String) -> PreviewSheet {
        guard maxRow >= minRow && maxColumn >= minColumn else { return .init(name: name, rows: [], totalRows: 0, totalCols: 0) }
        let width = min(Previewer.maxColumns, maxColumn - minColumn + 1)
        let rows = (minRow...min(maxRow, minRow + Previewer.maxRows - 1)).map { row in (minColumn..<(minColumn + width)).map { cells[row]?[$0] ?? "" } }
        return .init(name: name, rows: Previewer.trimRows(rows), totalRows: maxRow - minRow + 1, totalCols: maxColumn - minColumn + 1)
    }
}
