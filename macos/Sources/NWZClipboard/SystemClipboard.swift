import Foundation

/// 剪贴板中的一份内容。同一份内容可能同时带有多种格式（例如网页上复制的文字同时有纯文本和 HTML）。
public struct ClipboardSnapshot: Sendable {
    public var text: String?
    public var html: String?
    public var image: RGBAImage?
    public var files: [String]
    public init(text: String? = nil, html: String? = nil, image: RGBAImage? = nil, files: [String] = []) {
        self.text = text; self.html = html; self.image = image; self.files = files
    }
    public var isEmpty: Bool { text == nil && image == nil && files.isEmpty }
}

/// 一个正在运行的应用。
public struct RunningApp: Sendable, Equatable {
    /// Bundle ID；没有时为应用路径。
    public var id: String
    public var name: String
    /// .app 包的路径，用于读取图标。
    public var path: String?
    public var pid: Int32?
    public init(id: String, name: String, path: String? = nil, pid: Int32? = nil) { self.id = id; self.name = name; self.path = path; self.pid = pid }
}

/// 剪贴板历史需要的系统能力，由界面层用 AppKit 实现；测试中用内存实现代替。
public protocol SystemClipboard: Sendable {
    /// 剪贴板的变化序号，每次有应用写入剪贴板都会增加。
    func changeCount() -> Int
    /// 当前内容被写入方标记为敏感或临时内容（见 [`ClipPrivacy.concealedTypes`]）。
    func isConcealed() -> Bool
    /// 读取当前内容。`withImage` 为 false 时不读图片（图片解码较慢）。
    func read(withImage: Bool) -> ClipboardSnapshot
    /// 写入文字；有 HTML 时同时写入，粘贴到支持格式的应用会保留格式。返回写入后的变化序号。
    func write(text: String, html: String?) -> Int
    func write(imagePNG: Data) -> Int
    func write(files: [String]) -> Int

    func frontmostApp() -> RunningApp?
    /// 文件或应用在系统中的图标（PNG），边长约为 `size` 像素。
    func iconPNG(path: String, size: Int) -> Data?
    /// 是否已获得“辅助功能”权限（模拟按键需要）。
    func canPaste() -> Bool
    /// 弹出授权提示并打开对应的系统设置页面。
    func requestPastePermission()
    /// 向当前前台应用发送 ⌘V。
    func sendPaste()
}
