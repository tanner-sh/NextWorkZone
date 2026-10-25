import Foundation

public struct PreviewSheet: Codable, Hashable, Sendable {
    public var name: String
    public var rows: [[String]]
    public var totalRows: Int
    public var totalCols: Int
}

public struct ArchiveEntry: Codable, Hashable, Sendable {
    public var name: String
    public var size: Int
    public var dir: Bool
}

public enum AttachmentPreview: Codable, Hashable, Sendable {
    case text(text: String, truncated: Bool, encoding: String)
    case sheet([PreviewSheet])
    case document(paragraphs: [String], truncated: Bool)
    case archive(entries: [ArchiveEntry], truncated: Bool)
    case unsupported(String)

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let text, let truncated, let encoding):
            try c.encode("text", forKey: .kind); try c.encode(text, forKey: .text); try c.encode(truncated, forKey: .truncated); try c.encode(encoding, forKey: .encoding)
        case .sheet(let sheets): try c.encode("sheet", forKey: .kind); try c.encode(sheets, forKey: .sheets)
        case .document(let paragraphs, let truncated):
            try c.encode("document", forKey: .kind); try c.encode(paragraphs, forKey: .paragraphs); try c.encode(truncated, forKey: .truncated)
        case .archive(let entries, let truncated):
            try c.encode("archive", forKey: .kind); try c.encode(entries, forKey: .entries); try c.encode(truncated, forKey: .truncated)
        case .unsupported(let reason): try c.encode("unsupported", forKey: .kind); try c.encode(reason, forKey: .reason)
        }
    }
    private enum Keys: String, CodingKey { case kind, text, truncated, encoding, sheets, paragraphs, entries, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "text": self = .text(text: try c.decode(String.self, forKey: .text), truncated: try c.decode(Bool.self, forKey: .truncated), encoding: try c.decode(String.self, forKey: .encoding))
        case "sheet": self = .sheet(try c.decode([PreviewSheet].self, forKey: .sheets))
        case "document": self = .document(paragraphs: try c.decode([String].self, forKey: .paragraphs), truncated: try c.decode(Bool.self, forKey: .truncated))
        case "archive": self = .archive(entries: try c.decode([ArchiveEntry].self, forKey: .entries), truncated: try c.decode(Bool.self, forKey: .truncated))
        default: self = .unsupported((try? c.decode(String.self, forKey: .reason)) ?? "不支持预览")
        }
    }
}
