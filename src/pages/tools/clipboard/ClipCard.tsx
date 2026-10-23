import { useMemo, type ReactNode } from "react";
import hljs from "highlight.js/lib/common";
import { AppWindow, File, Folder, Pin } from "lucide-react";
import type { ClipItem, IssueHit, Pinboard, Service } from "../../../api";
import { StatusPill } from "../../../components/common";
import { clipAssetUrl } from "../../../lib/asset";
import { colorFormats, fileName, headColor, hostOf, inAppLabel, KIND_META, metaLine, MOD, readableOn, timeLabel } from "./clip";

/** 来源应用的图标；没有图标时显示名称首字。 */
export function AppIcon({ item, size = 28 }: { item: Pick<ClipItem, "appId" | "appName" | "appIcon" | "appColor">; size?: number }) {
  if (item.appIcon && item.appId) return <img className="clip-app-icon" src={clipAssetUrl("icon", item.appId)} width={size} height={size} alt="" draggable={false} />;
  const name = item.appName ?? "?";
  return (
    <span className="clip-app-icon letter" style={{ width: size, height: size, fontSize: size * 0.45, background: item.appColor ?? "var(--faint)" }}>
      {name.slice(0, 1).toUpperCase()}
    </span>
  );
}

/** 把搜索词标出来。 */
export function Highlight({ text, query }: { text: string; query: string }) {
  const q = query.trim();
  if (!q) return <>{text}</>;
  const parts: ReactNode[] = [];
  const lower = text.toLowerCase();
  const needle = q.toLowerCase();
  let at = 0;
  for (let i = lower.indexOf(needle); i >= 0 && parts.length < 40; i = lower.indexOf(needle, at)) {
    if (i > at) parts.push(text.slice(at, i));
    parts.push(<mark key={i}>{text.slice(i, i + q.length)}</mark>);
    at = i + q.length;
  }
  parts.push(text.slice(at));
  return <>{parts}</>;
}

function IssueLine({ issue }: { issue: IssueHit }) {
  return (
    <div className="clip-issue">
      <span className="clip-issue-key">{issue.key}</span>
      <StatusPill status={issue.status} />
      <span className="clip-issue-summary">{issue.summary}</span>
    </div>
  );
}

interface CardProps {
  item: ClipItem;
  /** 在列表中的序号，前 9 个显示 ⌘1–⌘9 */
  index: number;
  selected: boolean;
  /** 多选时的序号（从 1 开始） */
  marked: number | null;
  query: string;
  issues: IssueHit[];
  board: Pinboard | undefined;
  baseUrl: (service: Service) => string;
  onClick: (e: React.MouseEvent) => void;
  onDoubleClick: () => void;
  onContextMenu: (e: React.MouseEvent) => void;
  onMouseDown: (e: React.MouseEvent) => void;
  /** 图片、文件不用网页拖放（见 drag.ts） */
  draggable: boolean;
  onDragStart: (e: React.DragEvent) => void;
  onDragEnd: (e: React.DragEvent) => void;
}

/** 面板中的一张卡片：标题栏是来源应用的颜色，正文按类型显示。 */
export function ClipCard(props: CardProps) {
  const { item } = props;
  const color = headColor(item);
  const meta = KIND_META[item.kind];
  return (
    <div
      className={`clip-card${props.selected ? " selected" : ""}${props.marked ? " marked" : ""}`}
      style={{ "--clip-head": color, "--clip-head-text": readableOn(color), "--clip-i": Math.min(props.index, 12) } as React.CSSProperties}
      data-id={item.id}
      draggable={props.draggable}
      onMouseDown={props.onMouseDown}
      onDragStart={props.onDragStart}
      onDragEnd={props.onDragEnd}
      onClick={props.onClick}
      onDoubleClick={props.onDoubleClick}
      onContextMenu={props.onContextMenu}
    >
      <div className="clip-card-head">
        <div className="clip-card-title">
          <b>{item.title || meta.label}</b>
          <span>{timeLabel(item.copiedAt)}</span>
        </div>
        {props.board && <Pin size={12} className="clip-card-pin" style={{ color: props.board.color }} aria-label={`置顶于 ${props.board.name}`} />}
        <AppIcon item={item} />
      </div>
      <div className={`clip-card-body kind-${item.kind}`}>
        <CardBody {...props} />
      </div>
      <div className="clip-card-foot">
        <span className="ellipsis">{metaLine(item)}</span>
        {props.marked ? <span className="clip-mark">{props.marked}</span> : props.index < 9 ? <kbd>{`${MOD}${props.index + 1}`}</kbd> : null}
      </div>
    </div>
  );
}

