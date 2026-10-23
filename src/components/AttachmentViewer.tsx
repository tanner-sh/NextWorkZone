import { useEffect, useMemo, useState } from "react";
import { ChevronLeft, ChevronRight, Copy, ExternalLink, Eye, Maximize2, Minimize2, X } from "lucide-react";
import { api, errorMessage, type Attachment, type AttachmentPreview, type Service } from "../api";
import { assetUrl } from "../lib/asset";
import { formatSize, formatTime } from "../lib/format";
import { useSettings } from "../state/settings";
import { copyText } from "../lib/clipboard";
import { Spinner } from "./common";
import type { MenuInput } from "./ContextMenu";
import { guarded, toast } from "./Toast";

/** 附件的右键菜单（Jira 问题、Wiki 页面共用）。 */
export function attachmentMenu(a: Attachment, preview: () => void, openExternal: (a: Attachment) => unknown): MenuInput[] {
  return [
    { label: "预览", icon: <Eye size={14} />, onSelect: preview },
    { label: "用系统应用打开", icon: <ExternalLink size={14} />, onSelect: () => openExternal(a) },
    "separator",
    {
      label: "复制文件名",
      icon: <Copy size={14} />,
      onSelect: guarded(async () => {
        await copyText(a.filename);
        toast("已复制");
      }),
    },
  ];
}

type Kind = "image" | "pdf" | "media" | "html" | "converted" | "none";

/** 由后端转换后预览的文件类型（与 crates/preview 一致）。 */
const CONVERTED = new Set(
  "xlsx xlsm xlsb xls ods csv tsv docx zip jar war txt log out err trace md json xml yaml yml sql ini conf cfg properties java js ts tsx jsx py rs go c h cpp cs kt sh bat cmd ps1 css vue toml gradle jsp".split(" "),
);

/** 超过这个大小的文件不在应用内预览（需要先整个下载）。 */
const MAX_PREVIEW_BYTES = 30 * 1024 * 1024;

function kindOf(a: Attachment): Kind {
  const ext = a.filename.includes(".") ? a.filename.split(".").pop()!.toLowerCase() : "";
  if (a.mimeType.startsWith("image/") && ext !== "psd") return "image";
  if (a.mimeType === "application/pdf" || ext === "pdf") return "pdf";
  if (a.mimeType.startsWith("video/") || a.mimeType.startsWith("audio/")) return "media";
  if (a.size > MAX_PREVIEW_BYTES) return "none";
  if (ext === "html" || ext === "htm" || a.mimeType === "text/html") return "html";
  if (CONVERTED.has(ext) || a.mimeType.startsWith("text/")) return "converted";
  return "none";
}

/**
 * 附件预览：图片、PDF、音视频直接显示；表格、Word、文本由后端转换后显示。
 * ← → 切换附件，Esc 关闭。
 */
export function AttachmentViewer({ attachments, index: initial, onClose, onOpenExternal, service = "jira" }: { attachments: Attachment[]; index: number; onClose: () => void; onOpenExternal: (a: Attachment) => void; service?: Service }) {
  const [index, setIndex] = useState(initial);
  const a = attachments[index];
  const count = attachments.length;
  const go = (step: number) => setIndex((i) => (i + step + count) % count);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      // 在输入框（例如筛选行）里按方向键不切换附件
      const typing = (e.target as HTMLElement).closest("input, textarea");
      if (e.key === "Escape") {
        e.stopPropagation();
        onClose();
      } else if (!typing && count > 1 && (e.key === "ArrowLeft" || e.key === "ArrowRight")) {
        e.preventDefault();
        go(e.key === "ArrowLeft" ? -1 : 1);
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [onClose, count]);

  return (
    <div className="image-viewer attachment-viewer" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="image-viewer-bar">
        {count > 1 && (
          <>
            <button className="btn subtle icon" title="上一个（←）" onClick={() => go(-1)}>
              <ChevronLeft size={18} />
            </button>
            <span className="small nowrap">
              {index + 1} / {count}
            </span>
            <button className="btn subtle icon" title="下一个（→）" onClick={() => go(1)}>
              <ChevronRight size={18} />
            </button>
          </>
        )}
        <span className="ellipsis attachment-viewer-name" title={a.filename}>
          {a.filename}
        </span>
        <span className="small nowrap viewer-meta">
          {formatSize(a.size)} · {a.author} · {formatTime(a.created)}
        </span>
        <span className="spacer" />
        <button className="btn subtle" title="下载到“下载”文件夹并用系统应用打开" onClick={() => onOpenExternal(a)}>
          <ExternalLink size={15} />
          用系统应用打开
        </button>
        <button className="btn subtle icon" title="关闭（Esc）" onClick={onClose}>
          <X size={18} />
        </button>
      </div>
      <AttachmentBody key={a.id} attachment={a} service={service} onOpenExternal={() => onOpenExternal(a)} />
    </div>
  );
}

