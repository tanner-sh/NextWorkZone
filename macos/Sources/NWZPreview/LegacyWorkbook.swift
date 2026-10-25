import Foundation
import NWZCore

enum LegacyWorkbook {
    static func preview(_ data: Data) throws -> AttachmentPreview {
        let compound = try CompoundFile(data)
        let bytes = try compound.workbook()
        let records = try records(bytes)
        var sheets: [(Int, String)] = [], strings: [String] = [], formats: [Int: String] = [:], styles: [Int] = []
        var date1904 = false, index = 0
        while index < records.count {
            let (type, value) = records[index]; index += 1
            if type == 0x2f { throw NWZError.other("不支持预览加密表格") }
            if type == 0x0a { break }
            switch type {
            case 0x85:
                guard value.count >= 8, let offset = value.u32(0) else { continue }
                let count = Int(value[6]), width = value[7] & 1 == 1 ? 2 : 1
                guard 8 + count * width <= value.count else { throw BinaryWorkbook.invalid() }
                sheets.append((Int(offset), string(value.subdata(in: 8..<(8 + count * width)), wide: width == 2)))
            case 0xfc:
                var parts = [Data(value.dropFirst(8))]
                while index < records.count && records[index].0 == 0x3c { parts.append(records[index].1); index += 1 }
                var reader = BiffStrings(parts: parts)
                guard let count = value.u32(4), count < 1_000_000 else { throw BinaryWorkbook.invalid() }
                for _ in 0..<count { strings.append(try reader.read()) }
            case 0xe0: if let format = value.u16(2) { styles.append(Int(format)) }
            case 0x41e:
                if let format = value.u16(0) { var reader = BiffStrings(parts: [Data(value.dropFirst(2))]); formats[Int(format)] = try reader.read() }
            case 0x22: date1904 = value.u16(0) == 1
            default: break
            }
        }
        var result: [PreviewSheet] = []
        for (offset, name) in sheets.prefix(Previewer.maxSheets) {
            guard offset < bytes.count else { throw BinaryWorkbook.invalid() }
            var grid = SheetGrid(), pending: (Int, Int)?
            for (type, value) in try Self.records(Data(bytes.dropFirst(offset))) {
                if type == 0x0a { break }
                if type == 0x207, let (row, column) = pending {
                    var reader = BiffStrings(parts: [value]); grid.add(row: row, column: column, text: try reader.read()); pending = nil; continue
                }
                guard let rowValue = value.u16(0), let columnValue = value.u16(2), let styleValue = value.u16(4) else { continue }
                let row = Int(rowValue), column = Int(columnValue), style = Int(styleValue)
                func format(_ number: Double, _ style: Int) -> String {
                    BinaryWorkbook.formatted(number, date: styles.indices.contains(style) && BinaryWorkbook.isDate(styles[style], formats: formats), date1904: date1904)
                }
                let text: String
                switch type {
                case 0x203: guard let number = value.double(6) else { continue }; text = format(number, style)
                case 0x27e: guard let number = value.u32(6) else { continue }; text = format(BinaryWorkbook.rkNumber(number), style)
                case 0xbd:
                    guard value.count >= 12 else { continue }
                    for position in stride(from: 4, to: value.count - 2, by: 6) {
                        guard let style = value.u16(position), let number = value.u32(position + 2) else { continue }
                        grid.add(row: row, column: column + (position - 4) / 6, text: format(BinaryWorkbook.rkNumber(number), Int(style)))
                    }
                    continue
                case 0xfd: guard let id = value.u32(6), Int(id) < strings.count else { continue }; text = strings[Int(id)]
                case 0x204: var reader = BiffStrings(parts: [Data(value.dropFirst(6))]); text = try reader.read()
                case 0x205: guard value.count >= 8 else { continue }; text = value[7] == 0 ? (value[6] == 0 ? "false" : "true") : BinaryWorkbook.error(value[6])
                case 0x06:
                    guard value.count >= 14 else { continue }
                    if value[12] == 0xff && value[13] == 0xff {
                        switch value[6] {
                        case 0: pending = (row, column); continue
                        case 1: text = value[8] == 0 ? "false" : "true"
                        case 2: text = BinaryWorkbook.error(value[8])
                        default: continue
                        }
                    } else { text = format(value.double(6)!, style) }
                default: continue
                }
                grid.add(row: row, column: column, text: text)
            }
            result.append(grid.result(name: name))
        }
        guard !result.isEmpty else { throw BinaryWorkbook.invalid() }
        return .sheet(result)
    }
    static func records(_ data: Data) throws -> [(Int, Data)] {
        var offset = 0, result: [(Int, Data)] = []
        while offset + 4 <= data.count {
            let type = Int(data.u16(offset)!), length = Int(data.u16(offset + 2)!); offset += 4
            guard length <= data.count - offset else { throw BinaryWorkbook.invalid() }
            result.append((type, data.subdata(in: offset..<(offset + length)))); offset += length
        }
        return result
    }
    static func string(_ data: Data, wide: Bool) -> String {
        let words = wide ? stride(from: 0, to: data.count - 1, by: 2).map { data.u16($0)! } : data.map(UInt16.init)
        return String(decoding: words, as: UTF16.self)
    }
}

