import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Check, ChevronRight } from "lucide-react";
import { errorMessage } from "../api";

export interface MenuAction {
  label: string;
  icon?: ReactNode;
  onSelect?: () => unknown;
  /** 子菜单 */
  children?: MenuInput[];
  /** 打开时才加载的子菜单（例如需要查询服务器的可用流转） */
  loadChildren?: () => Promise<MenuInput[]>;
  danger?: boolean;
  disabled?: boolean;
  /** 显示勾选标记（单选项的当前值） */
  checked?: boolean;
  /** 需要再点一次确认时显示的文字（删除等不可撤销的操作） */
  confirm?: string;
}

export type MenuEntry = MenuAction | "separator";

/** 允许用 `cond && {...}` 按条件添加菜单项。 */
export type MenuInput = MenuEntry | false | null | undefined | "" | 0;

type Anchor = { x: number; y: number } | { rect: DOMRect };

function clean(items: MenuInput[]): MenuEntry[] {
  const result: MenuEntry[] = [];
  for (const item of items) {
    if (!item) continue;
    // 去掉开头、结尾和连续的分隔线
    if (item === "separator" && (result.length === 0 || result[result.length - 1] === "separator")) continue;
    result.push(item);
  }
  if (result[result.length - 1] === "separator") result.pop();
  return result;
}

/**
 * 右键菜单。`open` 在 onContextMenu 中调用（也可以在按钮的 onClick 中调用，菜单显示在按钮下方）；
 * `target` 是当前打开菜单的对象，用于高亮所在行；`menu` 需要渲染到页面中。
 */
export function useContextMenu() {
  const [state, setState] = useState<{ x: number; y: number; items: MenuEntry[]; target: string | null } | null>(null);
  const close = useCallback(() => setState(null), []);
  const open = useCallback((e: React.MouseEvent | MouseEvent, items: MenuInput[], target: string | null = null) => {
    e.preventDefault();
    e.stopPropagation();
    const list = clean(items);
    if (list.length === 0) return;
    if (e.type === "click") {
      const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
      setState({ x: rect.left, y: rect.bottom + 4, items: list, target });
    } else {
      setState({ x: e.clientX, y: e.clientY, items: list, target });
    }
  }, []);
  /** 在元素下方打开（例如异步加载菜单项后，原来的事件已经失效）。 */
  const openAt = useCallback((el: HTMLElement, items: MenuInput[], target: string | null = null) => {
    const list = clean(items);
    const rect = el.getBoundingClientRect();
    if (list.length > 0) setState({ x: rect.left, y: rect.bottom + 4, items: list, target });
  }, []);
  const menu = state
    ? createPortal(<MenuList key={`${state.x},${state.y}`} items={state.items} anchor={{ x: state.x, y: state.y }} onDone={close} focus />, document.body)
    : null;
  return { open, openAt, target: state?.target ?? null, menu };
}

const hasSub = (item: MenuAction) => Boolean(item.children || item.loadChildren);

/** 子菜单；需要加载的先显示“加载中”。 */
function SubMenu({ item, ...rest }: { item: MenuAction; anchor: Anchor; onDone: () => void; onBack: () => void; focus: boolean }) {
  const [loaded, setLoaded] = useState<MenuEntry[] | null>(item.children ? clean(item.children) : null);
  useEffect(() => {
    if (!item.loadChildren) return;
    let alive = true;
    item.loadChildren().then(
      (list) => alive && setLoaded(clean(list).length > 0 ? clean(list) : [{ label: "没有可用的选项", disabled: true }]),
      (e) => alive && setLoaded([{ label: `加载失败：${errorMessage(e)}`, disabled: true }]),
    );
    return () => {
      alive = false;
    };
  }, [item]);
  // 加载完成后重新挂载，以便按实际大小重新定位
  return loaded ? <MenuList key="loaded" items={loaded} {...rest} /> : <MenuList key="loading" items={[{ label: "加载中…", disabled: true }]} {...rest} />;
}

