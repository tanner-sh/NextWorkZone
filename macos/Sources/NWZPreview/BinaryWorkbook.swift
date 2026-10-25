import Foundation
import NWZCore

/// 二进制 Excel 使用单元格的已缓存值，预览不执行公式或宏。
enum BinaryWorkbook {
    static func preview(_ data: Data) throws -> AttachmentPreview {
        let zip = try ZIPArchive(data: data)
        let workbook = try records(zip.read("xl/workbook.bin"))
        let relationships = BinaryRelationships()
        try relationships.parse(zip.read("xl/_rels/workbook.bin.rels"))
        let date1904 = (workbook.first { $0.0 == 0x99 }?.1.first ?? 0) & 1 != 0
        var strings: [String] = [], formats: [Int: String] = [:], dates: [Bool] = []
        if let data = try? zip.read("xl/sharedStrings.bin") {
            strings = try records(data).filter { $0.0 == 0x13 }.map { var offset = 1; return try wideString($0.1, offset: &offset) }
        }
        if let data = try? zip.read("xl/styles.bin") {
            var inCellFormats = false
            for (type, bytes) in try records(data) {
                if type == 0x2c, let id = bytes.u16(0) { var offset = 2; formats[Int(id)] = try wideString(bytes, offset: &offset) }
                if type == 0x269 { inCellFormats = true }
                if type == 0x26a { inCellFormats = false }
                if type == 0x2f && inCellFormats, let id = bytes.u16(2) { dates.append(isDate(Int(id), formats: formats)) }
            }
        }
        var sheets: [PreviewSheet] = []
        for (_, bytes) in workbook.filter({ $0.0 == 0x9c }).prefix(Previewer.maxSheets) {
            var offset = 8
            let relationship = try wideString(bytes, offset: &offset), name = try wideString(bytes, offset: &offset)
            guard let target = relationships.paths[relationship] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : NSString(string: "xl/" + target).standardizingPath
            var grid = SheetGrid(), row = 0
            for (type, bytes) in try records(zip.read(path)) {
                if type == 0, let value = bytes.u32(0) { row = Int(value); continue }
                guard (2...11).contains(type), bytes.count >= 8, let column = bytes.u32(0), let styleValue = bytes.u32(4) else { continue }
                let style = Int(styleValue & 0xffffff), text: String
                switch type {
                case 2: guard let rk = bytes.u32(8) else { continue }; text = formatted(rkNumber(rk), date: dates.indices.contains(style) && dates[style], date1904: date1904)
                case 3, 11: guard bytes.count > 8 else { continue }; text = error(bytes[8])
                case 4, 10: guard bytes.count > 8 else { continue }; text = bytes[8] == 0 ? "false" : "true"
                case 5, 9: guard let number = bytes.double(8) else { continue }; text = formatted(number, date: dates.indices.contains(style) && dates[style], date1904: date1904)
                case 6, 8: var offset = 8; text = try wideString(bytes, offset: &offset)
                case 7: guard let index = bytes.u32(8), Int(index) < strings.count else { continue }; text = strings[Int(index)]
                default: continue
                }
                grid.add(row: row, column: Int(column), text: text)
            }
            sheets.append(grid.result(name: name))
        }
        guard !sheets.isEmpty else { throw NWZError.other("表格中没有可显示的工作表") }
        return .sheet(sheets)
    }
    static func records(_ data: Data) throws -> [(Int, Data)] {
        var index = 0, result: [(Int, Data)] = []
        func variable(_ maxBytes: Int) throws -> Int {
            var result = 0
            for shift in 0..<maxBytes {
                guard index < data.count else { throw invalid() }
                let byte = data[index]; index += 1
                result |= Int(byte & 0x7f) << (shift * 7)
                if byte & 0x80 == 0 { return result }
            }
            throw invalid()
        }
        while index < data.count {
            let type = try variable(2), count = try variable(4)
            guard count <= data.count - index else { throw invalid() }
            result.append((type, data.subdata(in: index..<(index + count)))); index += count
        }
        return result
    }
    static func wideString(_ data: Data, offset: inout Int) throws -> String {
        guard let count = data.u32(offset), count != UInt32.max, Int(count) <= (data.count - offset - 4) / 2 else { throw invalid() }
        offset += 4
        let words = stride(from: offset, to: offset + Int(count) * 2, by: 2).map { data.u16($0)! }
        offset += Int(count) * 2
        return String(decoding: words, as: UTF16.self)
    }
    static func isDate(_ id: Int, formats: [Int: String]) -> Bool {
        (14...22).contains(id) || (27...36).contains(id) || (45...47).contains(id) || (50...58).contains(id) || formats[id].map(Workbook.isDateFormat) == true
    }
    static func formatted(_ number: Double, date: Bool, date1904: Bool) -> String {
        date ? Workbook.date(String(number), date1904: date1904) : Workbook.number(String(number))
    }
    static func rkNumber(_ bits: UInt32) -> Double {
        let value = bits & 2 != 0 ? Double(Int32(bitPattern: bits) >> 2) : Double(bitPattern: UInt64(bits & 0xfffffffc) << 32)
        return bits & 1 != 0 ? value / 100 : value
    }
    static func error(_ value: UInt8) -> String { [0x00: "#Null", 0x07: "#Div0", 0x0f: "#Value", 0x17: "#Ref", 0x1d: "#Name", 0x24: "#Num", 0x2a: "#NA", 0x2b: "#GettingData"][Int(value)] ?? "#Error" }
    static func invalid() -> NWZError { .other("无法读取二进制表格") }
}
private final class BinaryRelationships: XMLReader {
    var paths: [String: String] = [:]
    override func start(_ name: String, attributes: [String: String]) {
        if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"], attributes["TargetMode"] != "External" { paths[id] = target }
    }
}
extension Data {
    func u64(_ offset: Int) -> UInt64? {
        guard let low = u32(offset), let high = u32(offset + 4) else { return nil }
        return UInt64(low) | UInt64(high) << 32
    }
    func double(_ offset: Int) -> Double? { u64(offset).map(Double.init(bitPattern:)) }
}
