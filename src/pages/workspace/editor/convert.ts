// 工作空间文档与外部系统之间的格式转换：
// - Jira / Wiki 渲染出的 HTML → Markdown（沉淀、剪藏到知识库）
// - Markdown → Confluence 存储格式（发布到 Wiki）
import TurndownService from "turndown";
import { gfm } from "turndown-plugin-gfm";
import { marked } from "marked";
import DOMPurify from "dompurify";

/** 正文中引用的本地图片：`ws://asset/<id>` */
export const ASSET_PREFIX = "ws://asset/";
/** 正文中链接到其他文档：`ws://doc/<id>` */
export const DOC_PREFIX = "ws://doc/";

/**
 * HTML → Markdown。相对地址补全为 `baseUrl` 下的完整地址，图片在编辑器中经代理显示。
 * Jira 缩略图换成外层链接指向的原图。
 */
export function htmlToMarkdown(html: string, baseUrl: string): string {
  const fragment = DOMPurify.sanitize(html, { RETURN_DOM_FRAGMENT: true, ADD_ATTR: ["file-preview-title"] });
  const absolute = (url: string) => (url.startsWith("/") && !url.startsWith("//") ? `${baseUrl}${url}` : url);
  fragment.querySelectorAll("img").forEach((img) => {
    const anchor = img.closest("a");
    const href = anchor?.getAttribute("href") ?? "";
    const original = img.getAttribute("data-image-src") ?? (/\.(png|jpe?g|gif|bmp|webp)(\?|$)/i.test(href) ? href : null);
    img.setAttribute("src", absolute(original ?? img.getAttribute("src") ?? ""));
    // 去掉外层的预览链接，避免生成“图片套链接”
    if (anchor && anchor.childElementCount === 1) anchor.replaceWith(img);
  });
  fragment.querySelectorAll("a[href]").forEach((a) => a.setAttribute("href", absolute(a.getAttribute("href")!)));
  // 标题锚点、表情图标等无意义的内容
  fragment.querySelectorAll("a[name]:not([href]), .aui-icon, script, style").forEach((el) => el.remove());

  const service = new TurndownService({ headingStyle: "atx", codeBlockStyle: "fenced", bulletListMarker: "-", emDelimiter: "*" });
  service.use(gfm);
  // Jira 的代码块：<div class="code panel"><pre class="code-java">
  service.addRule("jiraCode", {
    filter: (node) => node.nodeName === "PRE",
    replacement: (_content, node) => {
      const el = node as HTMLElement;
      const lang = [...el.classList].find((c) => c.startsWith("code-"))?.slice(5) ?? el.querySelector("code")?.className.replace("language-", "") ?? "";
      return `\n\n\`\`\`${lang}\n${(el.textContent ?? "").replace(/\n$/, "")}\n\`\`\`\n\n`;
    },
  });
  const container = document.createElement("div");
  container.appendChild(fragment);
  return service.turndown(container).trim();
}

const escapeXml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

const ALLOWED = new Set(["p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "strong", "em", "b", "i", "u", "s", "del", "code", "blockquote", "table", "thead", "tbody", "tr", "th", "td", "a", "br", "hr", "sup", "sub"]);

/**
 * Markdown → Confluence 存储格式（XHTML）。
 * 本地图片写成附件引用（文件名占位 `ws-asset:<id>`，上传时替换为真实文件名），返回引用到的图片 id。
 */
export function markdownToStorage(markdown: string): { storage: string; assets: string[] } {
  const html = marked.parse(markdown, { gfm: true, async: false }) as string;
  const doc = new DOMParser().parseFromString(`<body>${html}</body>`, "text/html");
  const assets: string[] = [];

  const walk = (node: Node): string => {
    if (node.nodeType === Node.TEXT_NODE) return escapeXml(node.textContent ?? "");
    if (!(node instanceof HTMLElement)) return "";
    const tag = node.tagName.toLowerCase();
    const children = () => Array.from(node.childNodes).map(walk).join("");
    switch (tag) {
      case "pre": {
        const code = node.querySelector("code");
        const lang = code?.className.match(/language-(\S+)/)?.[1];
        const text = (code ?? node).textContent ?? "";
        return (
          `<ac:structured-macro ac:name="code">${lang ? `<ac:parameter ac:name="language">${escapeXml(lang)}</ac:parameter>` : ""}` +
          `<ac:plain-text-body><![CDATA[${text.replace(/]]>/g, "]]]]><![CDATA[>")}]]></ac:plain-text-body></ac:structured-macro>`
        );
      }
      case "img": {
        const src = node.getAttribute("src") ?? "";
        if (src.startsWith(ASSET_PREFIX)) {
          const id = src.slice(ASSET_PREFIX.length);
          assets.push(id);
          return `<ac:image><ri:attachment ri:filename="ws-asset:${escapeXml(id)}" /></ac:image>`;
        }
        return `<ac:image><ri:url ri:value="${escapeXml(src)}" /></ac:image>`;
      }
      case "input":
        // 任务列表的复选框
        return (node as HTMLInputElement).checked ? "☑ " : "☐ ";
      case "a": {
        const href = node.getAttribute("href") ?? "";
        // 工作空间内部链接在 Wiki 上无法打开，只保留文字
        if (!href || href.startsWith("ws://")) return children();
        return `<a href="${escapeXml(href)}">${children()}</a>`;
      }
      case "br":
        return "<br />";
      case "hr":
        return "<hr />";
      default:
        return ALLOWED.has(tag) ? `<${tag}>${children()}</${tag}>` : children();
    }
  };
  const storage = Array.from(doc.body.childNodes).map(walk).join("");
  return { storage, assets: [...new Set(assets)] };
}
