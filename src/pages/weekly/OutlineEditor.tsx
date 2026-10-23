import { useEffect, useRef, useState, type ClipboardEvent, type KeyboardEvent } from "react";
import type { OutlineItem } from "../../api";

export interface EditorItem extends OutlineItem {
  id: number;
}

let nextId = 1;
export const withIds = (items: OutlineItem[]): EditorItem[] => items.map((i) => ({ ...i, id: nextId++ }));
export const withoutIds = (items: EditorItem[]): OutlineItem[] =>
  items.map(({ level, text }) => ({ level, text })).filter((i) => i.text.trim() !== "");

const MAX_LEVEL = 4;

/**
 * 大纲式列表编辑器：回车新增一项，Tab / Shift+Tab 调整层级，空项上退格删除，
 * 粘贴多行文本时按行拆分（行首空格或 “-” 表示层级）。
 */
export function OutlineEditor({ items, onChange, placeholder }: { items: EditorItem[]; onChange: (items: EditorItem[]) => void; placeholder: string }) {
  const refs = useRef(new Map<number, HTMLInputElement>());
  const [focus, setFocus] = useState<{ id: number; caret?: number } | null>(null);

  useEffect(() => {
    if (!focus) return;
    const input = refs.current.get(focus.id);
    if (input) {
      input.focus();
      const pos = focus.caret ?? input.value.length;
      input.setSelectionRange(pos, pos);
    }
    setFocus(null);
  }, [focus]);

  const list = items.length > 0 ? items : [];

  const update = (index: number, patch: Partial<EditorItem>) => onChange(list.map((it, i) => (i === index ? { ...it, ...patch } : it)));

  const insertAfter = (index: number, level: number, text = "") => {
    const item = { id: nextId++, level, text };
    onChange([...list.slice(0, index + 1), item, ...list.slice(index + 1)]);
    setFocus({ id: item.id, caret: 0 });
  };

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>, index: number) => {
    const item = list[index];
    const input = event.currentTarget;
    if (event.nativeEvent.isComposing) return;
    switch (event.key) {
      case "Enter": {
        event.preventDefault();
        // 在光标处拆分当前项
        const caret = input.selectionStart ?? item.text.length;
        const before = item.text.slice(0, caret);
        const after = item.text.slice(caret);
        const next = { id: nextId++, level: item.level, text: after };
        onChange([...list.slice(0, index), { ...item, text: before }, next, ...list.slice(index + 1)]);
        setFocus({ id: next.id, caret: 0 });
        break;
      }
      case "Tab": {
        event.preventDefault();
        const caret = input.selectionStart ?? 0;
        if (event.shiftKey) {
          if (item.level > 0) update(index, { level: item.level - 1 });
        } else {
          const max = index === 0 ? 0 : Math.min(list[index - 1].level + 1, MAX_LEVEL);
          if (item.level < max) update(index, { level: item.level + 1 });
        }
        setFocus({ id: item.id, caret });
        break;
      }
      case "Backspace": {
        if (input.selectionStart === 0 && input.selectionEnd === 0) {
          event.preventDefault();
          if (item.level > 0) {
            update(index, { level: item.level - 1 });
            setFocus({ id: item.id, caret: 0 });
          } else if (index > 0) {
            // 与上一项合并
            const prev = list[index - 1];
            onChange([...list.slice(0, index - 1), { ...prev, text: prev.text + item.text }, ...list.slice(index + 1)]);
            setFocus({ id: prev.id, caret: prev.text.length });
          }
        }
        break;
      }
      case "ArrowUp":
        if (index > 0) {
          event.preventDefault();
          setFocus({ id: list[index - 1].id });
        }
        break;
      case "ArrowDown":
        if (index < list.length - 1) {
          event.preventDefault();
          setFocus({ id: list[index + 1].id });
        }
        break;
    }
  };

  const onPaste = (event: ClipboardEvent<HTMLInputElement>, index: number) => {
    const text = event.clipboardData.getData("text/plain");
    if (!text.includes("\n")) return;
    event.preventDefault();
    const base = list[index].level;
    const pasted = parseLines(text).map((p) => ({ id: nextId++, level: Math.min(base + p.level, MAX_LEVEL), text: p.text }));
    if (pasted.length === 0) return;
    const current = list[index];
    const replaceCurrent = current.text.trim() === "";
    const merged = replaceCurrent
      ? [...list.slice(0, index), ...pasted, ...list.slice(index + 1)]
      : [...list.slice(0, index + 1), ...pasted, ...list.slice(index + 1)];
    onChange(merged);
    setFocus({ id: pasted[pasted.length - 1].id });
  };

  if (list.length === 0) {
    return (
      <button className="outline-empty" onClick={() => insertAfter(-1, 0)}>
        {placeholder}
      </button>
    );
  }

  return (
    <ul className="outline">
      {list.map((item, index) => (
        <li key={item.id} style={{ paddingLeft: item.level * 22 }} className={`outline-item level-${Math.min(item.level, 2)}`}>
          <span className="bullet" aria-hidden />
          <input
            ref={(el) => {
              if (el) refs.current.set(item.id, el);
              else refs.current.delete(item.id);
            }}
            value={item.text}
            placeholder={index === 0 ? placeholder : ""}
            onChange={(e) => update(index, { text: e.target.value })}
            onKeyDown={(e) => onKeyDown(e, index)}
            onPaste={(e) => onPaste(e, index)}
          />
        </li>
      ))}
    </ul>
  );
}

/** 把多行文本解析为大纲：每 2 个空格或 1 个 Tab 为一级缩进，行首的 “-”“*”“•” 会被去掉。 */
export function parseLines(text: string): OutlineItem[] {
  return text
    .split(/\r?\n/)
    .map((line) => {
      const indent = line.match(/^[\t ]*/)?.[0] ?? "";
      const width = [...indent].reduce((n, c) => n + (c === "\t" ? 2 : 1), 0);
      const content = line.trim().replace(/^[-*•]\s*/, "");
      return { level: Math.floor(width / 2), text: content };
    })
    .filter((i) => i.text !== "");
}