function AttachmentBody({ attachment: a, service, onOpenExternal }: { attachment: Attachment; service: Service; onOpenExternal: () => void }) {
  const { sessionVersion } = useSettings();
  const src = assetUrl(service, a.contentUrl, sessionVersion);
  const kind = kindOf(a);
  const [actual, setActual] = useState(false);
  const [failed, setFailed] = useState(false);

  if (kind === "image") {
    return (
      <div className={`image-viewer-stage${actual ? " actual" : ""}`}>
        {failed ? <span className="muted">图片加载失败</span> : <img src={src} alt={a.filename} onClick={() => setActual((v) => !v)} onError={() => setFailed(true)} title={actual ? "点击适应窗口" : "点击查看原始大小"} />}
        <button className="btn subtle icon viewer-zoom" title={actual ? "适应窗口" : "原始大小"} onClick={() => setActual((v) => !v)}>
          {actual ? <Minimize2 size={16} /> : <Maximize2 size={16} />}
        </button>
      </div>
    );
  }
  // WKWebView 在 iframe 中不显示 PDF，embed 可以（自带缩放工具条）
  if (kind === "pdf") return <embed className="viewer-frame" type="application/pdf" src={src} title={a.filename} />;
  if (kind === "none") {
    return (
      <div className="image-viewer-stage">
        <div className="viewer-unsupported">
          <p>{a.size > MAX_PREVIEW_BYTES ? `文件较大（${formatSize(a.size)}），不在应用内预览` : "这种文件暂不支持在应用内预览"}</p>
          <button className="btn primary" onClick={onOpenExternal}>
            <ExternalLink size={14} />
            用系统应用打开
          </button>
        </div>
      </div>
    );
  }
  if (kind === "media") {
    return (
      <div className="image-viewer-stage">
        {a.mimeType.startsWith("audio/") ? <audio src={src} controls /> : <video src={src} controls className="viewer-video" />}
      </div>
    );
  }
  return <ConvertedPreview attachment={a} service={service} html={kind === "html"} onOpenExternal={onOpenExternal} />;
}

function ConvertedPreview({ attachment: a, service, html, onOpenExternal }: { attachment: Attachment; service: Service; html: boolean; onOpenExternal: () => void }) {
  const [preview, setPreview] = useState<AttachmentPreview | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    api.jiraPreviewAttachment(a.contentUrl, a.filename, a.mimeType, service).then(
      (p) => alive && setPreview(p),
      (e) => alive && setError(errorMessage(e)),
    );
    return () => {
      alive = false;
    };
  }, [a.contentUrl, a.filename, a.mimeType]);

  if (error || preview?.kind === "unsupported") {
    return (
      <div className="image-viewer-stage">
        <div className="viewer-unsupported">
          <p>{error ?? (preview as { reason: string }).reason}</p>
          <button className="btn primary" onClick={onOpenExternal}>
            <ExternalLink size={14} />
            用系统应用打开
          </button>
        </div>
      </div>
    );
  }
  if (!preview)
    return (
      <div className="image-viewer-stage">
        <div className="viewer-paper">
          <Spinner label="正在加载预览…" />
        </div>
      </div>
    );
  if (preview.kind === "text" && html) return <HtmlPreview html={preview.text} />;
  if (preview.kind === "text") return <TextPreview text={preview.text} truncated={preview.truncated} encoding={preview.encoding} />;
  if (preview.kind === "archive") return <ArchivePreview entries={preview.entries} truncated={preview.truncated} />;
  if (preview.kind === "sheet") return <SheetPreview sheets={preview.sheets} />;
  return (
    <div className="viewer-scroll">
      <div className="viewer-paper document-preview">
        {preview.paragraphs.map((p, i) => (p.trim() ? <p key={i}>{p}</p> : <br key={i} />))}
        {preview.truncated && <p className="muted small">文档较长，只显示了前面一部分。</p>}
      </div>
    </div>
  );
}

/** 网页报告：在禁止脚本的沙箱中显示，可切换查看源码。 */
function HtmlPreview({ html }: { html: string }) {
  const [source, setSource] = useState(false);
  if (source) {
    return (
      <div className="viewer-column">
        <button className="btn subtle viewer-toggle" onClick={() => setSource(false)}>
          显示网页
        </button>
        <TextPreview text={html} truncated={false} encoding="HTML" />
      </div>
    );
  }
  return (
    <div className="viewer-column">
      <button className="btn subtle viewer-toggle" onClick={() => setSource(true)}>
        查看源码
      </button>
      {/* sandbox 不含 allow-scripts：附件里的脚本不会运行 */}
      <iframe className="viewer-frame" sandbox="" srcDoc={html} title="网页附件" />
    </div>
  );
}

