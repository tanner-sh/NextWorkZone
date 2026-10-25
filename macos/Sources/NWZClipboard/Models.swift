import Foundation

/// 未压缩的 RGBA 像素（每像素 4 字节，行与行之间没有填充）。
public struct RGBAImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var pixels: Data
    public init(width: Int, height: Int, pixels: Data) { self.width = width; self.height = height; self.pixels = pixels }
}

/// 新复制的一份内容。
public struct Capture: Sendable {
    public var text: String?
    public var html: String?
    public var image: RGBAImage?
    public var files: [String]
    /// 来源应用（标识, 名称）。
    public var app: (id: String, name: String)?
    public init(text: String? = nil, html: String? = nil, image: RGBAImage? = nil, files: [String] = [], app: (id: String, name: String)? = nil) {
        self.text = text; self.html = html; self.image = image; self.files = files; self.app = app
    }
}

public struct ClipImage: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    /// PNG 文件大小。
    public var bytes: Int
}

/// 一条历史记录。列表中的 `text` 只有开头一部分，完整内容见 [`ClipboardStore.content`]。
public struct ClipItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// 见 [`ClipKind.all`]。
    public var kind: String
    public var text: String
    /// 完整文字的字符数。
    public var textLength: Int
    public var hasHtml: Bool
    /// 用户起的名字（置顶的常用片段）。
    public var title: String
    public var image: ClipImage?
    public var files: [String]
    public var appId: String?
    public var appName: String?
    /// 来源应用图标的主色，例如 `#3b82f6`。
    public var appColor: String?
    public var appIcon: Bool
    public var createdAt: Int64
    public var copiedAt: Int64
    public var copyCount: Int
    public var pinboard: String?
}

/// 写回剪贴板所需的完整内容。
public struct ClipContent: Sendable {
    public var id: String
    public var kind: String
    public var text: String
    public var html: String?
    public var image: URL?
    public var files: [String]
}

public struct ClipQuery: Codable, Hashable, Sendable {
    public var text: String?
    public var kind: String?
    /// 只看某个置顶板；`"*"` 表示所有置顶的条目。
    public var pinboard: String?
    public var app: String?
    /// 分页：只返回最近复制时间（置顶板中为置顶时间）早于此的条目。
    public var before: Int64?
    public var limit: Int?
    public init(text: String? = nil, kind: String? = nil, pinboard: String? = nil, app: String? = nil, before: Int64? = nil, limit: Int? = nil) {
        self.text = text; self.kind = kind; self.pinboard = pinboard; self.app = app; self.before = before; self.limit = limit
    }
}

public struct Pinboard: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var color: String
    public var sort: Double
    public var count: Int
}

/// 出现过的来源应用及条数。
public struct ClipApp: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var color: String?
    public var icon: Bool
    public var count: Int
}

public struct ClipStats: Codable, Hashable, Sendable {
    public var items: Int
    public var pinned: Int
    /// 图片占用的空间（字节）。
    public var imageBytes: Int64
}

public struct ClipText: Codable, Hashable, Sendable {
    public var text: String
    public var html: String?
    public init(text: String, html: String?) { self.text = text; self.html = html }
}
