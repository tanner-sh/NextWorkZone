import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { LogicalPosition } from "@tauri-apps/api/dpi";
import { Menu } from "@tauri-apps/api/menu";
import type { MenuItemOptions, PredefinedMenuItemOptions, SubmenuOptions } from "@tauri-apps/api/menu";
import { ClipboardList, CornerDownLeft, Pause, Plus, Search, Settings2, X } from "lucide-react";
import { api, CLIP_OPEN_EVENT, CLIP_SETTINGS_EVENT, errorMessage, type ClipItem, type ClipKind, type ClipSettings, type IssueHit } from "../../../api";
import { SettingsProvider, useSettings } from "../../../state/settings";
import { smartActions, itemIssueKeys, type ClipAction } from "./actions";
import { AppIcon, ClipCard, ClipPreviewBody } from "./ClipCard";
import { BOARD_COLORS, KIND_META, KINDS, MOD, timeLabel, useIssues } from "./clip";
import { useClips } from "./useClips";
import { dragsAsFiles, endDrag, pointerDrag, prepareDrag, startDrag } from "./drag";

type MenuEntry = MenuItemOptions | SubmenuOptions | PredefinedMenuItemOptions;
const SEPARATOR: PredefinedMenuItemOptions = { item: "Separator" };

/** 全局快捷键弹出的剪贴板面板（独立窗口，显示在屏幕底部）。 */
export function ClipPanel() {
  return (
    <SettingsProvider>
      <Panel />
    </SettingsProvider>
  );
}

