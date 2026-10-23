import { useCallback, useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { api, CLIP_CHANGED_EVENT, CLIP_SETTINGS_EVENT, type ClipItem, type ClipKind, type Pinboard } from "../../../api";

const PAGE = 120;

export interface ClipFilter {
  text: string;
  kind: ClipKind | null;
  /** 置顶板 id；null 为全部历史 */
  board: string | null;
  app?: string | null;
}

/** 按条件加载剪贴板历史和置顶板；有新内容或其他窗口修改了条目时自动刷新，滚动到末尾时加载更多。 */
export function useClips(filter: ClipFilter) {
  const [items, setItems] = useState<ClipItem[] | null>(null);
  const [boards, setBoards] = useState<Pinboard[]>([]);
  const [hasMore, setHasMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const seq = useRef(0);
  const loadingMore = useRef(false);
  const { text, kind, board, app } = filter;

  const reload = useCallback(async () => {
    const my = ++seq.current;
    try {
      const [list, pinboards] = await Promise.all([api.clipList({ text, kind, pinboard: board, app, limit: PAGE }), api.clipPinboards()]);
      if (my !== seq.current) return;
      setItems(list);
      setBoards(pinboards);
      // 置顶板中的条目按置顶时间排列，数量不多，一次取完
      setHasMore(list.length === PAGE && !board);
      setError(null);
    } catch (e) {
      if (my === seq.current) setError(String(e));
    }
  }, [text, kind, board, app]);

  // 输入搜索词时稍等一下再查询
  useEffect(() => {
    const timer = window.setTimeout(() => void reload(), text ? 80 : 0);
    return () => window.clearTimeout(timer);
  }, [reload, text]);

  useEffect(() => {
    let timer: number | undefined;
    const schedule = () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => void reload(), 60);
    };
    const unlisten = [listen(CLIP_CHANGED_EVENT, schedule), listen(CLIP_SETTINGS_EVENT, schedule)];
    return () => {
      window.clearTimeout(timer);
      unlisten.forEach((u) => void u.then((fn) => fn()));
    };
  }, [reload]);

  const loadMore = useCallback(async () => {
    if (!hasMore || !items?.length || loadingMore.current) return;
    loadingMore.current = true;
    const my = seq.current;
    try {
      const more = await api.clipList({ text, kind, pinboard: board, app, before: items[items.length - 1].copiedAt, limit: PAGE });
      if (my !== seq.current) return;
      setItems((list) => [...(list ?? []), ...more.filter((m) => !list?.some((i) => i.id === m.id))]);
      setHasMore(more.length === PAGE);
    } finally {
      loadingMore.current = false;
    }
  }, [hasMore, items, text, kind, board, app]);

  return { items, boards, hasMore, error, reload, loadMore };
}
