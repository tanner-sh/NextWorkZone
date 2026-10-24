import { Fragment, useMemo, useState, type ReactNode } from "react";
import { ChevronDown, ChevronRight, MessageSquarePlus } from "lucide-react";
import type { FileDiff } from "../../api";
import { CommentBox } from "../../components/CommentBox";

interface DiffRow {
  kind: "hunk" | "add" | "del" | "ctx";
  oldNo: number | null;
  newNo: number | null;
  text: string;
}

/** 解析统一 diff 格式（GitLab 返回的 diff 不含文件头，直接从 @@ 开始）。 */
export function parseDiff(diff: string): DiffRow[] {
  const rows: DiffRow[] = [];
  let oldNo = 0;
  let newNo = 0;
  for (const line of diff.split("\n")) {
    const hunk = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
    if (hunk) {
      oldNo = Number(hunk[1]);
      newNo = Number(hunk[2]);
      rows.push({ kind: "hunk", oldNo: null, newNo: null, text: line });
    } else if (line.startsWith("+")) {
      rows.push({ kind: "add", oldNo: null, newNo: newNo++, text: line.slice(1) });
    } else if (line.startsWith("-")) {
      rows.push({ kind: "del", oldNo: oldNo++, newNo: null, text: line.slice(1) });
    } else if (line.startsWith("\\")) {
      continue; // \ No newline at end of file
    } else if (rows.length > 0 || line !== "") {
      rows.push({ kind: "ctx", oldNo: oldNo++, newNo: newNo++, text: line.slice(1) });
    }
  }
  // 末尾的空行来自 diff 文本结尾的换行
  while (rows.length > 0 && rows[rows.length - 1].kind === "ctx" && rows[rows.length - 1].text === "") rows.pop();
  return rows;
}

/** 行数超过这个值的文件默认折叠。 */
const COLLAPSE_ROWS = 400;

/** 改动中的一行：新文件的行号优先，删除的行用旧文件行号。 */
export interface DiffLine {
  oldLine: number | null;
  newLine: number | null;
}

/** 行的定位键，与 `lineKeyOf` 对应，用于把评论挂到行下面。 */
function rowKey(path: string, row: DiffRow): string | null {
  if (row.kind === "hunk") return null;
  return row.newNo !== null ? `${path}\n+${row.newNo}` : `${path}\n-${row.oldNo}`;
}

export function lineKeyOf(path: string, line: DiffLine): string {
  return line.newLine !== null ? `${path}\n+${line.newLine}` : `${path}\n-${line.oldLine}`;
}

/**
 * 行内评论（合并请求）：`threads` 按 `lineKeyOf` 的键放在对应行下面；
 * 提供 `onComment` 时，鼠标移到行上可以在该行发表评论。
 */
export interface DiffAnnotations {
  threads: Map<string, ReactNode>;
  onComment?: (diff: FileDiff, line: DiffLine, body: string) => Promise<void>;
}

export function DiffList({ diffs, annotations }: { diffs: FileDiff[]; annotations?: DiffAnnotations }) {
  return (
    <div className="diff-list">
      <ul className="diff-files">
        {diffs.map((d, i) => (
          <li key={i}>
            <a href={`#diff-${i}`} onClick={(e) => {
              e.preventDefault();
              document.getElementById(`diff-${i}`)?.scrollIntoView({ behavior: "smooth" });
            }}>
              <FileBadge diff={d} /> {d.newPath}
            </a>
          </li>
        ))}
      </ul>
      {diffs.map((d, i) => (
        <FileDiffView key={i} id={`diff-${i}`} diff={d} annotations={annotations} />
      ))}
    </div>
  );
}

function FileBadge({ diff }: { diff: FileDiff }) {
  if (diff.newFile) return <span className="badge add">新增</span>;
  if (diff.deletedFile) return <span className="badge del">删除</span>;
  if (diff.renamedFile) return <span className="badge">重命名</span>;
  return <span className="badge">修改</span>;
}

function FileDiffView({ id, diff, annotations }: { id: string; diff: FileDiff; annotations?: DiffAnnotations }) {
  const rows = useMemo(() => parseDiff(diff.diff), [diff.diff]);
  const threads = annotations?.threads;
  const hasThreads = useMemo(() => !!threads && [...threads.keys()].some((k) => k.startsWith(`${diff.newPath}\n`)), [threads, diff.newPath]);
  const [open, setOpen] = useState(rows.length <= COLLAPSE_ROWS || hasThreads);
  const [composing, setComposing] = useState<number | null>(null);
  const onComment = annotations?.onComment;
  const added = rows.filter((r) => r.kind === "add").length;
  const removed = rows.filter((r) => r.kind === "del").length;

  return (
    <div className="file-diff" id={id}>
      <button className="file-diff-header" onClick={() => setOpen((v) => !v)}>
        {open ? <ChevronDown size={15} /> : <ChevronRight size={15} />}
        <FileBadge diff={diff} />
        <span className="ellipsis">{diff.renamedFile ? `${diff.oldPath} → ${diff.newPath}` : diff.newPath}</span>
        <span className="spacer" />
        {hasThreads && <MessageSquarePlus size={14} className="muted" />}
        <span className="diff-stat add">+{added}</span>
        <span className="diff-stat del">−{removed}</span>
      </button>
      {open &&
        (rows.length === 0 ? (
          <p className="muted small diff-empty">没有可显示的文本改动（可能是二进制文件或改动过大）。</p>
        ) : (
          <table className="diff-table">
            <tbody>
              {rows.map((r, i) => {
                const key = rowKey(diff.newPath, r);
                const thread = key ? threads?.get(key) : undefined;
                return (
                  <Fragment key={i}>
                    <tr className={r.kind}>
                      <td className="ln">{r.oldNo ?? ""}</td>
                      <td className="ln">
                        {r.newNo ?? ""}
                        {onComment && key && (
                          <button className="line-comment" title="评论这一行" onClick={() => setComposing(composing === i ? null : i)}>
                            <MessageSquarePlus size={12} />
                          </button>
                        )}
                      </td>
                      <td className="mark">{r.kind === "add" ? "+" : r.kind === "del" ? "−" : ""}</td>
                      <td className="src">{r.text}</td>
                    </tr>
                    {thread && (
                      <tr className="diff-thread">
                        <td colSpan={4}>{thread}</td>
                      </tr>
                    )}
                    {composing === i && onComment && (
                      <tr className="diff-thread">
                        <td colSpan={4}>
                          <CommentBox
                            placeholder={`评论第 ${r.newNo ?? r.oldNo} 行（Ctrl+Enter 发送，Esc 取消）`}
                            onCancel={() => setComposing(null)}
                            onSubmit={async (body) => {
                              await onComment(diff, { oldLine: r.kind === "add" ? null : r.oldNo, newLine: r.kind === "del" ? null : r.newNo }, body);
                              setComposing(null);
                            }}
                          />
                        </td>
                      </tr>
                    )}
                  </Fragment>
                );
              })}
            </tbody>
          </table>
        ))}
    </div>
  );
}
