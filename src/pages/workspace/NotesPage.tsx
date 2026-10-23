import { useCallback, useEffect, useMemo, useState } from "react";
import { CalendarDays, NotepadText, Pin, Plus, Search } from "lucide-react";
import { api, errorMessage, type DocSummary } from "../../api";
import { ErrorBox } from "../../components/common";
import { useContextMenu } from "../../components/ContextMenu";
import { formatTime } from "../../lib/format";
import { today, useWorkspaceRefresh, weekdayOf, workspaceChanged } from "../../lib/workspace";
import { useNav } from "../../state/nav";
import { DocPane } from "./DocPane";
import { copyTitleItem, deleteItem, pinItem } from "./docMenu";

type Tab = "daily" | "notes";

/** 笔记：每日日记 + 独立笔记。 */
export function NotesPage() {
  const { current } = useNav();
  const [tab, setTab] = useState<Tab>(current.docId && !current.docId.startsWith("daily-") ? "notes" : "daily");
  const [notes, setNotes] = useState<DocSummary[] | null>(null);
  const [days, setDays] = useState<string[]>([]);
  const [filter, setFilter] = useState("");
  const [selected, setSelected] = useState<string>(current.docId ?? `daily-${today()}`);
  const [error, setError] = useState<string | null>(null);
  const contextMenu = useContextMenu();

  const load = useCallback(async () => {
    try {
      const [n, d] = await Promise.all([api.wsDocs("note"), api.wsDailyDays()]);
      setNotes(n);
      setDays(d);
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, []);
  useEffect(() => {
    void load();
  }, [load]);
  useWorkspaceRefresh(load);

  // 从其他页面（搜索、反向链接）跳转过来
  useEffect(() => {
    if (current.page !== "notes" || !current.docId) return;
    setSelected(current.docId);
    setTab(current.docId.startsWith("daily-") ? "daily" : "notes");
  }, [current]);

  const createNote = async () => {
    try {
      const doc = await api.wsSaveDoc({ kind: "note", title: "", content: "" });
      workspaceChanged();
      setTab("notes");
      setFilter("");
      setSelected(doc.id);
      await load();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  const t = today();
  const dayList = useMemo(() => [t, ...days.filter((d) => d !== t)], [days, t]);
  const visibleNotes = useMemo(() => {
    const q = filter.trim().toLowerCase();
    return (notes ?? []).filter((n) => !q || `${n.title} ${n.excerpt} ${n.tags.join(" ")}`.toLowerCase().includes(q));
  }, [notes, filter]);

  return (
    <div className="split">
      <aside className="list-pane">
        <div className="list-toolbar">
          <div className="list-meta">
            <div className="segmented">
              <button className={tab === "daily" ? "active" : ""} onClick={() => setTab("daily")}>
                <CalendarDays size={13} />
                日记
              </button>
              <button className={tab === "notes" ? "active" : ""} onClick={() => setTab("notes")}>
                <NotepadText size={13} />
                笔记 {notes && notes.length > 0 && <span className="seg-count">{notes.length}</span>}
              </button>
            </div>
            <span className="spacer" />
            <button className="btn primary icon" title="新建笔记" onClick={createNote}>
              <Plus size={16} />
            </button>
          </div>
          {tab === "daily" ? (
            <label className="list-meta">
              <span className="muted small nowrap">跳到日期</span>
              <input type="date" value={selected.startsWith("daily-") ? selected.slice(6) : ""} max={t} onChange={(e) => e.target.value && setSelected(`daily-${e.target.value}`)} />
            </label>
          ) : (
            <div className="input-icon">
              <Search size={14} />
              <input value={filter} placeholder="筛选笔记" onChange={(e) => setFilter(e.target.value)} />
            </div>
          )}
        </div>
        {error && <ErrorBox message={error} onRetry={load} />}
        {tab === "daily" ? (
          <ul className="doc-list">
            {dayList.map((day) => (
              <li key={day}>
                <button
                  className={`doc-item${selected === `daily-${day}` ? " selected" : ""}${contextMenu.target === day ? " menu-target" : ""}`}
                  onClick={() => setSelected(`daily-${day}`)}
                  onContextMenu={(e) =>
                    contextMenu.open(
                      e,
                      [
                        { label: "打开", onSelect: () => setSelected(`daily-${day}`) },
                        { label: "新建笔记", icon: <Plus size={14} />, onSelect: createNote },
                        // 今天的日记还没写时不能删除
                        days.includes(day) && "separator",
                        days.includes(day) && deleteItem(`daily-${day}`, "删除这天的日记", () => setSelected((id) => (id === `daily-${day}` ? `daily-${t}` : id))),
                      ],
                      day,
                    )
                  }
                >
                  <span className="doc-item-title">{day === t ? "今天" : day}</span>
                  <span className="muted small">{day === t ? `${day} · ${weekdayOf(day)}` : weekdayOf(day)}</span>
                </button>
              </li>
            ))}
          </ul>
        ) : (
          <ul className="doc-list">
            {visibleNotes.map((n) => (
              <li key={n.id}>
                <button
                  className={`doc-item${selected === n.id ? " selected" : ""}${contextMenu.target === n.id ? " menu-target" : ""}`}
                  onClick={() => setSelected(n.id)}
                  onContextMenu={(e) =>
                    contextMenu.open(
                      e,
                      [
                        { label: "打开", onSelect: () => setSelected(n.id) },
                        { label: "新建笔记", icon: <Plus size={14} />, onSelect: createNote },
                        "separator",
                        pinItem(n),
                        copyTitleItem(n.title),
                        "separator",
                        deleteItem(n.id, "删除", () => setSelected((id) => (id === n.id ? `daily-${t}` : id))),
                      ],
                      n.id,
                    )
                  }
                >
                  <span className="doc-item-title">
                    {n.pinned && <Pin size={12} className="muted" />}
                    {n.title || "无标题"}
                  </span>
                  {n.excerpt && <span className="doc-item-excerpt muted small">{n.excerpt}</span>}
                  <span className="muted small">
                    {formatTime(new Date(n.updatedAt).toISOString())}
                    {n.tags.length > 0 && ` · ${n.tags.map((t) => `#${t}`).join(" ")}`}
                  </span>
                </button>
              </li>
            ))}
            {notes && visibleNotes.length === 0 && <li className="muted list-empty">{filter ? "没有匹配的笔记" : "还没有笔记，点击右上角 + 新建"}</li>}
          </ul>
        )}
      </aside>
      <section className="detail-pane">
        <DocPane
          key={selected}
          docId={selected}
          onSaved={(doc) => {
            // 列表里的标题、摘要随编辑更新
            if (doc.kind === "note") setNotes((list) => list?.map((n) => (n.id === doc.id ? { ...n, title: doc.title, updatedAt: doc.updatedAt, pinned: doc.pinned, tags: doc.tags } : n)) ?? list);
          }}
          onDeleted={() => {
            setSelected(`daily-${today()}`);
            setTab("daily");
            void load();
          }}
        />
      </section>
      {contextMenu.menu}
    </div>
  );
}
