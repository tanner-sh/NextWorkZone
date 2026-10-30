import Foundation

/// 本地索引共用的文本处理。
public enum TextFold {
    /// 逐个字符转小写，字符个数不变（SQLite 的 instr 位置可以直接对应原文）。
    /// 结果与 `String(scalar).lowercased()` 的第一个字符相同，但不为每个字符创建字符串：同步时要处理几百万字的正文。
    public static func fold(_ text: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars { UTF8.encode(fold(scalar)) { bytes.append($0) } }
        return String(decoding: bytes, as: UTF8.self)
    }

    @inline(__always)
    public static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let value = scalar.value
        if value < 0x80 { return value >= 65 && value <= 90 ? Unicode.Scalar(UInt8(value + 32)) : scalar }
        // 中日韩文字、谚文没有大小写，跳过较慢的字符属性查询
        if (0x3000..<0xA640).contains(value) || (0xAC00..<0xD800).contains(value) { return scalar }
        guard scalar.properties.changesWhenLowercased else { return scalar }
        return scalar.properties.lowercaseMapping.unicodeScalars.first ?? scalar
    }
}

/// 三个系统返回的时间。格式器创建很慢（每次约 0.1 毫秒），同步和排序时要解析成千上万次，所以只创建一次；
/// 格式器可以在多个线程中同时使用，创建后不再修改。
public enum ServerTime {
    nonisolated(unsafe) private static let formatters: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"].map {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = $0
        return formatter
    }
    nonisolated(unsafe) private static let iso: [ISO8601DateFormatter] = ([[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] as [ISO8601DateFormatter.Options]).map {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = $0
        return formatter
    }

    /// Jira、GitLab 的时间（`+0800` 或 `+08:00` 形式的时区，可带毫秒）。
    public static func parse(_ value: String) -> Date? {
        for formatter in formatters { if let date = formatter.date(from: value) { return date } }
        return nil
    }

    /// ISO 8601 时间（Wiki 返回的形式）。
    public static func iso8601(_ value: String) -> Date? {
        for formatter in iso { if let date = formatter.date(from: value) { return date } }
        return nil
    }
}
