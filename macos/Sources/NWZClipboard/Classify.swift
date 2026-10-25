import Foundation

/// 判断一段文字的类型：链接、颜色、代码或普通文本。用于卡片的显示样式和按类型筛选。
public enum ClipKind {
    public static let text = "text"
    public static let link = "link"
    public static let code = "code"
    public static let color = "color"
    public static let image = "image"
    public static let file = "file"

    public static let all = [text, link, code, color, image, file]

    nonisolated(unsafe) private static let colorPattern = /(?i)^(#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})|(?:rgba?|hsla?)\(\s*[0-9.]+%?\s*[, ]\s*[0-9.]+%?\s*[, ]\s*[0-9.]+%?\s*(?:[,\/]\s*[0-9.]+%?\s*)?\))$/
    nonisolated(unsafe) private static let linkPattern = /(?i)^(?:(?:https?|ftp):\/\/|www\.)\S+$/
    nonisolated(unsafe) private static let sqlPattern = /(?is)^\s*(select\s.+\sfrom\s|insert\s+into\s|update\s+\S+\s+set\s|delete\s+from\s|create\s+(table|index|view)\s|alter\s+table\s|with\s+\w+\s+as\s*\()/
    nonisolated(unsafe) private static let codeLinePattern = /^\s*(?:(?:pub\s+)?fn\s|function\b|def\s|class\s|import\s|from\s+\S+\s+import|export\s|const\s|let\s|var\s|return\b|public\s|private\s|protected\s|package\s|#include|using\s|if\s*\(|for\s*\(|while\s*\(|\}|\/\/|\/\*|\*|#!|<\?|<[a-zA-Z][\w-]*[\s>\/])/

    /// 文字内容的类型。
    public static func of(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return Self.text }
        if trimmed.utf8.count <= 40, trimmed.wholeMatch(of: colorPattern) != nil { return color }
        if trimmed.wholeMatch(of: linkPattern) != nil { return link }
        if looksLikeCode(trimmed) { return code }
        return Self.text
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        if (text.hasPrefix("{") && text.hasSuffix("}") || text.hasPrefix("[") && text.hasSuffix("]")), text.utf8.count > 2,
           (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil {
            return true
        }
        if text.prefixMatch(of: sqlPattern) != nil { return true }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return false }
        let codeish = lines.filter { line in
            let t = line.replacing(/\s+$/, with: "")
            return line.prefixMatch(of: codeLinePattern) != nil || t.hasSuffix(";") || t.hasSuffix("{") || t.hasSuffix("=>") || t.hasSuffix(")") && t.contains("(")
        }.count
        // 中文段落几乎不会以分号、括号结尾；多数行像代码才算
        return codeish * 2 >= lines.count && codeish >= 2
    }
}