/// SST 的续记录允许切换字符宽度，只在字符区边界消耗续记录的标记。
private struct BiffStrings {
    var parts: [Data], part = 0, offset = 0
    mutating func byte() throws -> UInt8 {
        while part < parts.count && offset == parts[part].count { part += 1; offset = 0 }
        guard part < parts.count else { throw BinaryWorkbook.invalid() }
        defer { offset += 1 }; return parts[part][offset]
    }
    mutating func word() throws -> Int { let low = try byte(); return Int(low) | Int(try byte()) << 8 }
    mutating func read() throws -> String {
        let count = try word(), flags = try byte(), runs = flags & 8 != 0 ? try word() : 0
        let extensionSize: Int
        if flags & 4 != 0 { let low = try word(); extensionSize = low | (try word()) << 16 } else { extensionSize = 0 }
        var wide = flags & 1 != 0, words: [UInt16] = []
        for _ in 0..<count {
            if part < parts.count && offset == parts[part].count { part += 1; offset = 0; wide = try byte() & 1 != 0 }
            words.append(wide ? UInt16(try word()) : UInt16(try byte()))
        }
        guard extensionSize < 128 * 1024 * 1024 else { throw BinaryWorkbook.invalid() }
        for _ in 0..<(runs * 4 + extensionSize) { _ = try byte() }
        return String(decoding: words, as: UTF16.self)
    }
}

private struct CompoundFile {
    let data: Data, sectorSize: Int, fat: [UInt32]
    init(_ data: Data) throws {
        guard data.count >= 512, data.starts(with: [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]), let shift = data.u16(30), [9, 12].contains(shift), data.u16(32) == 6 else { throw BinaryWorkbook.invalid() }
        self.data = data
        let sectorSize = 1 << Int(shift)
        self.sectorSize = sectorSize
        func sector(_ id: UInt32) throws -> Data {
            let start = (Int(id) + 1) * sectorSize
            guard start <= data.count - sectorSize else { throw BinaryWorkbook.invalid() }
            return data.subdata(in: start..<(start + sectorSize))
        }
        var ids = stride(from: 76, to: 512, by: 4).compactMap { data.u32($0) }.filter { $0 < 0xfffffffa }
        var next = data.u32(68)!, visited: Set<UInt32> = []
        while next < 0xfffffffa {
            guard visited.insert(next).inserted else { throw BinaryWorkbook.invalid() }
            let bytes = try sector(next)
            ids += stride(from: 0, to: sectorSize - 4, by: 4).compactMap { bytes.u32($0) }.filter { $0 < 0xfffffffa }
            next = bytes.u32(sectorSize - 4)!
        }
        var entries: [UInt32] = []
        for id in ids { let bytes = try sector(id); entries += stride(from: 0, to: sectorSize, by: 4).map { bytes.u32($0)! } }
        fat = entries
    }
    func chain(_ start: UInt32, table: [UInt32], source: Data, size: Int, base: Int, limit: Int = 128 * 1024 * 1024) throws -> Data {
        var id = start, visited: Set<UInt32> = [], result = Data()
        while id < 0xfffffffa {
            let offset = Int(id) * size + base
            guard Int(id) < table.count, visited.insert(id).inserted, offset <= source.count - size, result.count <= limit - size else { throw BinaryWorkbook.invalid() }
            result.append(source.subdata(in: offset..<(offset + size))); id = table[Int(id)]
        }
        return result
    }
    func workbook() throws -> Data {
        let directory = try chain(data.u32(48)!, table: fat, source: data, size: sectorSize, base: sectorSize)
        var root: (UInt32, Int)?, book: (UInt32, Int)?
        for offset in stride(from: 0, to: directory.count - 127, by: 128) {
            let count = Int(directory.u16(offset + 64)!)
            guard count >= 2 && count <= 64 else { continue }
            let name = LegacyWorkbook.string(directory.subdata(in: offset..<(offset + count - 2)), wide: true)
            guard let size = directory.u64(offset + 120), size < 128 * 1024 * 1024 else { throw BinaryWorkbook.invalid() }
            let entry = (directory.u32(offset + 116)!, Int(size))
            if directory[offset + 66] == 5 { root = entry }
            if directory[offset + 66] == 2 && ["Workbook", "Book"].contains(name) { book = entry }
        }
        guard let (start, count) = book else { throw BinaryWorkbook.invalid() }
        let result: Data
        if count < 4096 {
            guard let (rootStart, _) = root else { throw BinaryWorkbook.invalid() }
            let stream = try chain(rootStart, table: fat, source: data, size: sectorSize, base: sectorSize)
            let mini = try chain(data.u32(60)!, table: fat, source: data, size: sectorSize, base: sectorSize)
            let table = stride(from: 0, to: mini.count, by: 4).map { mini.u32($0)! }
            result = try chain(start, table: table, source: stream, size: 64, base: 0)
        } else { result = try chain(start, table: fat, source: data, size: sectorSize, base: sectorSize) }
        guard count <= result.count else { throw BinaryWorkbook.invalid() }
        return Data(result.prefix(count))
    }
}
