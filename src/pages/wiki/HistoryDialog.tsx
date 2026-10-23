import { useEffect, useMemo, useState } from "react";
import { api, errorMessage, type WikiPageDetail, type WikiVersion } from "../../api";
import { ErrorBox, Modal, Skeleton } from "../../components/common";
import { RichHtml } from "../../components/RichHtml";
import { formatTime } from "../../lib/format";
import { parseDiff } from "../gitlab/DiffView";

/** 页面的历史版本：选择一个版本查看它与上一版（或任意版本）的差异，也可以查看当时的完整内容。 */
export function HistoryDialog({ page, onClose }: { page: WikiPageDetail; onClose: () => void }) {
  const [versions, setVersions] = useState<WikiVersion[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState(page.version);
  /** 比较的基准版本；为空时与上一版比较 */
  const [base, setBase] = useState<number | null>(null);
  const [mode, setMode] = useState<"diff" | "view">("diff");

  useEffect(() => {
    api.wikiVersions(page.id).then(setVersions, (e) => setError(errorMessage(e)));
  }, [page.id]);

  const from = base ?? (versions?.find((v) => v.number < selected)?.number ?? null);

  return (
    <Modal title={`历史版本 · ${page.title}`} onClose={onClose} wide>
      {error && <ErrorBox message={error} />}
      {!versions && !error && <Skeleton lines={6} />}
      {versions && (
        <div className="wiki-history">
          <ul className="wiki-versions">
            {versions.map((v) => (
              <li key={v.number}>
                <button className={`doc-item${v.number === selected ? " selected" : ""}`} onClick={() => setSelected(v.number)}>
                  <span className="doc-item-title">
                    第 {v.number} 版{v.number === page.version && <span className="muted small"> · 当前</span>}
                    {v.minorEdit && <span className="muted small"> · 小修改</span>}
                  </span>
                  <span className="doc-item-excerpt muted small">
                    {v.by} · {formatTime(v.when)}
                    {v.message && ` · ${v.message}`}
                  </span>
                </button>
              </li>
            ))}
          </ul>
          <div className="wiki-history-main">
            <div className="list-meta">
              <div className="segmented small-seg">
                <button className={mode === "diff" ? "active" : ""} onClick={() => setMode("diff")}>
                  变化
                </button>
                <button className={mode === "view" ? "active" : ""} onClick={() => setMode("view")}>
                  完整内容
                </button>
              </div>
              {mode === "diff" && (
                <label className="small muted wiki-compare">
                  对比
                  <select value={base ?? ""} onChange={(e) => setBase(e.target.value ? Number(e.target.value) : null)}>
                    <option value="">上一版</option>
                    {versions
                      .filter((v) => v.number !== selected)
                      .map((v) => (
                        <option key={v.number} value={v.number}>
                          第 {v.number} 版（{v.by}）
                        </option>
                      ))}
                  </select>
                </label>
              )}
            </div>
            {mode === "diff" ? (
              from === null ? (
                <p className="muted">这是第一个版本。</p>
              ) : (
                <VersionDiff pageId={page.id} from={Math.min(from, selected)} to={Math.max(from, selected)} />
              )
            ) : (
              <VersionContent pageId={page.id} version={selected} />
            )}
          </div>
        </div>
      )}
    </Modal>
  );
}

function VersionDiff({ pageId, from, to }: { pageId: string; from: number; to: number }) {
  const [diff, setDiff] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    setDiff(null);
    setError(null);
    api.wikiDiff(pageId, from, to).then(
      (d) => alive && setDiff(d),
      (e) => alive && setError(errorMessage(e)),
    );
    return () => {
      alive = false;
    };
  }, [pageId, from, to]);
  if (error) return <ErrorBox message={error} />;
  if (diff === null) return <Skeleton lines={8} />;
  return (
    <>
      <p className="muted small">
        第 {from} 版 → 第 {to} 版（按段落比较文字内容，格式变化不显示）
      </p>
      <WikiDiff diff={diff} />
    </>
  );
}

/** 文字差异：成对的删除、新增行中标出改动的部分。 */
export function WikiDiff({ diff }: { diff: string }) {
  const rows = useMemo(() => parseDiff(diff), [diff]);
  // 连续的删除行与紧随其后的新增行逐行配对（第 n 个删除对第 n 个新增）
  const pairs = useMemo(() => {
    const map = new Map<number, string>();
    let i = 0;
    while (i < rows.length) {
      if (rows[i].kind !== "del") {
        i++;
        continue;
      }
      const dels: number[] = [];
      while (i < rows.length && rows[i].kind === "del") dels.push(i++);
      const adds: number[] = [];
      while (i < rows.length && rows[i].kind === "add") adds.push(i++);
      dels.forEach((d, n) => {
        if (adds[n] === undefined) return;
        map.set(d, rows[adds[n]].text);
        map.set(adds[n], rows[d].text);
      });
    }
    return map;
  }, [rows]);
  if (!diff.trim()) return <p className="muted">文字内容没有变化。</p>;
  return (
    <table className="diff-table wiki-diff">
      <tbody>
        {rows.map((r, i) => {
          if (r.kind === "hunk") {
            return (
              <tr key={i} className="hunk">
                <td className="mark" />
                <td className="src">…</td>
              </tr>
            );
          }
          const other = pairs.get(i) ?? null;
          return (
            <tr key={i} className={r.kind}>
              <td className="mark">{r.kind === "add" ? "+" : r.kind === "del" ? "−" : ""}</td>
              <td className="src">{other !== null ? <Changed text={r.text} other={other} /> : r.text}</td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

/** 去掉相同的开头和结尾，突出中间改动的部分。 */
function Changed({ text, other }: { text: string; other: string }) {
  let start = 0;
  while (start < text.length && start < other.length && text[start] === other[start]) start++;
  let end = 0;
  while (end < text.length - start && end < other.length - start && text[text.length - 1 - end] === other[other.length - 1 - end]) end++;
  if (start === 0 && end === 0) return <>{text}</>;
  return (
    <>
      {text.slice(0, start)}
      <mark className="diff-word">{text.slice(start, text.length - end)}</mark>
      {text.slice(text.length - end)}
    </>
  );
}

function VersionContent({ pageId, version }: { pageId: string; version: number }) {
  const [html, setHtml] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    setHtml(null);
    api.wikiVersionHtml(pageId, version).then(
      (h) => alive && setHtml(h),
      (e) => alive && setError(errorMessage(e)),
    );
    return () => {
      alive = false;
    };
  }, [pageId, version]);
  if (error) return <ErrorBox message={error} />;
  if (html === null) return <Skeleton lines={8} />;
  return <RichHtml service="confluence" className="wiki-content" html={html} />;
}