function MenuList({ items, anchor, onDone, onBack, focus }: { items: MenuEntry[]; anchor: Anchor; onDone: () => void; onBack?: () => void; focus: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null);
  const [active, setActive] = useState(-1);
  const [sub, setSub] = useState<{ index: number; rect: DOMRect; focus: boolean } | null>(null);
  const [armed, setArmed] = useState<number | null>(null);

  // 放在视口内：右侧放不下时向左展开，底部放不下时上移
  useLayoutEffect(() => {
    const el = ref.current!;
    const { width, height } = el.getBoundingClientRect();
    const margin = 6;
    let left: number;
    let top: number;
    if ("rect" in anchor) {
      left = anchor.rect.right - 2;
      top = anchor.rect.top - 5;
      if (left + width > window.innerWidth - margin) left = anchor.rect.left - width + 2;
    } else {
      left = anchor.x;
      top = anchor.y;
      if (left + width > window.innerWidth - margin) left = anchor.x - width;
    }
    if (top + height > window.innerHeight - margin) top = window.innerHeight - margin - height;
    setPos({ left: Math.max(margin, left), top: Math.max(margin, top) });
    if (focus) el.focus();
  }, []);

  // 顶层菜单：点击其他位置、滚动、窗口失去焦点时关闭
  useEffect(() => {
    if (onBack) return;
    const onPointer = (e: MouseEvent) => {
      if (!(e.target as Element).closest?.(".context-menu")) onDone();
    };
    window.addEventListener("mousedown", onPointer, true);
    window.addEventListener("scroll", onDone, true);
    window.addEventListener("resize", onDone);
    window.addEventListener("blur", onDone);
    return () => {
      window.removeEventListener("mousedown", onPointer, true);
      window.removeEventListener("scroll", onDone, true);
      window.removeEventListener("resize", onDone);
      window.removeEventListener("blur", onDone);
    };
  }, [onBack, onDone]);

  const enabled = (i: number) => {
    const item = items[i];
    return item !== "separator" && !item.disabled;
  };

  const openSub = (i: number, viaKeyboard: boolean) => {
    const el = ref.current?.querySelectorAll<HTMLElement>("[data-index]")[i];
    if (el) setSub({ index: i, rect: el.getBoundingClientRect(), focus: viaKeyboard });
  };

  const choose = (i: number, viaKeyboard = false) => {
    const item = items[i];
    if (item === "separator" || item.disabled) return;
    if (hasSub(item)) return openSub(i, viaKeyboard);
    if (item.confirm && armed !== i) return setArmed(i);
    onDone();
    Promise.resolve()
      .then(() => item.onSelect?.())
      .catch((e) => console.error(e));
  };

  const onKeyDown = (e: React.KeyboardEvent) => {
    // 子菜单有焦点时由它处理
    if (e.target !== ref.current) return;
    e.stopPropagation();
    const step = (dir: 1 | -1) => {
      for (let n = 1; n <= items.length; n++) {
        const i = (active + dir * n + items.length * 2) % items.length;
        if (enabled(i)) return setActive(i);
      }
    };
    switch (e.key) {
      case "ArrowDown":
        step(1);
        break;
      case "ArrowUp":
        step(-1);
        break;
      case "ArrowRight":
        if (active >= 0 && hasSub(items[active] as MenuAction)) openSub(active, true);
        break;
      case "ArrowLeft":
        onBack?.();
        break;
      case "Enter":
      case " ":
        if (active >= 0) choose(active, true);
        break;
      case "Escape":
        (onBack ?? onDone)();
        break;
      default:
        return;
    }
    e.preventDefault();
  };

  const subItem = sub ? (items[sub.index] as MenuAction) : null;

  return (
    <div
      ref={ref}
      className="context-menu"
      role="menu"
      tabIndex={-1}
      style={pos ? { left: pos.left, top: pos.top } : { left: 0, top: 0, visibility: "hidden" }}
      onKeyDown={onKeyDown}
      onContextMenu={(e) => e.preventDefault()}
    >
      {items.map((item, i) =>
        item === "separator" ? (
          <div key={i} className="context-menu-separator" role="separator" />
        ) : (
          <button
            key={i}
            data-index={i}
            type="button"
            role="menuitem"
            className={`context-menu-item${item.danger || armed === i ? " danger" : ""}${active === i || sub?.index === i ? " active" : ""}`}
            disabled={item.disabled}
            onMouseEnter={() => {
              setActive(i);
              if (hasSub(item)) openSub(i, false);
              else setSub(null);
            }}
            onClick={() => choose(i)}
          >
            <span className="context-menu-icon">{item.checked ? <Check size={14} /> : item.icon}</span>
            <span className="grow">{armed === i ? item.confirm : item.label}</span>
            {hasSub(item) && <ChevronRight size={13} className="muted" />}
          </button>
        ),
      )}
      {sub && subItem && hasSub(subItem) && (
        <SubMenu
          key={sub.index}
          item={subItem}
          anchor={{ rect: sub.rect }}
          onDone={onDone}
          focus={sub.focus}
          onBack={() => {
            setSub(null);
            ref.current?.focus();
          }}
        />
      )}
    </div>
  );
}
