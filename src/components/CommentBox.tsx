import { useState } from "react";
import { Send } from "lucide-react";
import { errorMessage } from "../api";
import { ErrorBox } from "./common";

/** 评论输入框：Ctrl+Enter 发送，Esc 取消（有取消按钮时）。 */
export function CommentBox({ placeholder, onSubmit, onCancel, initial = "", submitLabel = "发送" }: { placeholder: string; onSubmit: (text: string) => Promise<void>; onCancel?: () => void; initial?: string; submitLabel?: string }) {
  const [text, setText] = useState(initial);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const submit = async () => {
    if (!text.trim() || sending) return;
    setSending(true);
    setError(null);
    try {
      await onSubmit(text);
      setText("");
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setSending(false);
    }
  };
  return (
    <div className="wiki-comment-box">
      <textarea
        value={text}
        rows={text ? Math.min(Math.max(text.split("\n").length + 1, 4), 16) : 2}
        placeholder={placeholder}
        autoFocus={Boolean(onCancel)}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && e.ctrlKey) {
            e.preventDefault();
            void submit();
          } else if (e.key === "Escape" && onCancel) {
            onCancel();
          }
        }}
      />
      {error && <ErrorBox message={error} />}
      {(text || onCancel) && (
        <div className="wiki-comment-actions">
          {onCancel && (
            <button className="btn subtle" onClick={onCancel}>
              取消
            </button>
          )}
          <button className="btn primary" disabled={!text.trim() || sending} onClick={submit}>
            <Send size={13} />
            {sending ? `${submitLabel}中…` : submitLabel}
          </button>
        </div>
      )}
    </div>
  );
}
