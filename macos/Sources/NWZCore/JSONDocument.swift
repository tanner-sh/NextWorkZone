import Foundation

/// 字段元数据依赖服务器的对象键顺序，不能经由无序 Dictionary 再构造表单。
public indirect enum JSONDocument: Sendable {
    case scalar(JSONValue)
    case array([JSONDocument])
    case object([(String, JSONDocument)])

    public static var null: Self { .scalar(.null) }
    public var string: String? { if case .scalar(let value) = self { value.string } else { nil } }
    public var number: Double? { if case .scalar(let value) = self { value.number } else { nil } }
    public var bool: Bool? { if case .scalar(let value) = self { value.bool } else { nil } }
    public var text: String { string ?? "" }
    public var int: Int { number.flatMap { Int(exactly: $0) } ?? 0 }
    public var list: [JSONDocument] { if case .array(let list) = self { list } else { [] } }
    public var keys: [String] { if case .object(let entries) = self { entries.map(\.0) } else { [] } }
    public var isObject: Bool { if case .object = self { true } else { false } }
    public var isNull: Bool { if case .scalar(.null) = self { true } else { false } }
    public subscript(_ key: String) -> Self {
        if case .object(let entries) = self { entries.last { $0.0 == key }?.1 ?? .null } else { .null }
    }
    public subscript(_ index: Int) -> Self { list.indices.contains(index) ? list[index] : .null }
    public var value: JSONValue {
        switch self {
        case .scalar(let value): value
        case .array(let items): .array(items.map(\.value))
        case .object(let entries): .object(Dictionary(entries.map { ($0.0, $0.1.value) }, uniquingKeysWith: { _, new in new }))
        }
    }
    public init(value: JSONValue) {
        switch value {
        case .array(let items): self = .array(items.map(Self.init(value:)))
        case .object(let entries): self = .object(entries.keys.sorted().map { ($0, Self(value: entries[$0]!)) })
        default: self = .scalar(value)
        }
    }
    public init(data: Data) throws {
        var reader = JSONDocumentReader(bytes: Array(data))
        self = try reader.read(depth: 0)
        reader.skipSpaces()
        guard reader.offset == reader.bytes.count else { throw NWZError.other("JSON 响应末尾包含无效内容") }
    }
}

private struct JSONDocumentReader {
    let bytes: [UInt8]
    var offset = 0
    mutating func skipSpaces() { while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
    mutating func consume(_ byte: UInt8) throws {
        skipSpaces(); guard offset < bytes.count && bytes[offset] == byte else { throw NWZError.other("无效的 JSON 响应") }; offset += 1
    }
    mutating func string() throws -> String {
        skipSpaces(); let start = offset
        try consume(34)
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
            if byte == 92 { offset += 1 }
        }
        throw NWZError.other("JSON 字符串未结束")
    }
    mutating func read(depth: Int) throws -> JSONDocument {
        skipSpaces()
        guard depth < 512, offset < bytes.count else { throw NWZError.other("JSON 响应不完整或嵌套过深") }
        switch bytes[offset] {
        case 34: return .scalar(.string(try string()))
        case 123:
            offset += 1; skipSpaces(); var entries: [(String, JSONDocument)] = []
            if offset < bytes.count && bytes[offset] == 125 { offset += 1; return .object([]) }
            while true {
                let key = try string(); try consume(58); let value = try read(depth: depth + 1)
                if let previous = entries.firstIndex(where: { $0.0 == key }) { entries[previous].1 = value } else { entries.append((key, value)) }
                skipSpaces(); guard offset < bytes.count else { throw NWZError.other("JSON 对象未结束") }
                if bytes[offset] == 125 { offset += 1; return .object(entries) }
                try consume(44)
            }
        case 91:
            offset += 1; skipSpaces(); var entries: [JSONDocument] = []
            if offset < bytes.count && bytes[offset] == 93 { offset += 1; return .array([]) }
            while true {
                entries.append(try read(depth: depth + 1)); skipSpaces()
                guard offset < bytes.count else { throw NWZError.other("JSON 数组未结束") }
                if bytes[offset] == 93 { offset += 1; return .array(entries) }
                try consume(44)
            }
        default:
            let start = offset
            while offset < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
            return .scalar(try JSONDecoder().decode(JSONValue.self, from: Data(bytes[start..<offset])))
        }
    }
}
