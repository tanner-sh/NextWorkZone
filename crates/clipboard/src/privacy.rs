//! 隐私保护：不记录疑似密钥、密码的内容，默认忽略密码管理器。

use std::sync::LazyLock;

use regex::Regex;

/// 默认不记录的应用（标识, 名称）：常见的密码管理器。macOS 上是 Bundle ID，Windows 上是可执行文件名。
pub const DEFAULT_IGNORED_APPS: &[(&str, &str)] = &[
    ("com.1password.1password", "1Password"),
    ("com.agilebits.onepassword7", "1Password 7"),
    ("com.bitwarden.desktop", "Bitwarden"),
    ("org.keepassxc.keepassxc", "KeePassXC"),
    ("com.apple.keychainaccess", "钥匙串访问"),
    ("com.apple.Passwords", "密码"),
    ("com.lastpass.LastPass", "LastPass"),
    ("in.sinew.Enpass-Desktop", "Enpass"),
    ("1password.exe", "1Password"),
    ("bitwarden.exe", "Bitwarden"),
    ("keepassxc.exe", "KeePassXC"),
    ("keepass.exe", "KeePass"),
];

/// 常见服务的令牌、私钥格式（公开的前缀规则）。
static SECRET_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(concat!(
        r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
        r"|\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b",
        r"|\bgithub_pat_[A-Za-z0-9_]{60,}",
        r"|\bglpat-[A-Za-z0-9_\-]{20,}",
        r"|\bxox[abposr]-[A-Za-z0-9\-]{10,}",
        r"|\bAKIA[0-9A-Z]{16}\b",
        r"|\bAIza[0-9A-Za-z_\-]{35}\b",
        r"|\bsk-(?:proj-|ant-)?[A-Za-z0-9_\-]{32,}",
    ))
    .unwrap()
});

/// 内容疑似密钥或密码：包含已知格式的令牌、私钥，或是一段像随机密码的短文字。
pub fn looks_secret(text: &str) -> bool {
    SECRET_RE.is_match(text) || looks_like_password(text.trim())
}

/// 8–64 个字符、没有空白、同时包含大写字母、小写字母、数字和符号，且不像地址、路径或邮箱。
fn looks_like_password(text: &str) -> bool {
    let len = text.chars().count();
    if !(8..=64).contains(&len) || text.chars().any(|c| c.is_whitespace() || !c.is_ascii()) {
        return false;
    }
    if text.contains("://") || text.starts_with('/') || text.starts_with('~') || text.contains('\\') || text.contains('@') && text.contains('.') {
        return false;
    }
    let upper = text.chars().any(|c| c.is_ascii_uppercase());
    let lower = text.chars().any(|c| c.is_ascii_lowercase());
    let digit = text.chars().any(|c| c.is_ascii_digit());
    let symbol = text.chars().any(|c| c.is_ascii_punctuation() && !matches!(c, '_' | '-' | '.'));
    upper && lower && digit && symbol
}

#[cfg(test)]
mod tests {
    use super::looks_secret;

    #[test]
    fn detects_secrets() {
        assert!(looks_secret("token = glpat-abcdefghijklmnopqrstu"));
        assert!(looks_secret("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"));
        assert!(looks_secret(&format!("ghp_{}", "a".repeat(36))));
        assert!(looks_secret("AKIAABCDEFGHIJKLMNOP"));
        assert!(looks_secret("Xk9#mP2$vL"));
        assert!(!looks_secret("PROJ-123"));
        assert!(!looks_secret("https://example.com/Path?a=1&B=2"));
        assert!(!looks_secret("hello world"));
        assert!(!looks_secret("user.Name@example.com"));
        assert!(!looks_secret("getUserName()"));
        assert!(!looks_secret("今天的会议纪要"));
    }
}
