import Foundation
import Compression
import NWZCore

/// 只读取 ZIP 中央目录和条目，不将归档路径写到文件系统。
public struct ZIPArchive: Sendable {
    public struct Entry: Sendable {
        public let name: String
        public let size: Int
        public let directory: Bool
        let compressedSize: Int, method: Int, flags: Int, offset: Int
        let crc: UInt32
    }
    let data: Data
    public let entries: [Entry]
    public init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw Self.invalid() }
        let lower = max(0, data.count - 65_557)
        guard let end = stride(from: data.count - 22, through: lower, by: -1).first(where: { data.u32($0) == 0x06054b50 && $0 + 22 + Int(data.u16($0 + 20) ?? 0) == data.count }),
              data.u16(end + 4) == 0, data.u16(end + 6) == 0,
              let count = data.u16(end + 10), let directoryOffset = data.u32(end + 16), let directorySize = data.u32(end + 12),
              count != UInt16.max, directoryOffset != UInt32.max, directorySize != UInt32.max,
              Int(directoryOffset) + Int(directorySize) <= end else { throw Self.invalid() }
        var cursor = Int(directoryOffset), entries: [Entry] = []
        for _ in 0..<count {
            guard data.u32(cursor) == 0x02014b50, cursor + 46 <= data.count,
                  let nameSize = data.u16(cursor + 28), let extraSize = data.u16(cursor + 30), let commentSize = data.u16(cursor + 32),
                  let compressed = data.u32(cursor + 20), let size = data.u32(cursor + 24), let offset = data.u32(cursor + 42), let crc = data.u32(cursor + 16),
                  let flags = data.u16(cursor + 8), let method = data.u16(cursor + 10) else { throw Self.invalid() }
            let next = cursor + 46 + Int(nameSize) + Int(extraSize) + Int(commentSize)
            guard next <= Int(directoryOffset) + Int(directorySize) else { throw Self.invalid() }
            let nameData = data[(cursor + 46)..<(cursor + 46 + Int(nameSize))]
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            entries.append(.init(name: name, size: Int(size), directory: name.hasSuffix("/"), compressedSize: Int(compressed), method: Int(method), flags: Int(flags), offset: Int(offset), crc: crc))
            cursor = next
        }
        self.entries = entries
    }
    public func read(_ name: String, limit: Int = 128 * 1024 * 1024) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else { throw NWZError.other("压缩包中缺少文件：\(name)") }
        guard entry.flags & 1 == 0 else { throw NWZError.other("无法预览加密的压缩包") }
        guard entry.size <= limit, entry.compressedSize <= data.count,
              data.u32(entry.offset) == 0x04034b50,
              let nameSize = data.u16(entry.offset + 26), let extraSize = data.u16(entry.offset + 28) else { throw Self.invalid() }
        let start = entry.offset + 30 + Int(nameSize) + Int(extraSize)
        guard start <= data.count, entry.compressedSize <= data.count - start else { throw Self.invalid() }
        let bytes = data.subdata(in: start..<(start + entry.compressedSize)), output: Data
        switch entry.method {
        case 0: output = bytes
        case 8:
            guard !bytes.isEmpty else { throw Self.invalid() }
            // 多分配一个字节，区别“恰好解完”与“输出缓冲区不够”。
            var destination = Data(count: entry.size + 1)
            let capacity = destination.count
            let written = destination.withUnsafeMutableBytes { target in
                bytes.withUnsafeBytes { source in
                    compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, capacity, source.bindMemory(to: UInt8.self).baseAddress!, bytes.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw Self.invalid() }
            destination.count = written; output = destination
        default: throw NWZError.other("不支持这种 ZIP 压缩方式")
        }
        guard output.count == entry.size, Self.crc32(output) == entry.crc else { throw Self.invalid() }
        return output
    }
    private static func invalid() -> NWZError { .other("压缩包损坏或格式不受支持") }
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        }
        return crc ^ 0xffffffff
    }
}

extension Data {
    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset <= count - 2 else { return nil }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func u32(_ offset: Int) -> UInt32? {
        guard let low = u16(offset), let high = u16(offset + 2) else { return nil }
        return UInt32(low) | UInt32(high) << 16
    }
}
