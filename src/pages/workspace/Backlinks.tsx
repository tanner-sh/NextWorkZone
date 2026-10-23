import { useCallback, useEffect, useState, type ReactNode } from "react";
import { BookOpen, CalendarDays, CheckSquare, Link2, NotepadText, Square } from "lucide-react";
import { api, type Backlink } from "../../api";
import { formatTime } from "../../lib/format";
import { useWorkspaceRefresh } from "../../lib/workspace";
import { useNav, type NavTarget } from "../../state/nav";

/** 打开某条本地内容（待办、笔记、日记、知识库页面）的跳转目标。 */
export function backlinkTarget(link: Pick<Backlink, "itemType" | "id" | "kind">): NavTarget {
  if (link.itemType === "todo") return { page: "todos", todoId: link.id };
  return { page: link.kind === "page" ? "kb" : "notes", docId: link.id };
}

const ICONS = { todo: CheckSquare, note: NotepadText, daily: CalendarDays, page: BookOpen } as const;
const KIND_LABEL = { todo: "待办", note: "笔记", daily: "日记", page: "知识库" } as const;

/** 引用了某个条目（Jira 问题、文档）的待办和文档。 */
export function Backlinks(props: { system: string; itemKey: string; title?: string; hideEmpty?: boolean; actions?: ReactNode; id?: string; onCount?: (n: number) => void }) {
  const { navigate } = useNav();
  const [links, setLinks] = useState<Backlink[] | null>(null);

  const load = useCallback(() => {
    api.wsBacklinks(props.system, props.itemKey).then(setLinks, () => setLinks([]));
  }, [props.system, props.itemKey]);
  useEffect(load, [load]);
  useWorkspaceRefresh(load);
  const { onCount } = props;
  useEffect(() => {
    onCount?.(links?.length ?? 0);
  }, [links, onCount]);

  if (!links || (props.hideEmpty && links.length === 0 && !props.actions)) return null;
  return (
    <section className="block" id={props.id}>
      <div className="block-title">
        <h2>
          <Link2 size={16} className="muted" />
          {props.title ?? "工作空间中的引用"} {links.length > 0 && <span className="count">{links.length}</span>}
        </h2>
        {props.actions && <div className="block-actions">{props.actions}</div>}
      </div>
      {links.length > 0 ? (
        <ul className="links">
          {links.map((l) => {
            const Icon = l.itemType === "todo" && !l.done ? Square : ICONS[l.kind];
            return (
              <li key={`${l.itemType}-${l.id}`} className="clickable" onClick={() => navigate(backlinkTarget(l))}>
                <Icon size={14} className="muted" />
                <span className="muted small nowrap">{KIND_LABEL[l.kind]}</span>
                <span className={`ellipsis grow${l.done ? " strike" : ""}`}>{l.title || "无标题"}</span>
                <span className="muted small nowrap">{formatTime(new Date(l.updatedAt).toISOString())}</span>
              </li>
            );
          })}
        </ul>
      ) : (
        <p className="muted small">还没有待办或文档引用它</p>
      )}
    </section>
  );
}
