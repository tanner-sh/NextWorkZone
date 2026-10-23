import { useEffect, useMemo, useRef, useState } from "react";
import { ClipboardList, Copy, Keyboard, Pencil, Pin, PinOff, Plus, Search, Trash2 } from "lucide-react";
import { api, errorMessage, type ClipApp, type ClipItem, type ClipKind, type Pinboard } from "../../../api";
import { Modal } from "../../../components/common";
import { useContextMenu, type MenuInput } from "../../../components/ContextMenu";
import { toast } from "../../../components/Toast";
import { clipAssetUrl } from "../../../lib/asset";
import { openLink } from "../../../lib/links";
import { useNav } from "../../../state/nav";
import { useSettings } from "../../../state/settings";
import { displayShortcut } from "../../workspace/WorkspaceSettingsCard";
import { itemIssueKeys, smartActions } from "./actions";
import { AppIcon, ClipPreviewBody, Highlight } from "./ClipCard";
import { BOARD_COLORS, KIND_META, KINDS, metaLine, timeLabel, useIssues } from "./clip";
import { ClipboardSettings, useClipSettings } from "./ClipboardSettings";
import { useClips } from "./useClips";
import { dragsAsFiles, endDrag, pointerDrag, prepareDrag, startDrag } from "./drag";

/** 应用内的剪贴板页面：浏览、搜索、整理历史和置顶板，以及设置。 */
export function ClipboardPage({ tab }: { tab?: string }) {
  const { navigate } = useNav();
  const settingsTab = tab === "settings";
  const switcher = (
    <div className="segmented">
      <button className={!settingsTab ? "active" : ""} onClick={() => navigate({ page: "tools", tool: "clipboard" })}>
        历史
      </button>
      <button className={settingsTab ? "active" : ""} onClick={() => navigate({ page: "tools", tool: "clipboard", toolTab: "settings" })}>
        设置
      </button>
    </div>
  );
  if (settingsTab) {
    return (
      <section className="page">
        <div className="page-header">
          <div>
            <h1>剪贴板</h1>
            <p className="muted">记录复制过的内容，随时搜索、粘贴。</p>
          </div>
          {switcher}
        </div>
        <ClipboardSettings />
      </section>
    );
  }
  return <History switcher={switcher} />;
}

