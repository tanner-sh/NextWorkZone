import { useCallback, useEffect, useRef, useState } from "react";
import { emit, listen } from "@tauri-apps/api/event";
import { CalendarDays, CheckSquare, ClipboardPaste, Inbox } from "lucide-react";
import { api, errorMessage, WORKSPACE_SYNCED_EVENT } from "../../api";
import { addDays, today, workspaceChanged } from "../../lib/workspace";
import { docInput } from "./docMenu";

type Mode = "todo" | "daily" | "inbox";

const MODES: { id: Mode; label: string; icon: typeof CheckSquare; placeholder: string }[] = [
  { id: "todo", label: "待办", icon: CheckSquare, placeholder: "要做什么？" },
  { id: "daily", label: "日记", icon: CalendarDays, placeholder: "记一笔，追加到今天的日记" },
  { id: "inbox", label: "收件箱", icon: Inbox, placeholder: "先记下来，稍后在收件箱里处理" },
];

const DUE_OPTIONS = [
  { label: "今天", due: () => today() },
  { label: "明天", due: () => addDays(today(), 1) },
  { label: "不设日期", due: () => null },
];

const MODE_KEY = "nextworkzone.capture.mode";

function savedMode(): Mode {
  try {
    const mode = localStorage.getItem(MODE_KEY);
    return mode === "daily" || mode === "inbox" ? mode : "todo";
  } catch {
    return "todo";
  }
}

const pad = (n: number) => String(n).padStart(2, "0");

/** 全局快捷键弹出的快速记录窗口：Tab 切换类型，回车保存，Esc 收起。 */
export function CaptureWindow() {
  const [mode, setMode] = useState<Mode>(savedMode);
  const [text, setText] = useState("");
  const [dueIndex, setDueIndex] = useState(0);
  const [clipboard, setClipboard] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const input = useRef<HTMLTextAreaElement>(null);

  // 每次弹出时清空并聚焦，读取剪贴板（可一键使用）
  const reset = useCallback(() => {
    setText("");
    setError(null);
    setSaved(null);
    setBusy(false);
    api.captureClipboard().then(setClipboard, () => setClipboard(null));
    window.setTimeout(() => input.current?.focus(), 0);
  }, []);
  useEffect(() => {
    reset();
    const unlisten = listen("capture-open", reset);
    return () => void unlisten.then((fn) => fn());
  }, [reset]);

  const switchMode = (next: Mode) => {
    setMode(next);
    try {
      localStorage.setItem(MODE_KEY, next);
    } catch {
      // 不记忆
    }
    input.current?.focus();
  };

  const save = async () => {
    const value = text.trim();
    if (!value || busy) return;
    setBusy(true);
    setError(null);
    try {
      if (mode === "todo") {
        await api.wsSaveTodo({ title: value, due: DUE_OPTIONS[dueIndex].due() });
        setSaved("已加入待办");
      } else if (mode === "daily") {
        const doc = await api.wsDaily(today());
        const now = new Date();
        const line = `- ${pad(now.getHours())}:${pad(now.getMinutes())} ${value.replace(/\n+/g, " ")}`;
        const content = doc.content.trim() ? `${doc.content.replace(/\s+$/, "")}\n${line}\n` : `${line}\n`;
        await api.wsSaveDoc(docInput(doc, { content, kind: "daily", title: doc.title || today() }));
        setSaved("已写入今天的日记");
      } else {
        const [title, ...rest] = value.split("\n");
        const url = value.match(/https?:\/\/\S+/)?.[0] ?? null;
        await api.wsCapture(title.trim(), rest.join("\n").trim(), url);
        setSaved("已存入收件箱");
      }
      workspaceChanged();
      // 通知主窗口刷新列表
      void emit(WORKSPACE_SYNCED_EVENT, null);
      window.setTimeout(() => void api.captureHide(), 500);
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  };

  const onKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.nativeEvent.isComposing) return;
    if (e.key === "Escape") {
      e.preventDefault();
      void api.captureHide();
    } else if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      void save();
    } else if (e.key === "Tab") {
      e.preventDefault();
      const index = MODES.findIndex((m) => m.id === mode);
      switchMode(MODES[(index + (e.shiftKey ? MODES.length - 1 : 1)) % MODES.length].id);
    } else if ((e.metaKey || e.ctrlKey) && ["1", "2", "3"].includes(e.key)) {
      e.preventDefault();
      switchMode(MODES[Number(e.key) - 1].id);
    }
  };

  const current = MODES.find((m) => m.id === mode)!;

  return (
    <div className="capture">
      <div className="capture-head" data-tauri-drag-region>
        <div className="segmented small-seg">
          {MODES.map((m) => (
            <button key={m.id} className={mode === m.id ? "active" : ""} onClick={() => switchMode(m.id)}>
              <m.icon size={13} />
              {m.label}
            </button>
          ))}
        </div>
        <span className="muted small" data-tauri-drag-region>
          Tab 切换 · ↵ 保存 · ⇧↵ 换行 · Esc 收起
        </span>
      </div>
      <textarea ref={input} className="capture-input" value={text} rows={3} placeholder={current.placeholder} onChange={(e) => setText(e.target.value)} onKeyDown={onKeyDown} />
      <div className="capture-foot">
        {mode === "todo" && (
          <div className="segmented small-seg">
            {DUE_OPTIONS.map((o, i) => (
              <button key={o.label} className={dueIndex === i ? "active" : ""} onClick={() => setDueIndex(i)}>
                {o.label}
              </button>
            ))}
          </div>
        )}
        {clipboard && !text && (
          <button className="btn small-btn capture-clip" title={clipboard} onClick={() => (setText(clipboard), input.current?.focus())}>
            <ClipboardPaste size={13} />
            <span className="ellipsis">使用剪贴板：{clipboard.replace(/\s+/g, " ").slice(0, 40)}</span>
          </button>
        )}
        <span className="spacer" />
        {error && <span className="capture-error small">{error}</span>}
        {saved && <span className="capture-saved small">{saved}</span>}
        <button className="btn primary small-btn" disabled={!text.trim() || busy} onClick={() => void save()}>
          保存
        </button>
      </div>
    </div>
  );
}
