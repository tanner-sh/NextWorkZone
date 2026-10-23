import { useMemo } from "react";
import hljs from "highlight.js/lib/common";

/** 超过这个大小的文件不做语法高亮，避免卡顿。 */
const HIGHLIGHT_LIMIT = 300 * 1024;

const EXTENSION_LANGUAGES: Record<string, string> = {
  java: "java", kt: "kotlin", groovy: "java", gradle: "java", scala: "scala",
  js: "javascript", jsx: "javascript", mjs: "javascript", cjs: "javascript", ts: "typescript", tsx: "typescript", vue: "xml",
  py: "python", rb: "ruby", go: "go", rs: "rust", c: "c", h: "c", cpp: "cpp", hpp: "cpp", cs: "csharp", php: "php", swift: "swift",
  sql: "sql", xml: "xml", html: "xml", htm: "xml", svg: "xml", xsd: "xml", wsdl: "xml",
  css: "css", scss: "scss", less: "less", json: "json", yml: "yaml", yaml: "yaml", toml: "ini", ini: "ini", properties: "ini", conf: "ini",
  md: "markdown", sh: "bash", bash: "bash", zsh: "bash", bat: "dos", cmd: "dos", ps1: "powershell", dockerfile: "dockerfile",
};

export function languageOf(path: string): string | null {
  const name = path.split("/").pop()?.toLowerCase() ?? "";
  if (name === "dockerfile") return "dockerfile";
  if (name === "makefile") return "makefile";
  const ext = name.includes(".") ? name.split(".").pop()! : "";
  const lang = EXTENSION_LANGUAGES[ext];
  return lang && hljs.getLanguage(lang) ? lang : null;
}

export function highlight(code: string, lang: string | null): string | null {
  if (!lang || code.length > HIGHLIGHT_LIMIT) return null;
  try {
    return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
  } catch {
    return null;
  }
}

export function CodeView({ code, path }: { code: string; path: string }) {
  const html = useMemo(() => highlight(code, languageOf(path)), [code, path]);
  const lineCount = useMemo(() => code.split("\n").length - (code.endsWith("\n") ? 1 : 0), [code]);

  return (
    <div className="code-view">
      <pre className="gutter" aria-hidden>
        {Array.from({ length: Math.max(lineCount, 1) }, (_, i) => i + 1).join("\n")}
      </pre>
      {html !== null ? (
        <pre className="code hljs">
          <code dangerouslySetInnerHTML={{ __html: html }} />
        </pre>
      ) : (
        <pre className="code">
          <code>{code}</code>
        </pre>
      )}
    </div>
  );
}
