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

/** 输入停顿 `delay` 毫秒后搜索；少于两个字或是网址时不搜索。 */
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
    const timer = setTimeout(async () => {
      try {
        const local = await api.globalSearch(q, { phase: "local", limit });
        if (cancelled) return;
        setState({ results: local, pending: true, error: null });
        const remote = await api.globalSearch(q, { phase: "remote", limit });
        if (cancelled) return;
        setState({ results: merge(local, remote), pending: false, error: null });
      } catch (e) {
        if (!cancelled) setState((s) => ({ ...s, pending: false, error: errorMessage(e) }));
      }
    }, delay);
    return () => {
      cancelled = true;
      clearTimeout(timer);
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
