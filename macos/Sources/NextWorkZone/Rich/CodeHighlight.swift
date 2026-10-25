import AppKit

/// 代码高亮：注释、字符串、数字、常见关键字。不追求完整的语法分析，只让代码更易读。
enum CodeHighlight {
    private static let keywords: Set<String> = Set("""
    abstract and as async await boolean break byte case catch char class const continue def default defer del do double elif else enum export extends false final finally float fn for from func function go goto if impl import in instanceof int interface is let long loop match mod module mut namespace new nil none not null object or override package private protected pub public return self short static struct super switch synchronized this throw throws trait true try type typeof undefined unsafe use val var void volatile where while with yield select insert update delete into values set join left right inner outer on group by order having limit union create table alter drop index primary key foreign references begin commit rollback declare procedure
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    // 规则创建后不再修改，可以在多个线程中同时使用
    nonisolated(unsafe) private static let patterns: [(Regex<Substring>, NSColor)] = [
        (try! Regex(#"//[^\n ]*|#(?!include)[^\n ]*|--[^\n ]*|/\*[\s\S]*?\*/"#), .systemGreen),
        (try! Regex(#""(?:\\.|[^"\\\n ])*"|'(?:\\.|[^'\\\n ])*'|`[^`]*`"#), .systemRed),
        (try! Regex(#"\b\d+(?:\.\d+)?\b"#), .systemPurple),
    ]

    static func apply(_ text: NSMutableAttributedString, lang: String, font: NSFont) {
        let s = text.string
        guard s.count < 200_000 else { return }
        let ns = s as NSString
        var painted = IndexSet()
        let sqlLike = ["sql", "plsql"].contains(lang.lowercased())
        for (regex, color) in patterns {
            for m in s.matches(of: regex) {
                let r = NSRange(m.range, in: s)
                // 已经是注释或字符串的部分不再上色
                if painted.contains(integersIn: r.location..<r.location + max(r.length, 1)) { continue }
                // # 和 -- 开头的注释只在部分语言中有效
                let token = ns.substring(with: r)
                if token.hasPrefix("#") && !["python", "py", "bash", "sh", "shell", "yaml", "yml", "ruby", "perl", "properties", "toml", "conf"].contains(lang.lowercased()) { continue }
                if token.hasPrefix("--") && !sqlLike && lang.lowercased() != "lua" { continue }
                text.addAttribute(.foregroundColor, value: color, range: r)
                painted.insert(integersIn: r.location..<r.location + r.length)
            }
        }
        let bold = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
        for m in s.matches(of: /[A-Za-z_][A-Za-z0-9_]*/) {
            let word = String(s[m.range])
            guard keywords.contains(sqlLike ? word.lowercased() : word) else { continue }
            let r = NSRange(m.range, in: s)
            if painted.contains(integersIn: r.location..<r.location + r.length) { continue }
            text.addAttributes([.foregroundColor: NSColor.systemBlue, .font: bold], range: r)
        }
    }
}