function Panel() {
  const { baseUrl, isReady } = useSettings();
  const jiraReady = isReady("jira");
  const [query, setQuery] = useState("");
  const [kind, setKind] = useState<ClipKind | null>(null);
  const [board, setBoard] = useState<string | null>(null);
  const { items, boards, loadMore, reload } = useClips({ text: query, kind, board });
  const [index, setIndex] = useState(0);
  /** 多选的条目，按选择顺序 */
  const [marked, setMarked] = useState<string[]>([]);
  const [preview, setPreview] = useState<{ edit: boolean } | null>(null);
  const [target, setTarget] = useState<string | null>(null);
  const [settings, setSettings] = useState<ClipSettings | null>(null);
  const [notice, setNotice] = useState<{ text: string; error?: boolean } | null>(null);
  const [newBoard, setNewBoard] = useState<string | null>(null);
  const [opening, setOpening] = useState(0);
  const input = useRef<HTMLInputElement>(null);
  const strip = useRef<HTMLDivElement>(null);
  const noticeTimer = useRef<number | undefined>(undefined);

  const list = useMemo(() => items ?? [], [items]);
  const current: ClipItem | undefined = list[Math.min(index, list.length - 1)];
  const currentIssues = useIssues(current ? itemIssueKeys(current, { baseUrl, jiraReady }) : [], jiraReady);

  const flash = useCallback((text: string, error = false) => {
    setNotice({ text, error });
    window.clearTimeout(noticeTimer.current);
    noticeTimer.current = window.setTimeout(() => setNotice(null), error ? 4000 : 1800);
  }, []);

  const refreshSettings = useCallback(() => void api.clipSettings().then(setSettings, () => {}), []);

  // 每次弹出：回到全部历史的第一条，清空搜索，聚焦输入框
  useEffect(() => {
    refreshSettings();
    const unlisten = [
      listen<{ target: string | null }>(CLIP_OPEN_EVENT, ({ payload }) => {
        setTarget(payload.target);
        setQuery("");
        setKind(null);
        setBoard(null);
        setIndex(0);
        setMarked([]);
        setPreview(null);
        setNewBoard(null);
        setNotice(null);
        setOpening((n) => n + 1);
        refreshSettings();
        // 拖出、粘贴后条目的顺序可能变了
        void reload();
        strip.current?.scrollTo({ left: 0 });
        window.setTimeout(() => input.current?.focus(), 0);
      }),
      listen(CLIP_SETTINGS_EVENT, refreshSettings),
    ];
    return () => unlisten.forEach((u) => void u.then((fn) => fn()));
  }, [refreshSettings, reload]);

  // 弹出时卡片依次升起
  const [entering, setEntering] = useState(false);
  useEffect(() => {
    if (!opening) return;
    setEntering(true);
    const timer = window.setTimeout(() => setEntering(false), 450);
    return () => window.clearTimeout(timer);
  }, [opening]);

  // 列表变化（搜索、新内容）时保持选中项在范围内
  useEffect(() => setIndex((i) => Math.max(0, Math.min(i, list.length - 1))), [list.length]);
  useEffect(() => setIndex(0), [query, kind, board]);

  // 选中的卡片滚动到可见位置
  useEffect(() => {
    if (!current) return;
    strip.current?.querySelector(`[data-id="${current.id}"]`)?.scrollIntoView({ block: "nearest", inline: "nearest", behavior: "smooth" });
  }, [current]);

  // 鼠标滚轮上下滚动时横向滚动卡片；接近末尾时加载更多
  useEffect(() => {
    const el = strip.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
        e.preventDefault();
        el.scrollLeft += e.deltaY;
      }
    };
    const onScroll = () => {
      if (el.scrollLeft + el.clientWidth > el.scrollWidth - 800) void loadMore();
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    el.addEventListener("scroll", onScroll);
    return () => {
      el.removeEventListener("wheel", onWheel);
      el.removeEventListener("scroll", onScroll);
    };
  }, [loadMore]);

  const selectedIds = useCallback((): string[] => (marked.length ? marked : current ? [current.id] : []), [marked, current]);

  const run = useCallback(
    async (action: () => Promise<unknown>) => {
      try {
        await action();
      } catch (e) {
        flash(errorMessage(e), true);
      }
    },
    [flash],
  );

  const paste = useCallback((ids: string[], plain?: boolean, edited?: string) => run(() => (ids.length || edited ? api.clipPaste(ids, plain, edited) : Promise.resolve())), [run]);
  const copy = useCallback((ids: string[]) => run(async () => {
    await api.clipCopy(ids);
    await api.clipHide(true);
  }), [run]);
  const remove = useCallback(
    (ids: string[]) =>
      run(async () => {
        await api.clipDelete(ids);
        setMarked([]);
      }),
    [run],
  );
  const pin = useCallback((ids: string[], to: string | null) => run(() => api.clipSetPinboard(ids, to)), [run]);
  const openMain = useCallback((targetSpec: string) => run(() => api.clipOpenMain(targetSpec)), [run]);

  const autoPaste = Boolean(settings?.config.autoPaste && settings.pasteSupport === "ready");
  const actionsFor = useCallback(
    (item: ClipItem, text: string, issues: IssueHit[]): ClipAction[] =>
      smartActions(item, text, issues, {
        baseUrl,
        jiraReady,
        emitText: (value) => paste([item.id], true, value),
        verb: autoPaste ? "粘贴" : "复制",
        openInApp: openMain,
        done: (message) => {
          flash(message);
          window.setTimeout(() => void api.clipHide(true), 700);
        },
      }),
    [baseUrl, jiraReady, paste, openMain, flash, autoPaste],
  );

  const pasteLabel = autoPaste ? `粘贴到 ${target ?? "当前应用"}` : "复制";

  /** 条目的右键菜单（系统原生菜单，不受面板高度限制）。 */
  const openMenu = useCallback(
    async (item: ClipItem, at?: { x: number; y: number }) => {
      const ids = marked.includes(item.id) ? marked : [item.id];
      const text = item.textLength > item.text.length ? (await api.clipText(item.id).catch(() => null))?.text ?? item.text : item.text;
      const smart = actionsFor(item, text, ids.length === 1 && item.id === current?.id ? currentIssues : []);
      const textual = item.kind !== "image" && item.kind !== "file";
      const entries: MenuEntry[] = [
        { text: ids.length > 1 ? `${pasteLabel}（${ids.length} 条）` : pasteLabel, accelerator: "Enter", action: () => void paste(ids) },
        textual && { text: autoPaste ? "粘贴为纯文本" : "复制为纯文本", accelerator: "Shift+Enter", action: () => void paste(ids, true) },
        // 不能自动粘贴时第一项已经是“复制”
        autoPaste && { text: "复制", accelerator: "CmdOrCtrl+C", action: () => void copy(ids) },
        SEPARATOR,
        ids.length === 1 && { text: "预览", accelerator: "Space", action: () => setPreview({ edit: false }) },
        ids.length === 1 && textual && { text: autoPaste ? "编辑后粘贴…" : "编辑后复制…", accelerator: "CmdOrCtrl+E", action: () => setPreview({ edit: true }) },
        {
          text: "置顶到",
          items: [
            ...boards.map((b) => ({ text: `${b.name}${item.pinboard === b.id ? " ✓" : ""}`, action: () => void pin(ids, b.id) })),
            ...(boards.length ? [SEPARATOR] : []),
            { text: "新建置顶板…", action: () => setNewBoard("") },
            ...(item.pinboard ? [SEPARATOR, { text: "取消置顶", action: () => void pin(ids, null) }] : []),
          ],
        } satisfies SubmenuOptions,
        ...(ids.length === 1 && smart.length
          ? [SEPARATOR, ...smart.map((a) => ({ text: a.label, action: () => void run(async () => a.run()) }))]
          : []),
        SEPARATOR,
        { text: ids.length > 1 ? `删除 ${ids.length} 条` : "删除", accelerator: "CmdOrCtrl+Backspace", action: () => void remove(ids) },
      ].filter(Boolean) as MenuEntry[];
      try {
        const menu = await Menu.new({ items: entries });
        await menu.popup(at ? new LogicalPosition(at.x, at.y) : undefined);
      } catch (e) {
        flash(errorMessage(e), true);
      }
    },
    [marked, actionsFor, current, currentIssues, pasteLabel, autoPaste, paste, copy, boards, pin, run, remove, flash],
  );

  const boardOrder = useMemo(() => [null, ...boards.map((b) => b.id)], [boards]);

  // 键盘操作：输入框始终保持焦点用于搜索，方向键、回车等在这里处理
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.isComposing) return;
      const typing = e.target instanceof HTMLTextAreaElement || (e.target instanceof HTMLInputElement && e.target !== input.current);
      const mod = e.ctrlKey;
      if (e.key === "Escape") {
        e.preventDefault();
        if (newBoard !== null) setNewBoard(null);
        else if (preview) setPreview(null);
        else if (marked.length) setMarked([]);
        else if (query) setQuery("");
        else void api.clipHide(true);
        window.setTimeout(() => input.current?.focus(), 0);
        return;
      }
      if (typing) return;
      if (e.key === "ArrowRight" || e.key === "ArrowLeft") {
        // 输入框中有文字时，不按 Shift 的左右键用于移动光标
        if (query && !e.shiftKey && !mod && document.activeElement === input.current && !preview) {
          const el = input.current!;
          if (!(e.key === "ArrowRight" && el.selectionStart === query.length) && !(e.key === "ArrowLeft" && el.selectionStart === 0)) return;
        }
        e.preventDefault();
        const step = e.key === "ArrowRight" ? 1 : -1;
        const next = mod ? (step > 0 ? list.length - 1 : 0) : Math.max(0, Math.min(list.length - 1, index + step));
        if (e.shiftKey && current && list[next]) {
          const add = [current.id, list[next].id];
          setMarked((m) => [...m, ...add.filter((id) => !m.includes(id))]);
        }
        setIndex(next);
        return;
      }
      if (e.key === "Home" || e.key === "End") {
        e.preventDefault();
        setIndex(e.key === "Home" ? 0 : list.length - 1);
        return;
      }
      if (e.key === "Tab") {
        e.preventDefault();
        const at = boardOrder.indexOf(board);
        setBoard(boardOrder[(at + (e.shiftKey ? boardOrder.length - 1 : 1)) % boardOrder.length]);
        return;
      }
      if (e.key === "Enter") {
        e.preventDefault();
        if (newBoard !== null) return;
        void paste(selectedIds(), e.shiftKey ? true : undefined);
        return;
      }
      if (mod && /^[1-9]$/.test(e.key)) {
        e.preventDefault();
        const item = list[Number(e.key) - 1];
        if (item) void paste([item.id], e.shiftKey ? true : undefined);
        return;
      }
      if (e.key === " " && !query && current) {
        e.preventDefault();
        setPreview((p) => (p ? null : { edit: false }));
        return;
      }
      if (mod && e.key.toLowerCase() === "y" && current) {
        e.preventDefault();
        setPreview((p) => (p ? null : { edit: false }));
        return;
      }
      if (mod && e.key.toLowerCase() === "e" && current && current.kind !== "image" && current.kind !== "file") {
        e.preventDefault();
        setPreview({ edit: true });
        return;
      }
      if (mod && e.key.toLowerCase() === "c" && !window.getSelection()?.toString() && !(input.current && input.current.selectionStart !== input.current.selectionEnd)) {
        e.preventDefault();
        void copy(selectedIds());
        return;
      }
      if ((mod && e.key === "Backspace") || (e.key === "Delete" && !query)) {
        e.preventDefault();
        const ids = selectedIds();
        if (ids.length) void remove(ids);
        return;
      }
      if (mod && e.key.toLowerCase() === "p" && current) {
        e.preventDefault();
        const card = strip.current?.querySelector(`[data-id="${current.id}"]`)?.getBoundingClientRect();
        void openMenu(current, card ? { x: card.left + 12, y: card.top + 40 } : undefined);
        return;
      }
      if (mod && e.key === ",") {
        e.preventDefault();
        void openMain("tool:clipboard:settings");
        return;
      }
      if (mod && e.key.toLowerCase() === "a" && document.activeElement === input.current && !query) {
        e.preventDefault();
        setMarked(list.map((i) => i.id));
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [list, index, current, query, preview, marked, newBoard, board, boardOrder, paste, copy, remove, selectedIds, openMenu, openMain]);

  /** 拖动的条目：拖的是多选中的一条时，拖动全部选中的（按选择顺序）。 */
  const dragItems = (item: ClipItem): ClipItem[] =>
    marked.includes(item.id) ? marked.map((id) => list.find((i) => i.id === id)).filter((i): i is ClipItem => Boolean(i)) : [item];

  const onCardClick = (e: React.MouseEvent, item: ClipItem, i: number) => {
    if (e.ctrlKey) {
      setMarked((m) => (m.includes(item.id) ? m.filter((id) => id !== item.id) : [...(m.length || !current ? m : [current.id].filter((id) => id !== item.id)), item.id]));
    } else if (e.shiftKey && current) {
      const [from, to] = [Math.min(index, i), Math.max(index, i)];
      setMarked(list.slice(from, to + 1).map((x) => x.id));
    } else {
      setMarked([]);
    }
    setIndex(i);
    input.current?.focus();
  };

  const createBoard = async (name: string) => {
    if (!name.trim()) return setNewBoard(null);
    await run(async () => {
      const created = await api.clipSavePinboard(null, name, BOARD_COLORS[boards.length % BOARD_COLORS.length]);
      if (current && marked.length === 0) await api.clipSetPinboard([current.id], created.id);
      else if (marked.length) await api.clipSetPinboard(marked, created.id);
      setBoard(created.id);
    });
    setNewBoard(null);
    input.current?.focus();
  };

  const paused = settings?.pausedUntil != null;

  return (
    <div className={`clip-panel${entering ? " entering" : ""}`} onMouseDown={(e) => e.target === e.currentTarget && input.current?.focus()}>
      <header className="clip-bar">
        <div className="clip-search">
          <Search size={15} />
          <input ref={input} value={query} placeholder="搜索剪贴板…" spellCheck={false} onChange={(e) => setQuery(e.target.value)} onBlur={() => !preview && newBoard === null && window.setTimeout(() => document.activeElement === document.body && input.current?.focus(), 0)} />
          {query && (
            <button className="clip-icon-btn" title="清空" onMouseDown={(e) => e.preventDefault()} onClick={() => setQuery("")}>
              <X size={13} />
            </button>
          )}
        </div>
        <nav className="clip-boards" onMouseDown={(e) => e.preventDefault()}>
          <button className={board === null ? "active" : ""} onClick={() => setBoard(null)}>
            <ClipboardList size={13} />
            剪贴板历史
          </button>
          {boards.map((b) => (
            <button key={b.id} className={board === b.id ? "active" : ""} onClick={() => setBoard(b.id)} title={`${b.count} 条`}>
              <span className="clip-dot" style={{ background: b.color }} />
              {b.name}
            </button>
          ))}
          {newBoard !== null ? (
            <input
              className="clip-new-board"
              autoFocus
              value={newBoard}
              placeholder="置顶板名称，回车创建"
              onMouseDown={(e) => e.stopPropagation()}
              onChange={(e) => setNewBoard(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.nativeEvent.isComposing) void createBoard(newBoard);
              }}
              onBlur={() => setNewBoard(null)}
            />
          ) : (
            <button className="clip-icon-btn" title="新建置顶板（会把选中的条目放进去）" onClick={() => setNewBoard("")}>
              <Plus size={14} />
            </button>
          )}
        </nav>
        <div className="clip-kinds" onMouseDown={(e) => e.preventDefault()}>
          {KINDS.map((k) => {
            const Icon = KIND_META[k].icon;
            return (
              <button key={k} className={kind === k ? "active" : ""} title={`只看${KIND_META[k].label}`} onClick={() => setKind(kind === k ? null : k)}>
                <Icon size={14} />
              </button>
            );
          })}
        </div>
        <span className="spacer" />
        {paused && (
          <button className="clip-paused" onMouseDown={(e) => e.preventDefault()} onClick={() => void api.clipPause(0).then(setSettings)}>
            <Pause size={12} />
            已暂停记录 · 恢复
          </button>
        )}
        <button className="clip-icon-btn" title={`剪贴板设置（${MOD},）`} onMouseDown={(e) => e.preventDefault()} onClick={() => void openMain("tool:clipboard:settings")}>
          <Settings2 size={15} />
        </button>
      </header>

      <div className="clip-strip" ref={strip}>
        {list.map((item, i) => (
          <ClipCardItem
            key={item.id}
            item={item}
            index={i}
            selected={i === index}
            marked={marked.includes(item.id) ? marked.indexOf(item.id) + 1 : null}
            query={query}
            jiraReady={jiraReady}
            board={boards.find((b) => b.id === item.pinboard)}
            onClick={(e) => onCardClick(e, item, i)}
            onDoubleClick={() => void paste([item.id])}
            draggable={!dragsAsFiles(dragItems(item))}
            onMouseDown={(e) => {
              if (e.button !== 0) return;
              prepareDrag(dragItems(item));
              pointerDrag(e, dragItems(item), (message) => flash(message, true));
            }}
            onDragStart={(e) => startDrag(e, dragItems(item), (message) => flash(message, true))}
            onDragEnd={(e) => endDrag(e, dragItems(item))}
            onContextMenu={(e) => {
              e.preventDefault();
              if (!marked.includes(item.id)) {
                setMarked([]);
                setIndex(i);
              }
              void openMenu(item, { x: e.clientX, y: e.clientY });
            }}
          />
        ))}
        {items && list.length === 0 && (
          <div className="clip-empty">
            {query || kind ? "没有找到匹配的内容" : board ? "这个置顶板还是空的：在条目上右键，选择“置顶到”" : paused ? "已暂停记录" : "复制一些内容，就会出现在这里"}
          </div>
        )}
      </div>

      <footer className="clip-foot">
        {notice ? (
          <span className={notice.error ? "error-text" : "clip-notice"}>{notice.text}</span>
        ) : (
          <span className="clip-hints">
            <span>
              <CornerDownLeft size={11} /> {pasteLabel}
            </span>
            <span>Shift+Enter 纯文本</span>
            {autoPaste && <span>{MOD}C 复制</span>}
            <span>空格 预览</span>
            <span>{MOD}E 编辑</span>
            <span>{MOD}1–9 快速粘贴</span>
            <span>Tab 切换置顶板</span>
            <span>{MOD}⌫ 删除</span>
            <span>拖动卡片到其他应用</span>
          </span>
        )}
        <span className="spacer" />
        {marked.length > 0 && <span className="clip-count">已选 {marked.length} 条 · Enter 按顺序一起粘贴</span>}
        {settings && !marked.length && <span className="muted">{settings.stats.items.toLocaleString()} 条</span>}
      </footer>

      {preview && current && (
        <PreviewLayer
          key={current.id}
          item={current}
          edit={preview.edit}
          issues={currentIssues}
          pasteLabel={pasteLabel}
          verb={autoPaste ? "粘贴" : "复制"}
          actionsFor={actionsFor}
          onClose={() => {
            setPreview(null);
            input.current?.focus();
          }}
          onPaste={(plain, edited) => void paste([current.id], plain, edited)}
          onEdit={() => setPreview({ edit: true })}
          onError={(e) => flash(e, true)}
        />
      )}
    </div>
  );
}