function History({ switcher }: { switcher: React.ReactNode }) {
  const { navigate } = useNav();
  const { baseUrl, isReady } = useSettings();
  const jiraReady = isReady("jira");
  const { settings } = useClipSettings();
  const [input, setInput] = useState("");
  const [query, setQuery] = useState("");
  const [kind, setKind] = useState<ClipKind | null>(null);
  const [board, setBoard] = useState<string | null>(null);
  const [app, setApp] = useState<string | null>(null);
  const [apps, setApps] = useState<ClipApp[]>([]);
  const { items, boards, hasMore, loadMore } = useClips({ text: query, kind, board, app });
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [editBoard, setEditBoard] = useState<Pinboard | "new" | null>(null);
  const menu = useContextMenu();
  const listRef = useRef<HTMLUListElement>(null);

  useEffect(() => {
    const timer = window.setTimeout(() => setQuery(input.trim()), 150);
    return () => window.clearTimeout(timer);
  }, [input]);
  useEffect(() => {
    api.clipApps().then(setApps, () => {});
  }, [items?.length]);

  const list = useMemo(() => items ?? [], [items]);
  const selected = list.find((i) => i.id === selectedId) ?? list[0];

  const pinMenu = (ids: string[], current: string | null): MenuInput[] => [
    ...boards.map((b) => ({ label: b.name, icon: <span className="clip-dot" style={{ background: b.color }} />, checked: current === b.id, onSelect: () => api.clipSetPinboard(ids, b.id) })),
    "separator",
    { label: "新建置顶板…", icon: <Plus size={14} />, onSelect: () => setEditBoard("new") },
    current !== null && { label: "取消置顶", icon: <PinOff size={14} />, onSelect: () => api.clipSetPinboard(ids, null) },
  ];

  const itemMenu = (item: ClipItem): MenuInput[] => [
    { label: "复制", icon: <Copy size={14} />, onSelect: () => api.clipCopy([item.id]).then(() => toast("已复制")) },
    item.hasHtml && { label: "复制为纯文本", onSelect: () => api.clipCopy([item.id], true).then(() => toast("已复制")) },
    { label: "置顶到", icon: <Pin size={14} />, children: pinMenu([item.id], item.pinboard) },
    "separator",
    { label: "删除", icon: <Trash2 size={14} />, danger: true, onSelect: () => api.clipDelete([item.id]) },
  ];

  const boardMenu = (b: Pinboard): MenuInput[] => [
    { label: "重命名…", icon: <Pencil size={14} />, onSelect: () => setEditBoard(b) },
    { label: "颜色", children: BOARD_COLORS.map((c) => ({ label: c, icon: <span className="clip-dot" style={{ background: c }} />, checked: b.color === c, onSelect: () => api.clipSavePinboard(b.id, b.name, c) })) },
    "separator",
    { label: "删除置顶板", icon: <Trash2 size={14} />, danger: true, confirm: "确认删除（其中的条目回到历史中）", onSelect: () => api.clipDeletePinboard(b.id).then(() => board === b.id && setBoard(null)) },
  ];

  const empty = !items ? null : query || kind || app ? "没有找到匹配的内容" : board ? "这个置顶板还是空的" : "还没有记录。复制一些内容试试。";

  return (
    <div className="split">
      <aside className="list-pane clip-list-pane">
        <div className="list-toolbar">
          {switcher}
          <div className="input-icon">
            <Search size={14} />
            <input value={input} placeholder="搜索文字、文件名、应用" onChange={(e) => setInput(e.target.value)} />
          </div>
          <div className="clip-filter-row">
            <button className={`chip-btn${board === null ? " active" : ""}`} onClick={() => setBoard(null)}>
              全部
            </button>
            {boards.map((b) => (
              <button key={b.id} className={`chip-btn${board === b.id ? " active" : ""}`} onClick={() => setBoard(b.id)} onContextMenu={(e) => menu.open(e, boardMenu(b))} title="右键：重命名、颜色、删除">
                <span className="clip-dot" style={{ background: b.color }} />
                {b.name}
                <span className="muted">{b.count}</span>
              </button>
            ))}
            <button className="chip-btn" title="新建置顶板" onClick={() => setEditBoard("new")}>
              <Plus size={12} />
            </button>
          </div>
          <div className="list-meta">
            <select className="compact-select" value={kind ?? ""} onChange={(e) => setKind((e.target.value || null) as ClipKind | null)} title="类型">
              <option value="">全部类型</option>
              {KINDS.map((k) => (
                <option key={k} value={k}>
                  {KIND_META[k].label}
                </option>
              ))}
            </select>
            <select className="compact-select grow" value={app ?? ""} onChange={(e) => setApp(e.target.value || null)} title="来源应用">
              <option value="">全部来源</option>
              {apps.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.name}（{a.count}）
                </option>
              ))}
            </select>
          </div>
        </div>
        <ul className="issue-list" ref={listRef} onScroll={(e) => {
          const el = e.currentTarget;
          if (hasMore && el.scrollTop + el.clientHeight > el.scrollHeight - 400) void loadMore();
        }}>
          {list.map((item) => {
            const Icon = KIND_META[item.kind].icon;
            return (
              <li key={item.id}>
                <button
                  className={`issue-item clip-row${selected?.id === item.id ? " selected" : ""}${menu.target === item.id ? " menu-open" : ""}`}
                  onClick={() => setSelectedId(item.id)}
                  draggable={!dragsAsFiles([item])}
                  onMouseDown={(e) => {
                    if (e.button !== 0) return;
                    prepareDrag([item]);
                    pointerDrag(e, [item], (message) => toast(message, true));
                  }}
                  onDragStart={(e) => startDrag(e, [item], (message) => toast(message, true))}
                  onDragEnd={(e) => endDrag(e, [item])}
                  onContextMenu={(e) => menu.open(e, itemMenu(item), item.id)}
                >
                  <div className="clip-row-main">
                    <AppIcon item={item} size={18} />
                    <span className="clip-row-text">
                      {item.title ? <b>{item.title}</b> : null}
                      {item.kind === "image" ? "图片" : item.kind === "file" ? metaLine(item) : <Highlight text={item.text.replace(/\s+/g, " ").slice(0, 160)} query={query} />}
                    </span>
                    {item.kind === "image" && <img className="clip-row-thumb" src={clipAssetUrl("thumb", item.id)} alt="" />}
                  </div>
                  <div className="issue-item-bottom muted small">
                    <span className="clip-row-meta">
                      <Icon size={12} />
                      {KIND_META[item.kind].label} · {item.appName ?? "未知来源"}
                      {item.pinboard && <Pin size={11} style={{ color: boards.find((b) => b.id === item.pinboard)?.color }} />}
                    </span>
                    <span>{timeLabel(item.copiedAt)}</span>
                  </div>
                </button>
              </li>
            );
          })}
          {empty && list.length === 0 && <li className="list-empty muted">{empty}</li>}
        </ul>
        {settings && (
          <div className="clip-list-foot muted small">
            <Keyboard size={12} />
            {settings.config.enabled ? `在任何应用中按 ${displayShortcut(settings.config.shortcut)} 打开面板` : "剪贴板记录已关闭"}
          </div>
        )}
      </aside>
      <main className="detail-pane">
        {selected ? (
          <Detail key={selected.id} item={selected} boards={boards} jiraReady={jiraReady} pinMenu={pinMenu} onOpen={(target) => {
            if (target.startsWith("url:")) void openLink(target.slice(4), baseUrl, navigate);
          }} />
        ) : (
          <div className="empty-center">
            <ClipboardList size={28} />
            <span>{empty ?? "加载中…"}</span>
          </div>
        )}
      </main>
      {menu.menu}
      {editBoard && <BoardDialog board={editBoard === "new" ? null : editBoard} count={boards.length} onClose={() => setEditBoard(null)} onSaved={(b) => editBoard === "new" && setBoard(b.id)} />}
    </div>
  );
}

