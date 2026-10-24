// 把文件拖进窗口：放到编辑区（带 data-file-drop 的元素）时插入到编辑区，
// 否则交给当前页面登记的默认目标（例如打开的 Jira 问题，上传为附件）。拖动过程中显示将要放到哪里。
import { useEffect, useState } from "react";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { Upload } from "lucide-react";
import { usePageActive } from "../state/nav";

/** 文件放到编辑区时，在该元素上派发的事件，`detail` 为文件路径。 */
export const FILE_DROP_EVENT = "nextworkzone-file-drop";

type DropTarget = { label: string; onDrop: (paths: string[]) => void };

/** 当前页面登记的默认目标；后登记的优先。 */
const targets: DropTarget[] = [];

/** 登记页面的默认放置目标（例如“上传到 ABC-1 的附件”）。页面隐藏时不登记，避免文件被交给看不见的页面。 */
export function useDropTarget(label: string, onDrop: (paths: string[]) => void, enabled = true) {
  const active = usePageActive();
  useEffect(() => {
    if (!enabled || !active) return;
    const target = { label, onDrop };
    targets.push(target);
    return () => {
      const index = targets.indexOf(target);
      if (index >= 0) targets.splice(index, 1);
    };
  }, [label, onDrop, enabled, active]);
}

type Hover = { count: number; zone: HTMLElement | null; label: string | null; blocked: boolean };

/** 鼠标位置（物理像素）下的放置位置。打开对话框时只接受对话框里的编辑区，避免误传到背后的问题。 */
function locate(position: { x: number; y: number }): Omit<Hover, "count"> {
  const scale = window.devicePixelRatio || 1;
  const el = document.elementFromPoint(position.x / scale, position.y / scale);
  // 隐藏的页面里也可能有打开的对话框，只看显示着的
  const modal = [...document.querySelectorAll(".modal")].find((m) => m.getClientRects().length > 0);
  let zone = el?.closest<HTMLElement>("[data-file-drop]") ?? null;
  if (zone && modal && !modal.contains(zone)) zone = null;
  if (zone) return { zone, label: zone.dataset.fileDrop ?? "插入到这里", blocked: false };
  if (modal) return { zone: null, label: null, blocked: true };
  const target = targets[targets.length - 1];
  return { zone: null, label: target?.label ?? null, blocked: false };
}

export function FileDropLayer() {
  const [hover, setHover] = useState<Hover | null>(null);

  useEffect(() => {
    let count = 0;
    let current: HTMLElement | null = null;
    const highlight = (zone: HTMLElement | null) => {
      if (current === zone) return;
      current?.classList.remove("file-drop-over");
      zone?.classList.add("file-drop-over");
      current = zone;
    };
    const unlisten = getCurrentWebview().onDragDropEvent((event) => {
      const payload = event.payload;
      if (payload.type === "enter") count = payload.paths.length;
      // 拖动的是文字（例如从剪贴板页面拖出的条目）时没有文件，不显示提示
      if ((payload.type === "enter" || payload.type === "over") && count === 0) return;
      if (payload.type === "enter" || payload.type === "over") {
        const where = locate(payload.position);
        highlight(where.zone);
        setHover({ count, ...where });
      } else if (payload.type === "leave") {
        highlight(null);
        setHover(null);
      } else if (payload.type === "drop") {
        const where = locate(payload.position);
        highlight(null);
        setHover(null);
        if (payload.paths.length === 0) return;
        if (where.zone) where.zone.dispatchEvent(new CustomEvent(FILE_DROP_EVENT, { detail: payload.paths }));
        else if (!where.blocked) targets[targets.length - 1]?.onDrop(payload.paths);
      }
    });
    return () => {
      highlight(null);
      void unlisten.then((fn) => fn());
    };
  }, []);

  if (!hover || (!hover.label && !hover.blocked)) return null;
  const files = hover.count > 0 ? `（${hover.count} 个文件）` : "";
  // 放到编辑区时编辑区本身高亮，只在底部提示；否则整个窗口显示放置区域
  return (
    <div className={`file-drop-layer${hover.zone ? " zone" : ""}${hover.blocked ? " blocked" : ""}`}>
      <div className="file-drop-pill">
        <Upload size={16} />
        {hover.blocked ? "请把文件拖到对话框中的编辑区" : `松开以${hover.label}${files}`}
      </div>
    </div>
  );
}