/** 卡片：只有在可见范围内的才查询问题信息。 */
function ClipCardItem(props: Omit<React.ComponentProps<typeof ClipCard>, "issues" | "baseUrl"> & { jiraReady: boolean }) {
  const { baseUrl } = useSettings();
  const { jiraReady, ...rest } = props;
  const issues = useIssues(props.index < 40 ? itemIssueKeys(props.item, { baseUrl, jiraReady }) : [], jiraReady);
  return <ClipCard {...rest} issues={issues} baseUrl={baseUrl} />;
}

/** 空格打开的预览层：完整内容、命名、编辑后粘贴、智能操作。 */
function PreviewLayer(props: {
  item: ClipItem;
  edit: boolean;
  issues: IssueHit[];
  pasteLabel: string;
  /** “粘贴”或“复制” */
  verb: string;
  actionsFor: (item: ClipItem, text: string, issues: IssueHit[]) => ClipAction[];
  onClose: () => void;
  onPaste: (plain?: boolean, edited?: string) => void;
  onEdit: () => void;
  onError: (message: string) => void;
}) {
  const { item } = props;
  const { baseUrl } = useSettings();
  const [text, setText] = useState(item.text);
  const [draft, setDraft] = useState<string | null>(null);
  const [title, setTitle] = useState(item.title);
  const editor = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    if (item.textLength > item.text.length) void api.clipText(item.id).then((t) => setText(t.text), (e) => props.onError(errorMessage(e)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item.id]);

  useEffect(() => {
    if (props.edit) {
      setDraft((d) => d ?? text);
      window.setTimeout(() => editor.current?.focus(), 0);
    }
  }, [props.edit, text]);

  const saveTitle = () => {
    if (title.trim() !== item.title) void api.clipRename(item.id, title).catch((e) => props.onError(errorMessage(e)));
  };

  const actions = props.actionsFor(item, text, props.issues);
  const editing = draft !== null;

  return (
    <div className="clip-preview" onMouseDown={(e) => e.stopPropagation()}>
      <div className="clip-preview-main">
        {editing ? (
          <textarea
            ref={editor}
            className="clip-editor"
            value={draft}
            spellCheck={false}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && e.ctrlKey) {
                e.preventDefault();
                props.onPaste(true, draft);
              }
            }}
          />
        ) : (
          <ClipPreviewBody item={item} text={text} issues={props.issues} baseUrl={baseUrl} />
        )}
      </div>
      <aside className="clip-preview-side">
        <div className="clip-preview-source">
          <AppIcon item={item} size={22} />
          <div>
            <div>{item.appName ?? "未知来源"}</div>
            <div className="muted small">
              {timeLabel(item.copiedAt)}
              {item.copyCount > 1 ? ` · 复制过 ${item.copyCount} 次` : ""}
              {item.hasHtml ? " · 带格式" : ""}
            </div>
          </div>
          <span className="spacer" />
          <button className="clip-icon-btn" title="关闭（Esc）" onClick={props.onClose}>
            <X size={14} />
          </button>
        </div>
        <input
          className="clip-title-input"
          value={title}
          placeholder="命名（方便搜索，例如“签名”）"
          onChange={(e) => setTitle(e.target.value)}
          onBlur={saveTitle}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.nativeEvent.isComposing) {
              saveTitle();
              (e.target as HTMLInputElement).blur();
            }
          }}
        />
        <div className="clip-preview-buttons">
          {editing ? (
            <>
              <button className="btn primary small-btn" onClick={() => props.onPaste(true, draft)}>
                {props.verb}修改后的内容 <kbd>{MOD}Enter</kbd>
              </button>
              <button
                className="btn small-btn"
                disabled={!draft.trim() || draft === text}
                onClick={() =>
                  void api.clipUpdateText(item.id, draft).then(
                    () => setDraft(null),
                    (e) => props.onError(errorMessage(e)),
                  )
                }
              >
                保存修改
              </button>
            </>
          ) : (
            <>
              <button className="btn primary small-btn" onClick={() => props.onPaste()}>
                {props.pasteLabel} <kbd>Enter</kbd>
              </button>
              {item.kind !== "image" && item.kind !== "file" && (
                <button className="btn small-btn" onClick={props.onEdit}>
                  编辑 <kbd>{MOD}E</kbd>
                </button>
              )}
            </>
          )}
        </div>
        {actions.length > 0 && (
          <ul className="clip-actions">
            {actions.map((a) => (
              <li key={a.id}>
                <button
                  onClick={() =>
                    void Promise.resolve()
                      .then(a.run)
                      .catch((e) => props.onError(errorMessage(e)))
                  }
                >
                  <a.icon size={13} />
                  <span className="ellipsis">{a.label}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </aside>
    </div>
  );
}
