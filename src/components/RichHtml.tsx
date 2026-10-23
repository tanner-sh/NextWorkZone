import { useEffect, useMemo, useRef, useState, type MouseEvent, type ReactNode } from "react";
import DOMPurify from "dompurify";
import { api, errorMessage, type Attachment, type Service } from "../api";
import { assetUrl, systemPath } from "../lib/asset";
import { openLink } from "../lib/links";
import { useNav } from "../state/nav";
import { useSettings } from "../state/settings";
import { AttachmentViewer } from "./AttachmentViewer";
import { ImageViewer } from "./ImageViewer";
import { toast } from "./Toast";

const IMAGE_FILE = /\.(png|jpe?g|gif|bmp|webp|svg)(\?|#|$)/i;

/** 附件下载地址（Jira、Wiki）：在应用内预览。 */
export const ATTACHMENT_PATH = /\/(secure\/attachment|download\/attachments|download\/thumbnails)\//;

/** 按扩展名推测文件类型，用于预览只有地址的附件链接。 */
function guessMime(filename: string): string {
  const ext = filename.split(".").pop()?.toLowerCase() ?? "";
  if (["png", "jpg", "jpeg", "gif", "bmp", "webp", "svg"].includes(ext)) return `image/${ext === "jpg" ? "jpeg" : ext === "svg" ? "svg+xml" : ext}`;
  if (ext === "pdf") return "application/pdf";
  if (["mp4", "mov", "webm"].includes(ext)) return `video/${ext === "mov" ? "quicktime" : ext}`;
  return "application/octet-stream";
}

/**
 * 显示系统渲染好的 HTML（Jira 描述与评论、Wiki 页面等）：
 * 先清洗掉脚本等危险内容，再把需要认证的图片改为经 Rust 代理加载。
 * 指向 Jira 问题、Wiki 页面、GitLab 项目的链接在应用内打开，附件在应用内预览，其他链接用浏览器打开。
 * `enhance` 在内容插入后调用，用于补充交互（例如 Wiki 的 Jira 宏状态、任务勾选）。
 */
export function RichHtml({ html, service, className, enhance, onClickCapture, children }: { html: string; service: Service; className?: string; enhance?: (root: HTMLDivElement) => void | (() => void); onClickCapture?: (event: MouseEvent<HTMLDivElement>) => boolean; children?: ReactNode }) {
  const { baseUrl: baseUrlOf, sessionVersion } = useSettings();
  const { navigate } = useNav();
  const baseUrl = baseUrlOf(service);

  const clean = useMemo(() => {
    const fragment = DOMPurify.sanitize(html, { RETURN_DOM_FRAGMENT: true });
    fragment.querySelectorAll("img").forEach((img) => {
      const src = img.getAttribute("src") ?? "";
      const path = systemPath(src, baseUrl);
      if (path) img.setAttribute("src", assetUrl(service, path, sessionVersion));
      img.setAttribute("loading", "lazy");
    });
    fragment.querySelectorAll("a[href]").forEach((a) => {
      const href = a.getAttribute("href") ?? "";
      if (href.startsWith("/") && !href.startsWith("//")) a.setAttribute("href", `${baseUrl}${href}`);
    });
    const container = document.createElement("div");
    container.appendChild(fragment);
    return container.innerHTML;
  }, [html, service, baseUrl, sessionVersion]);

  // 加载失败的图片（通常是尚未网页登录）用文字占位代替破损图标
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const replace = (img: HTMLImageElement) => {
      const placeholder = document.createElement("span");
      placeholder.className = "img-placeholder";
      placeholder.textContent = "[图片]";
      img.replaceWith(placeholder);
    };
    // 图片经自定义协议异步加载，监听器总在加载结果返回之前挂上
    ref.current?.querySelectorAll("img").forEach((img) => img.addEventListener("error", () => replace(img), { once: true }));
  }, [clean]);

  useEffect(() => {
    if (ref.current && enhance) return enhance(ref.current) ?? undefined;
  }, [clean, enhance]);

  const [attachment, setAttachment] = useState<Attachment | null>(null);

  const [viewing, setViewing] = useState<{ src: string; alt: string } | null>(null);

  /** 放大查看的地址：缩略图优先用原图（外层附件链接或 Confluence 的 data-image-src）。 */
  const fullSize = (img: HTMLImageElement): string => {
    const anchor = img.closest("a");
    const original = img.dataset.imageSrc ?? (anchor?.getAttribute("href") && IMAGE_FILE.test(anchor.getAttribute("href")!) ? anchor.getAttribute("href")! : null);
    const path = original ? systemPath(original, baseUrl) : null;
    return path ? assetUrl(service, path, sessionVersion) : img.src;
  };

  const openImage = (img: HTMLImageElement) => {
    const anchor = img.closest("a");
    setViewing({ src: fullSize(img), alt: img.alt || anchor?.getAttribute("title") || "" });
  };

  const onClick = (event: MouseEvent<HTMLDivElement>) => {
    if (onClickCapture?.(event)) return;
    const target = event.target as HTMLElement;
    // Wiki 的折叠块：点击标题展开或收起
    const expander = target.closest(".expand-control");
    if (expander) {
      const content = expander.parentElement?.querySelector(":scope > .expand-content");
      content?.classList.toggle("expand-hidden");
      expander.setAttribute("aria-expanded", String(!content?.classList.contains("expand-hidden")));
      return;
    }
    // 外面包着链接的图片（Jira 缩略图）：在应用内放大，不跳转浏览器
    if (target instanceof HTMLImageElement && target.closest("a")) {
      event.preventDefault();
      openImage(target);
      return;
    }
    const anchor = target.closest("a");
    const href = anchor?.getAttribute("href");
    if (!href || href.startsWith("#")) return;
    event.preventDefault();
    if (/^mailto:/.test(href)) {
      void openLink(href, baseUrlOf, navigate);
      return;
    }
    if (!/^https?:/.test(href)) return;
    const path = systemPath(href, baseUrl);
    if (path && ATTACHMENT_PATH.test(path)) {
      const filename = decodeURIComponent(path.split("?")[0].split("/").pop() ?? "附件");
      setAttachment({ id: path, filename, size: 0, mimeType: guessMime(filename), contentUrl: path, thumbnailUrl: null, author: "", created: "" });
      return;
    }
    openLink(href, baseUrlOf, navigate).catch((e) => toast(errorMessage(e), true));
  };

  return (
    <>
      <div
        ref={ref}
        className={`rich ${className ?? ""}`}
        onClick={onClick}
        onDoubleClick={(e) => e.target instanceof HTMLImageElement && openImage(e.target)}
        dangerouslySetInnerHTML={{ __html: clean }}
      />
      {children}
      {viewing && <ImageViewer src={viewing.src} alt={viewing.alt} onClose={() => setViewing(null)} />}
      {attachment && (
        <AttachmentViewer
          service={service}
          attachments={[attachment]}
          index={0}
          onClose={() => setAttachment(null)}
          onOpenExternal={(a) => api.jiraOpenAttachment(a.contentUrl, a.filename, service).catch((e) => toast(errorMessage(e), true))}
        />
      )}
    </>
  );
}
