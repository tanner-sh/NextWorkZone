import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Check, ChevronRight } from "lucide-react";
import { invoke } from "@tauri-apps/api/core";
import { Menu, type CheckMenuItemOptions, type MenuItemOptions, type PredefinedMenuItemOptions, type SubmenuOptions } from "@tauri-apps/api/menu";
import { confirm as confirmDialog } from "@tauri-apps/plugin-dialog";
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

/** macOS 上用系统菜单：外观（Liquid Glass）、动画和键盘操作与系统一致。其他平台用网页菜单。 */
const NATIVE = navigator.userAgent.includes("Mac") && "__TAURI_INTERNALS__" in window;

/**
 * 右键菜单。`open` 在 onContextMenu 中调用（也可以在按钮的 onClick 中调用，菜单显示在按钮下方）；
 * `target` 是当前打开菜单的对象，用于高亮所在行；`menu` 需要渲染到页面中。
 */
export function useContextMenu() {
  const [state, setState] = useState<{ x: number; y: number; items: MenuEntry[]; target: string | null } | null>(null);
  const [nativeTarget, setNativeTarget] = useState<string | null>(null);
  const close = useCallback(() => setState(null), []);
  const show = useCallback((x: number, y: number, list: MenuEntry[], target: string | null) => {
    if (!NATIVE) return setState({ x, y, items: list, target });
    setNativeTarget(target);
    void popupNative(list, x, y).finally(() => setNativeTarget(null));
  }, []);
  const open = useCallback(
    (e: React.MouseEvent | MouseEvent, items: MenuInput[], target: string | null = null) => {
      e.preventDefault();
      e.stopPropagation();
      const list = clean(items);
      if (list.length === 0) return;
      if (e.type === "click") {
        const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
        show(rect.left, rect.bottom + 4, list, target);
      } else {
        show(e.clientX, e.clientY, list, target);
      }
    },
    [show],
  );
  /** 在元素下方打开（例如异步加载菜单项后，原来的事件已经失效）。 */
  const openAt = useCallback(
    (el: HTMLElement, items: MenuInput[], target: string | null = null) => {
      const list = clean(items);
      const rect = el.getBoundingClientRect();
      if (list.length > 0) show(rect.left, rect.bottom + 4, list, target);
    },
    [show],
  );
  const menu = state
    ? createPortal(<MenuList key={`${state.x},${state.y}`} items={state.items} anchor={{ x: state.x, y: state.y }} onDone={close} focus />, document.body)
    : null;
  return { open, openAt, target: state?.target ?? nativeTarget, menu };
}

// ---------- 系统菜单 ----------

type NativeEntry = MenuItemOptions | CheckMenuItemOptions | SubmenuOptions | PredefinedMenuItemOptions;

/** 在窗口中的 (x, y) 处弹出系统菜单，菜单关闭后返回。 */
async function popupNative(items: MenuEntry[], x: number, y: number) {
  // 打开时才加载的子菜单先显示“加载中”，加载完成后替换（菜单打开时也会更新）
  const pending: { id: string; load: () => Promise<MenuInput[]> }[] = [];
  const menu = await Menu.new({ items: nativeEntries(items, pending) });
  for (const { id, load } of pending) {
    const fill = async (list: MenuEntry[]) => {
      const sub = await menu.get(id);
      if (!sub || !("removeAt" in sub)) return;
      await sub.append(nativeEntries(list, pending));
      await sub.removeAt(0);
    };
    load().then(
      (list) => fill(clean(list).length > 0 ? clean(list) : [{ label: "没有可用的选项", disabled: true }]),
      (e) => fill([{ label: `加载失败：${errorMessage(e)}`, disabled: true }]),
    );
  }
  try {
    // 不用 menu.popup：它在菜单打开期间占用资源，上面的“加载中”就无法替换（见 src-tauri/src/context_menu.rs）
    await invoke("menu_popup", { rid: menu.rid, x, y });
  } catch (e) {
    console.error(e);
  }
}

let nativeId = 0;

function nativeEntries(items: MenuEntry[], pending: { id: string; load: () => Promise<MenuInput[]> }[]): NativeEntry[] {
  return items.map((item): NativeEntry => {
    if (item === "separator") return { item: "Separator" };
    const enabled = !item.disabled;
    if (item.children) return { text: item.label, enabled, items: nativeEntries(clean(item.children), pending) };
    if (item.loadChildren) {
      const id = `nwz-sub-${++nativeId}`;
      pending.push({ id, load: item.loadChildren });
      return { id, text: item.label, enabled, items: [{ text: "加载中…", enabled: false }] };
    }
    const action = () => void runNative(item);
    return item.checked !== undefined ? { text: item.label, enabled, checked: item.checked, action } : { text: item.label, enabled, action };
  });
}

/** 执行菜单项；需要确认的（删除等）先弹出系统的确认框。 */
async function runNative(item: MenuAction) {
  if (item.confirm) {
    // confirm 是网页菜单中“再点一次”的提示，括号里的说明在确认框中保留
    const detail = item.confirm.match(/（(.+)）/)?.[1];
    const ok = await confirmDialog(detail ?? `确定要${item.label}吗？`, { title: item.label, kind: "warning", okLabel: item.label, cancelLabel: "取消" });
    if (!ok) return;
  }
  try {
    await item.onSelect?.();
  } catch (e) {
    console.error(e);
  }
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
