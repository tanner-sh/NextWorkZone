// 把条目拖到其他应用：文字（含链接、代码、颜色）用网页拖放带上纯文本和格式，图片、文件由系统做文件拖放
// （放到文件管理器、聊天、邮件中就是文件）。
import { api, errorMessage, type ClipItem } from "../../../api";

/** 完整的文字和 HTML。列表中的文字可能只有开头一部分，拖动开始时来不及异步读取，所以按下鼠标时先取好。 */
const full = new Map<string, { text: string; html: string | null }>();

const needsFetch = (item: ClipItem) => (item.kind !== "image" && item.kind !== "file" && item.textLength > item.text.length) || item.hasHtml;

/** 按下鼠标时调用：预先读取要拖动的文字条目的完整内容。 */
export function prepareDrag(items: ClipItem[]) {
  for (const item of items) {
    if (needsFetch(item) && !full.has(item.id)) void api.clipText(item.id).then((t) => full.set(item.id, t), () => {});
  }
}

const isFileLike = (item: ClipItem) => item.kind === "image" || item.kind === "file";

const escapeHtml = (text: string) => text.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]!);

/** 是否作为文件拖出：有图片或文件时整体作为文件拖出（文字不参与）。 */
export const dragsAsFiles = (items: ClipItem[]) => items.some(isFileLike);

/**
 * 图片、文件的拖动：在 `mousedown` 时调用，鼠标按住移动几个像素后由系统开始文件拖放。
 * 不能等网页的 `dragstart`：那时网页已经接管了这次拖动，系统拖放无法再开始。
 */
export function pointerDrag(e: React.MouseEvent, items: ClipItem[], onError: (message: string) => void) {
  if (e.button !== 0 || !dragsAsFiles(items)) return;
  const [x, y] = [e.clientX, e.clientY];
  const ids = items.filter(isFileLike).map((i) => i.id);
  const move = (ev: MouseEvent) => {
    if (Math.hypot(ev.clientX - x, ev.clientY - y) < 5) return;
    stop();
    void api.clipDrag(ids).catch((err) => onError(errorMessage(err)));
  };
  const stop = () => {
    window.removeEventListener("mousemove", move);
    window.removeEventListener("mouseup", stop);
  };
  window.addEventListener("mousemove", move);
  window.addEventListener("mouseup", stop);
}

/**
 * 文字条目的 `dragstart`：带上纯文本，有格式时同时带上 HTML。`items` 是要拖动的条目（多选时按选择顺序）。
 * 内容还没读取完时取消这次拖动，`onError` 收到原因。
 */
export function startDrag(e: React.DragEvent, items: ClipItem[], onError: (message: string) => void) {
  if (dragsAsFiles(items)) {
    e.preventDefault();
    return;
  }
  const parts = items.map((item) => (needsFetch(item) ? full.get(item.id) : { text: item.text, html: null }));
  if (parts.some((p) => !p)) {
    e.preventDefault();
    prepareDrag(items);
    onError("内容较长，正在读取，请再拖一次");
    return;
  }
  const text = parts.map((p) => p!.text).join("\n");
  const dt = e.dataTransfer;
  dt.effectAllowed = "copy";
  dt.setData("text/plain", text);
  const htmls = parts.map((p) => p!.html ?? `<p>${escapeHtml(p!.text).replace(/\n/g, "<br>")}</p>`);
  if (parts.some((p) => p!.html)) dt.setData("text/html", htmls.join("\n"));
  if (items.length === 1 && items[0].kind === "link") dt.setData("text/uri-list", text.trim());
}

/** `dragend` 时调用：确实放到了别处时，标记为刚刚使用。 */
export function endDrag(e: React.DragEvent, items: ClipItem[]) {
  if (e.dataTransfer.dropEffect !== "none") void api.clipTouch(items.map((i) => i.id)).catch(() => {});
}
