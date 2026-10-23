import { useEffect, useState } from "react";
import { errorMessage } from "../api";

const TOAST_EVENT = "nextworkzone-toast";
const TOAST_MS = 2200;

/** 在窗口底部短暂显示一条提示（复制成功、已添加待办等）。 */
export function toast(message: string, error = false) {
  window.dispatchEvent(new CustomEvent(TOAST_EVENT, { detail: { message, error } }));
}

/** 包装菜单、按钮的异步操作：失败时提示错误。 */
export const guarded = (action: () => unknown) => () =>
  Promise.resolve()
    .then(action)
    .catch((e) => toast(`操作失败：${errorMessage(e)}`, true));

export function Toasts() {
  const [items, setItems] = useState<{ id: number; message: string; error: boolean }[]>([]);
  useEffect(() => {
    let seq = 0;
    const onToast = (e: Event) => {
      const { message, error } = (e as CustomEvent<{ message: string; error: boolean }>).detail;
      const id = ++seq;
      setItems((list) => [...list.slice(-2), { id, message, error }]);
      window.setTimeout(() => setItems((list) => list.filter((t) => t.id !== id)), error ? TOAST_MS * 2 : TOAST_MS);
    };
    window.addEventListener(TOAST_EVENT, onToast);
    return () => window.removeEventListener(TOAST_EVENT, onToast);
  }, []);
  if (items.length === 0) return null;
  return (
    <div className="toasts" role="status">
      {items.map((t) => (
        <div key={t.id} className={`toast${t.error ? " error" : ""}`}>
          {t.message}
        </div>
      ))}
    </div>
  );
}
