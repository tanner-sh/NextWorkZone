// Jira 渲染出的 HTML 在放进可视化编辑器前的预处理。

/**
 * 给附件图片标上文件名（`data-filename`）和是否缩略图（`data-thumb`），转换回 wiki 时据此写出 `!文件名!`。
 * 渲染结果中附件图片形如：
 * `<span class="image-wrap"><a file-preview-title="x.png" …><img src="…/secure/thumbnail/…"></a></span>`
 * 或 `<span class="image-wrap"><img src="…/secure/attachment/123/123_x.png"></span>`。
 */
export function markAttachmentImages(root: ParentNode) {
  root.querySelectorAll("img").forEach((img) => {
    if (img.dataset.filename) return;
    const src = img.getAttribute("src") ?? "";
    const anchor = img.closest("a");
    const fromLink = anchor?.getAttribute("file-preview-title") ?? (anchor?.getAttribute("href")?.includes("/secure/attachment/") ? anchor.getAttribute("title") : null);
    const fromSrc = src.match(/\/secure\/attachment\/(\d+)\/\1_([^?#]+)/)?.[2];
    const filename = fromLink ?? (fromSrc ? decodeURIComponent(fromSrc) : null);
    if (!filename) return;
    img.dataset.filename = filename;
    if (src.includes("/secure/thumbnail/")) img.dataset.thumb = "1";
  });
}

/** 可视化编辑无法完整保留的内容（宏、插件输出等）：只认识 Jira wiki 基本语法产生的结构。 */
export function unsupportedContent(root: ParentNode): string[] {
  const found = new Set<string>();
  root.querySelectorAll("div, span").forEach((el) => {
    const cls = el.classList;
    if (el.tagName === "SPAN" && (cls.length === 0 || cls.contains("image-wrap") || cls.contains("code-object") || [...cls].some((c) => c.startsWith("code-")))) return;
    if (el.tagName === "SPAN" && el.closest("pre")) return;
    if (el.tagName === "DIV" && (cls.length === 0 || cls.contains("table-wrap") || cls.contains("panel") || cls.contains("panelContent") || cls.contains("panelHeader") || cls.contains("codeContent") || cls.contains("preformattedContent"))) return;
    found.add(`${el.tagName.toLowerCase()}.${[...cls].join(".")}`);
  });
  return [...found];
}