function ArchivePreview({ entries, truncated }: { entries: { name: string; size: number; dir: boolean }[]; truncated: boolean }) {
  const files = entries.filter((e) => !e.dir);
  return (
    <div className="viewer-scroll">
      <div className="viewer-paper archive-preview">
        <p className="muted small">
          共 {files.length} 个文件{truncated && "（只列出了前 5000 项）"}，合计 {formatSize(files.reduce((n, e) => n + e.size, 0))}
        </p>
        <ul className="archive-list">
          {entries.map((e) => (
            <li key={e.name} className={e.dir ? "dir" : ""}>
              <span className="ellipsis" style={{ paddingLeft: (e.name.replace(/\/$/, "").split("/").length - 1) * 16 }}>
                {e.name.replace(/\/$/, "").split("/").pop()}
                {e.dir && "/"}
              </span>
              {!e.dir && <span className="muted small nowrap">{formatSize(e.size)}</span>}
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}

/** 最多显示的行数，避免超大日志卡住界面。 */
const MAX_LINES = 20000;

function TextPreview({ text, truncated, encoding }: { text: string; truncated: boolean; encoding: string }) {
  const [filter, setFilter] = useState("");
  const [wrap, setWrap] = useState(true);
  const lines = useMemo(() => text.split(/\r?\n/), [text]);
  const q = filter.trim().toLowerCase();
  const shown = useMemo(() => {
    const all = lines.map((line, i) => ({ line, no: i + 1 }));
    return (q ? all.filter((l) => l.line.toLowerCase().includes(q)) : all).slice(0, MAX_LINES);
  }, [lines, q]);

  return (
    <div className="viewer-scroll">
      <div className="viewer-paper text-preview">
        <div className="text-preview-bar">
          <input value={filter} placeholder="只看包含这段文字的行，例如 ERROR、Exception" onChange={(e) => setFilter(e.target.value)} />
          <label className="checkbox small">
            <input type="checkbox" checked={wrap} onChange={(e) => setWrap(e.target.checked)} />
            自动换行
          </label>
          <span className="muted small nowrap">
            {q ? `${shown.length} / ${lines.length} 行` : `${lines.length} 行`} · {encoding}
          </span>
        </div>
        {truncated && <p className="notice warn small">文件较大，只显示了前 2 MB。</p>}
        <pre className={`text-lines${wrap ? " wrap" : ""}`}>
          {shown.map((l) => (
            <div key={l.no} className="text-line">
              <span className="line-no">{l.no}</span>
              <span>{q ? highlight(l.line, q) : l.line || " "}</span>
            </div>
          ))}
        </pre>
      </div>
    </div>
  );
}

function highlight(line: string, q: string) {
  const parts: React.ReactNode[] = [];
  const lower = line.toLowerCase();
  let from = 0;
  for (let at = lower.indexOf(q); at >= 0; at = lower.indexOf(q, from)) {
    parts.push(line.slice(from, at), <mark key={at}>{line.slice(at, at + q.length)}</mark>);
    from = at + q.length;
  }
  parts.push(line.slice(from));
  return parts;
}

/** A、B … Z、AA … */
function columnName(i: number): string {
  let name = "";
  for (let n = i + 1; n > 0; n = Math.floor((n - 1) / 26)) name = String.fromCharCode(65 + ((n - 1) % 26)) + name;
  return name;
}

function SheetPreview({ sheets }: { sheets: { name: string; rows: string[][]; totalRows: number; totalCols: number }[] }) {
  const [active, setActive] = useState(0);
  const sheet = sheets[active];
  const width = Math.max(0, ...sheet.rows.map((r) => r.length));
  return (
    <div className="viewer-scroll sheet-scroll">
      <div className="viewer-paper sheet-preview">
        {sheets.length > 1 && (
          <div className="segmented sheet-tabs">
            {sheets.map((s, i) => (
              <button key={s.name} className={i === active ? "active" : ""} onClick={() => setActive(i)}>
                {s.name}
              </button>
            ))}
          </div>
        )}
        {(sheet.totalRows > sheet.rows.length || sheet.totalCols > width) && sheet.rows.length > 0 && (
          <p className="notice warn small">
            表格较大（{sheet.totalRows} 行 × {sheet.totalCols} 列），只显示了前 {sheet.rows.length} 行。
          </p>
        )}
        {sheet.rows.length === 0 ? (
          <p className="muted">这个工作表是空的</p>
        ) : (
          <div className="sheet-table-wrap">
            <table className="sheet-table">
              <thead>
                <tr>
                  <th />
                  {Array.from({ length: width }, (_, i) => (
                    <th key={i}>{columnName(i)}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {sheet.rows.map((row, r) => (
                  <tr key={r}>
                    <th>{r + 1}</th>
                    {Array.from({ length: width }, (_, c) => (
                      <td key={c} title={row[c] && row[c].length > 40 ? row[c] : undefined}>
                        {row[c] ?? ""}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