function CardBody({ item, query, issues, baseUrl }: CardProps) {
  switch (item.kind) {
    case "image":
      return <img className="clip-thumb" src={clipAssetUrl("thumb", item.id)} alt="" draggable={false} loading="lazy" />;
    case "color":
      return (
        <div className="clip-color" style={{ background: item.text.trim() }}>
          <span style={{ color: readableOn(colorFormats(item.text)?.hex ?? "#000") }}>{item.text.trim()}</span>
        </div>
      );
    case "file":
      return <FileList files={item.files} limit={5} />;
    case "link": {
      const label = inAppLabel(item.text, baseUrl);
      return (
        <div className="clip-link">
          <div className="clip-link-host">{hostOf(item.text) ?? item.text}</div>
          <div className="clip-link-url">
            <Highlight text={item.text.trim()} query={query} />
          </div>
          {label && (
            <div className="clip-link-app">
              <AppWindow size={12} />
              {label}
            </div>
          )}
          {issues[0] && <IssueLine issue={issues[0]} />}
        </div>
      );
    }
    default:
      return (
        <>
          {issues.map((i) => (
            <IssueLine key={i.key} issue={i} />
          ))}
          <div className={`clip-text${item.kind === "code" ? " mono" : ""}`}>
            <Highlight text={item.text.slice(0, 600)} query={query} />
          </div>
        </>
      );
  }
}

function FileList({ files, limit }: { files: string[]; limit?: number }) {
  const shown = limit ? files.slice(0, limit) : files;
  return (
    <ul className="clip-files">
      {shown.map((f) => {
        const name = fileName(f);
        const folder = !/\.[^./\\]+$/.test(name);
        return (
          <li key={f} title={f}>
            {folder ? <Folder size={14} /> : <File size={14} />}
            <span className="ellipsis">{name}</span>
          </li>
        );
      })}
      {limit && files.length > limit && <li className="muted">还有 {files.length - limit} 个…</li>}
    </ul>
  );
}

/** 只对代码做高亮：常见语言自动识别。 */
function CodeBlock({ text }: { text: string }) {
  const html = useMemo(() => {
    if (text.length > 60_000) return null;
    try {
      return hljs.highlightAuto(text, ["json", "javascript", "typescript", "sql", "java", "python", "rust", "go", "xml", "bash", "yaml", "css", "kotlin", "cpp"]).value;
    } catch {
      return null;
    }
  }, [text]);
  return html ? <pre className="clip-preview-text mono hljs" dangerouslySetInnerHTML={{ __html: html }} /> : <pre className="clip-preview-text mono">{text}</pre>;
}

/** 完整内容的预览（面板的预览层、应用内页面的详情）。`text` 是完整文字。 */
export function ClipPreviewBody({ item, text, issues, baseUrl }: { item: ClipItem; text: string; issues: IssueHit[]; baseUrl: (service: Service) => string }) {
  switch (item.kind) {
    case "image":
      return (
        <div className="clip-preview-image">
          <img src={clipAssetUrl("image", item.id)} alt="" draggable={false} />
        </div>
      );
    case "color": {
      const formats = colorFormats(text);
      return (
        <div className="clip-preview-color">
          <div className="swatch" style={{ background: text.trim() }} />
          {formats && (
            <dl>
              {Object.entries(formats).map(([k, v]) => (
                <div key={k}>
                  <dt>{k.toUpperCase()}</dt>
                  <dd>{v}</dd>
                </div>
              ))}
            </dl>
          )}
        </div>
      );
    }
    case "file":
      return (
        <ul className="clip-files full">
          {item.files.map((f) => (
            <li key={f}>
              <File size={14} />
              <span>{f}</span>
            </li>
          ))}
        </ul>
      );
    case "code":
      return (
        <>
          {issues.map((i) => (
            <IssueLine key={i.key} issue={i} />
          ))}
          <CodeBlock text={text} />
        </>
      );
    default: {
      const label = item.kind === "link" ? inAppLabel(text, baseUrl) : null;
      return (
        <>
          {issues.map((i) => (
            <IssueLine key={i.key} issue={i} />
          ))}
          {label && (
            <div className="clip-link-app">
              <AppWindow size={12} />
              {label}
            </div>
          )}
          <pre className="clip-preview-text">{text}</pre>
        </>
      );
    }
  }
}
