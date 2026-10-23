import { Fragment, useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { api, type IndexStatus } from "../../api";

/** 后端问题库有变化（同步进度、同步完成）时发出的事件。 */
const INDEX_EVENT = "jira-index-changed";

/** 本机问题库的状态，同步过程中随进度更新。 */
export function useIndexStatus(): IndexStatus | null {
  const [status, setStatus] = useState<IndexStatus | null>(null);
  useEffect(() => {
    let alive = true;
    const refresh = () => api.jiraIndexStatus().then((s) => alive && setStatus(s), () => {});
    refresh();
    // 同步时每页都会发事件，合并成每秒最多刷新一次
    let timer: number | null = null;
    const unlisten = listen(INDEX_EVENT, () => {
      if (timer === null) {
        timer = window.setTimeout(() => {
          timer = null;
          refresh();
        }, 1000);
      }
    });
    return () => {
      alive = false;
      if (timer !== null) window.clearTimeout(timer);
      void unlisten.then((fn) => fn());
    };
  }, []);
  return status;
}

/** 高亮文字中的关键词（空格分隔，不区分大小写）。 */
export function Highlight({ text, query }: { text: string; query: string }) {
  const terms = query
    .split(/\s+/)
    .filter(Boolean)
    .map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  if (terms.length === 0) return <>{text}</>;
  const parts = text.split(new RegExp(`(${terms.join("|")})`, "gi"));
  return (
    <>
      {parts.map((part, i) => (i % 2 === 1 ? <mark key={i}>{part}</mark> : <Fragment key={i}>{part}</Fragment>))}
    </>
  );
}
