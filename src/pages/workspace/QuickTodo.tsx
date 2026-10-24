import { useState } from "react";
import { api, errorMessage } from "../../api";
import { ErrorBox, Modal } from "../../components/common";
import { addDays, today, workspaceChanged } from "../../lib/workspace";

const DUE_OPTIONS = [
  { label: "不设日期", due: () => null },
  { label: "今天", due: () => today() },
  { label: "明天", due: () => addDays(today(), 1) },
];

/** Ctrl+Shift+N：在任何页面快速记一条待办。 */
export function QuickTodo({ onClose, initialTitle = "" }: { onClose: () => void; initialTitle?: string }) {
  const [title, setTitle] = useState(initialTitle);
  const [dueIndex, setDueIndex] = useState(1);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const save = async () => {
    if (!title.trim()) return;
    setSaving(true);
    try {
      await api.wsSaveTodo({ title: title.trim(), due: DUE_OPTIONS[dueIndex].due() });
      workspaceChanged();
      onClose();
    } catch (e) {
      setError(errorMessage(e));
      setSaving(false);
    }
  };

  return (
    <Modal
      title="新建待办"
      onClose={onClose}
      dirty={Boolean(title.trim())}
      footer={
        <>
          <span className="muted small grow">↵ 保存 · Esc 关闭</span>
          <button className="btn" onClick={onClose}>
            取消
          </button>
          <button className="btn primary" disabled={!title.trim() || saving} onClick={save}>
            保存
          </button>
        </>
      }
    >
      <input
        value={title}
        placeholder="要做什么？"
        onChange={(e) => setTitle(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && !e.nativeEvent.isComposing) {
            e.preventDefault();
            void save();
          }
        }}
      />
      <div className="segmented">
        {DUE_OPTIONS.map((o, i) => (
          <button key={o.label} className={dueIndex === i ? "active" : ""} onClick={() => setDueIndex(i)}>
            {o.label}
          </button>
        ))}
      </div>
      {error && <ErrorBox message={error} />}
    </Modal>
  );
}