function Detail({ item, boards, jiraReady, pinMenu, onOpen }: { item: ClipItem; boards: Pinboard[]; jiraReady: boolean; pinMenu: (ids: string[], current: string | null) => MenuInput[]; onOpen: (target: string) => void }) {
  const { baseUrl } = useSettings();
  const [text, setText] = useState(item.text);
  const [draft, setDraft] = useState<string | null>(null);
  const [title, setTitle] = useState(item.title);
  const menu = useContextMenu();
  const issues = useIssues(itemIssueKeys(item, { baseUrl, jiraReady }), jiraReady);

  useEffect(() => {
    if (item.textLength > item.text.length) void api.clipText(item.id).then((t) => setText(t.text), () => {});
  }, [item]);

  const actions = smartActions(item, text, issues, {
    baseUrl,
    jiraReady,
    emitText: (value) => api.clipCopy([item.id], true, value).then(() => toast("已复制")),
    verb: "复制",
    openInApp: onOpen,
    done: (message) => toast(message),
  });
  const board = boards.find((b) => b.id === item.pinboard);
  const textual = item.kind !== "image" && item.kind !== "file";

  const saveTitle = () => {
    if (title.trim() !== item.title) void api.clipRename(item.id, title).catch((e) => toast(errorMessage(e), true));
  };

  return (
    <div className="detail-body clip-detail">
      <div className="clip-detail-head">
        <AppIcon item={item} size={32} />
        <div className="grow">
          <input className="clip-detail-title" value={title} placeholder={`${KIND_META[item.kind].label}（点击命名）`} onChange={(e) => setTitle(e.target.value)} onBlur={saveTitle} onKeyDown={(e) => e.key === "Enter" && !e.nativeEvent.isComposing && (e.target as HTMLInputElement).blur()} />
          <div className="muted small">
            {item.appName ?? "未知来源"} · {timeLabel(item.copiedAt)}
            {item.copyCount > 1 ? ` · 复制过 ${item.copyCount} 次` : ""} · {metaLine(item)}
            {item.hasHtml ? " · 带格式" : ""}
            {board ? ` · 置顶于“${board.name}”` : ""}
          </div>
        </div>
      </div>
      <div className="issue-actions">
        <button className="btn primary" onClick={() => void api.clipCopy([item.id]).then(() => toast("已复制"))}>
          <Copy size={14} />
          复制
        </button>
        {item.hasHtml && (
          <button className="btn" onClick={() => void api.clipCopy([item.id], true).then(() => toast("已复制纯文本"))}>
            复制为纯文本
          </button>
        )}
        {textual && draft === null && (
          <button className="btn" onClick={() => setDraft(text)}>
            <Pencil size={14} />
            编辑
          </button>
        )}
        <button className="btn" onClick={(e) => menu.open(e, pinMenu([item.id], item.pinboard))}>
          <Pin size={14} />
          {board ? board.name : "置顶到…"}
        </button>
        <button className="btn subtle" onClick={() => void api.clipDelete([item.id])}>
          <Trash2 size={14} />
          删除
        </button>
      </div>
      {draft !== null ? (
        <div className="clip-detail-edit">
          <textarea className="clip-editor" value={draft} spellCheck={false} onChange={(e) => setDraft(e.target.value)} autoFocus />
          <div className="row-actions">
            <button
              className="btn primary"
              disabled={!draft.trim() || draft === text}
              onClick={() =>
                void api.clipUpdateText(item.id, draft).then(
                  () => {
                    setText(draft);
                    setDraft(null);
                  },
                  (e) => toast(errorMessage(e), true),
                )
              }
            >
              保存
            </button>
            <button className="btn" onClick={() => setDraft(null)}>
              取消
            </button>
          </div>
        </div>
      ) : (
        <div className={`clip-detail-preview kind-${item.kind}`}>
          <ClipPreviewBody item={item} text={text} issues={issues} baseUrl={baseUrl} />
        </div>
      )}
      {actions.length > 0 && (
        <div className="clip-detail-actions">
          <h3>快捷操作</h3>
          <div className="clip-action-grid">
            {actions.map((a) => (
              <button key={a.id} className="btn" onClick={() => void Promise.resolve().then(a.run).catch((e) => toast(errorMessage(e), true))}>
                <a.icon size={14} />
                <span className="ellipsis">{a.label}</span>
              </button>
            ))}
          </div>
        </div>
      )}
      {menu.menu}
    </div>
  );
}

