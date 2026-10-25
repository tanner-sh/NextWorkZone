import Foundation
import NWZCore
import NWZPreview

/// 过渡期由现有会话层提供网页资源，接口不接触文档解析。
public protocol WebResourceSource: Sendable {
    func fetch(service: Service, url: String) async throws -> (Data, String?)
}

public struct AttachmentService: Sendable {
    let settings: SettingsService
    let web: any WebResourceSource
    let host: any AppHost
    public init(settings: SettingsService, web: any WebResourceSource, host: any AppHost) { self.settings = settings; self.web = web; self.host = host }
    public func fetch(service: Service, url: String) async throws -> (Data, String?) {
        let base = try settings.configuration.snapshot().baseURL(for: service)
        guard let baseURL = URL(string: base), let target = URL(string: url, relativeTo: baseURL.appendingPathComponent("/"))?.absoluteURL,
              target.host?.lowercased() == baseURL.host?.lowercased(), target.scheme == baseURL.scheme, target.port == baseURL.port,
              target.user == nil, target.password == nil else { throw NWZError.invalidURL(url) }
        return try await web.fetch(service: service, url: target.absoluteString)
    }
    public func preview(service: Service, url: String, filename: String, mime: String) async throws -> AttachmentPreview {
        let (data, _) = try await fetch(service: service, url: url)
        return await Task.detached { Previewer.preview(filename: filename, mime: mime, data: data) }.value
    }
    public func open(service: Service, url: String, filename: String) async throws -> String {
        let (data, _) = try await fetch(service: service, url: url)
        let directory = settings.paths.home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = URL(fileURLWithPath: filename).lastPathComponent
        let safeName = name.isEmpty || [".", "..", "/"].contains(name) ? "attachment" : name
        let original = directory.appendingPathComponent(safeName)
        var candidate = original, number = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let ext = original.pathExtension
            candidate = directory.appendingPathComponent(original.deletingPathExtension().lastPathComponent + " (\(number))" + (ext.isEmpty ? "" : "." + ext)); number += 1
        }
        try data.write(to: candidate, options: .withoutOverwriting)
        if let error = host.openPath(path: candidate.path) { throw NWZError.other(error) }
        return candidate.path
    }
    public func savePastedImage(base64: String, filename: String) throws -> String {
        guard let data = Data(base64Encoded: base64) else { throw NWZError.other("图片数据格式不正确") }
        let name = String(filename.filter { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) })
        let directory = settings.paths.cache.appendingPathComponent("pasted", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name.isEmpty || [".", ".."].contains(name) ? "image.png" : name)
        try data.write(to: path, options: .atomic)
        return path.path
    }
    public static func localImagePreview(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path), ext = url.pathExtension.lowercased()
        guard let mime = ["png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "gif":"image/gif", "webp":"image/webp", "bmp":"image/bmp"][ext],
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 10 * 1024 * 1024,
              let data = try? Data(contentsOf: url), data.count <= 10 * 1024 * 1024 else { return nil }
        return "data:\(mime);base64," + data.base64EncodedString()
    }
}
