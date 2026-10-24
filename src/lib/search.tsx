// 统一搜索的共用部分：先取本机结果、再补上服务器结果的 hook，以及高亮关键词。⌘K 和搜索页共用。
import { useEffect, useState, type ReactNode } from "react";
import { api, errorMessage, type SearchResults } from "../api";

export interface UnifiedSearch {
  results: SearchResults | null;
  /** 本机结果已出，服务器结果还在查 */
  pending: boolean;
  error: string | null;
}

/** 两次结果合并：服务器这一步补上 GitLab、未建库时的 Jira 和 Wiki，以及问题键对应的问题。 */
function merge(local: SearchResults, remote: SearchResults): SearchResults {
  const issues =
    remote.issuesSource === "jira" ? remote.issues : [...remote.issues, ...local.issues.filter((i) => !remote.issues.some((r) => r.key === i.key))];
  return {
    ...local,
    issues,
    issuesSource: remote.issuesSource ?? local.issuesSource,
    pages: remote.pages.length > 0 ? remote.pages : local.pages,
    projects: remote.projects,
    mergeRequests: remote.mergeRequests,
    errors: [...local.errors, ...remote.errors],
  };
}

/** 本机结果只需几十毫秒，输入稍停就查。 */
const LOCAL_DELAY = 100;

/** 输入停顿后搜索：本机数据停顿 100 毫秒就查，服务器停顿 `delay` 毫秒才查（避免边输入边发请求）。少于两个字或是网址时不搜索。 */
export function useUnifiedSearch(query: string, limit: number, delay = 250): UnifiedSearch {
  const [state, setState] = useState<UnifiedSearch>({ results: null, pending: false, error: null });

  useEffect(() => {
    const q = query.trim();
    if (q.length < 2 || /^https?:\/\//.test(q)) {
      setState({ results: null, pending: false, error: null });
      return;
    }
    let cancelled = false;
    setState((s) => ({ ...s, pending: true }));
    // 清除计时器后，等待它的搜索不再开始
    const timers: number[] = [];
    const after = (ms: number) => new Promise<void>((resolve) => timers.push(window.setTimeout(resolve, ms)));
    const fail = (e: unknown) => {
      if (!cancelled) setState((s) => ({ ...s, pending: false, error: errorMessage(e) }));
    };
    const local = after(LOCAL_DELAY).then(() => api.globalSearch(q, { phase: "local", limit }));
    local.then((results) => {
      if (!cancelled) setState({ results, pending: true, error: null });
    }, fail);
    const remote = after(Math.max(delay, LOCAL_DELAY)).then(() => api.globalSearch(q, { phase: "remote", limit }));
    Promise.all([local, remote]).then(([l, r]) => {
      if (!cancelled) setState({ results: merge(l, r), pending: false, error: null });
    }, fail);
    return () => {
      cancelled = true;
      timers.forEach(clearTimeout);
    };
  }, [query, limit, delay]);

  return state;
}

/** 高亮文字中出现的关键词（按空白拆分，不区分大小写）。 */
export function Highlight({ text, query }: { text: string; query: string }) {
  const terms = query
    .trim()
    .toLowerCase()
    .split(/\s+/)
    .filter((t) => t.length > 0);
  if (terms.length === 0) return <>{text}</>;
  const lower = text.toLowerCase();
  const parts: ReactNode[] = [];
  let at = 0;
  while (at < text.length && parts.length < 60) {
    let best = -1;
    let len = 0;
    for (const t of terms) {
      const i = lower.indexOf(t, at);
      if (i >= 0 && (best < 0 || i < best || (i === best && t.length > len))) {
        best = i;
        len = t.length;
      }
    }
    if (best < 0) break;
    if (best > at) parts.push(text.slice(at, best));
    parts.push(<mark key={best}>{text.slice(best, best + len)}</mark>);
    at = best + len;
  }
  parts.push(text.slice(at));
  return <>{parts}</>;
}