function BoardDialog({ board, count, onClose, onSaved }: { board: Pinboard | null; count: number; onClose: () => void; onSaved: (board: Pinboard) => void }) {
  const [name, setName] = useState(board?.name ?? "");
  const [color, setColor] = useState(board?.color ?? BOARD_COLORS[count % BOARD_COLORS.length]);
  const [error, setError] = useState<string | null>(null);
  const save = async () => {
    try {
      onSaved(await api.clipSavePinboard(board?.id ?? null, name, color));
      onClose();
    } catch (e) {
      setError(errorMessage(e));
    }
  };
  return (
    <Modal
      title={board ? "编辑置顶板" : "新建置顶板"}
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>
            取消
          </button>
          <button className="btn primary" disabled={!name.trim()} onClick={() => void save()}>
            保存
          </button>
        </>
      }
    >
      <label className="field">
        <span>名称</span>
        <input value={name} placeholder="例如：常用回复、代码片段" onChange={(e) => setName(e.target.value)} onKeyDown={(e) => e.key === "Enter" && !e.nativeEvent.isComposing && void save()} />
      </label>
      <div className="field">
        <span>颜色</span>
        <div className="clip-colors">
          {BOARD_COLORS.map((c) => (
            <button key={c} className={c === color ? "active" : ""} style={{ background: c }} onClick={() => setColor(c)} aria-label={c} />
          ))}
        </div>
      </div>
      {error && <p className="notice error">{error}</p>}
    </Modal>
  );
}
