import { useCallback, useEffect, useState } from "react";
import { CircleAlert, MessageSquare } from "lucide-react";
import { api, errorMessage, type GlProjectRef, type MergeRequest, type MrScope, type MrState } from "../../api";
import { Avatar, ErrorBox, Skeleton } from "../../components/common";
import { useMenus } from "../../components/MenuHost";
import { formatTime } from "../../lib/format";
import { useNav, usePageReturn } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { mrMenu } from "./gitlabMenu";
import { MrStatePill, mrProjectPath } from "./MergeRequestView";

export const MR_STATES: [MrState, string][] = [
  ["opened", "打开"],
  ["merged", "已合并"],
  ["closed", "已关闭"],
  ["all", "全部"],
];

/** 每页条数，与后端一致。 */
const PAGE_SIZE = 30;

/** 分页加载合并请求：`scope` 为跨项目列表，`project` 为某个项目的列表。 */
export function useMrList(source: { scope: MrScope } | { project: GlProjectRef }, state: MrState, search: string) {
  const [items, setItems] = useState<MergeRequest[] | null>(null);
  const [page, setPage] = useState(1);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const key = "scope" in source ? `scope:${source.scope}` : `project:${source.project}`;

  const load = useCallback(
    async (p: number) => {
      setLoading(true);
      setError(null);
      try {
        const query = { state, search: search || null, page: p };
        const list = "scope" in source ? await api.glMergeRequests(source.scope, query) : await api.glProjectMergeRequests(source.project, query);
        setItems((old) => (p === 1 ? list : [...(old ?? []), ...list.filter((m) => !old?.some((x) => x.id === m.id))]));
        setHasMore(list.length === PAGE_SIZE);
        setPage(p);
      } catch (e) {
        setError(errorMessage(e));
      } finally {
        setLoading(false);
      }
    },
    // source 每次渲染都是新对象，用 key 代表它
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [key, state, search],
  );

  useEffect(() => {
    setItems(null);
    void load(1);
  }, [load]);

  // 回到 GitLab 页面时在原地刷新；加载过更多时不刷新，免得列表变短
  usePageReturn(() => {
    if (page === 1) void load(1);
  });

  /** 用详情里的最新数据更新列表中的一项。 */
  const replace = (mr: MergeRequest) => setItems((list) => list?.map((m) => (m.id === mr.id ? { ...m, ...mr } : m)) ?? list);

  return { items, loading, error, hasMore, reload: () => load(1), loadMore: () => load(page + 1), replace };
}

export function MrListItem({ mr, selected, showProject, onOpen }: { mr: MergeRequest; selected: boolean; showProject: boolean; onOpen: () => void }) {
  const project = mrProjectPath(mr).split("/").pop();
  const menus = useMenus();
  const { navigate } = useNav();
  const { isReady } = useSettings();
  const menuTarget = `mr:${mr.id}`;
  return (
    <div
      className={`issue-item${selected ? " selected" : ""}${menus.target === menuTarget ? " menu-target" : ""}`}
      onClick={onOpen}
      onContextMenu={(e) => menus.open(e, mrMenu(mr, navigate, { onOpen, jira: isReady("jira") }), menuTarget)}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => e.key === "Enter" && onOpen()}
    >
      <div className="issue-item-top">
        <span className="issue-key">
          {showProject ? `${project} ` : ""}!{mr.iid}
        </span>
        {mr.draft && <span className="tag muted-tag">草稿</span>}
        {mr.state !== "opened" && <MrStatePill mr={mr} />}
      </div>
      <div className="issue-summary">{mr.title}</div>
      <div className="issue-item-bottom muted small">
        <span className="mr-item-meta">
          <Avatar name={mr.author.name} size={16} />
          <span className="ellipsis">
            {mr.author.name} · {mr.sourceBranch} → {mr.targetBranch}
          </span>
        </span>
        <span className="mr-item-meta">
          {mr.state === "opened" && mr.hasConflicts && (
            <span title="有冲突">
              <CircleAlert size={13} className="danger-text" />
            </span>
          )}
          {mr.userNotesCount > 0 && (
            <>
              <MessageSquare size={12} />
              {mr.userNotesCount}
            </>
          )}
          <span>{formatTime(mr.updatedAt)}</span>
        </span>
      </div>
    </div>
  );
}

/** 列表本体：加载中、错误、空列表和“加载更多”。 */
export function MrListBody({ list, selected, showProject, onOpen, empty }: { list: ReturnType<typeof useMrList>; selected: number | null; showProject: boolean; onOpen: (mr: MergeRequest) => void; empty: string }) {
  return (
    <>
      {list.error && <ErrorBox message={list.error} onRetry={list.reload} />}
      <ul className="issue-list">
        {list.items?.map((mr) => (
          <li key={mr.id}>
            <MrListItem mr={mr} selected={selected === mr.id} showProject={showProject} onOpen={() => onOpen(mr)} />
          </li>
        ))}
        {!list.items && !list.error && (
          <li style={{ padding: "8px 12px" }}>
            <Skeleton lines={6} height={16} />
          </li>
        )}
        {list.items && list.items.length === 0 && <li className="muted list-empty">{empty}</li>}
        {list.items && list.hasMore && (
          <li style={{ padding: "8px 12px" }}>
            <button className="btn" onClick={list.loadMore} disabled={list.loading}>
              {list.loading ? "加载中…" : "加载更多"}
            </button>
          </li>
        )}
      </ul>
    </>
  );
}
