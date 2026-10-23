// 可视化编辑器的 HTML → Jira wiki 标记转换。
// 输入是 Jira 渲染出的 HTML（经编辑器修改后），也可能是从网页、Office 粘贴进来的 HTML。

const BLOCK_TAGS = new Set(["P", "DIV", "H1", "H2", "H3", "H4", "H5", "H6", "UL", "OL", "TABLE", "BLOCKQUOTE", "PRE", "HR"]);

/** Jira 表情图标 → wiki 写法 */
const EMOTICONS: Record<string, string> = {
  smile: ":)",
  sad: ":(",
  tongue: ":P",
  biggrin: ":D",
  wink: ";)",
  thumbs_up: "(y)",
  thumbs_down: "(n)",
  information: "(i)",
  check: "(/)",
  error: "(x)",
  warning: "(!)",
  add: "(+)",
  forbidden: "(-)",
  help_16: "(?)",
  lightbulb_on: "(on)",
  lightbulb: "(off)",
  star_yellow: "(*)",
  star_red: "(*r)",
  star_green: "(*g)",
  star_blue: "(*b)",
  flag: "(flag)",
  flag_grey: "(flagoff)",
};

// 行内格式标记先用占位符表示，最后根据前后字符决定写成 *x* 还是 {*}x{*}（等宽为 {{{}x{}}}）：
// Jira 只在标记两侧不是字母、数字（含汉字）时识别简写形式。
const OPEN = "";
const CLOSE = "";

interface Ctx {
  inTable: boolean;
}

export function htmlToWiki(root: Node): string {
  const blocks = convertBlocks(root, { inTable: false });
  return resolveMarks(blocks.join("\n\n")).replace(/\n{3,}/g, "\n\n").trim();
}

function convertBlocks(parent: Node, ctx: Ctx): string[] {
  const blocks: string[] = [];
  let inline = "";
  const flush = () => {
    const text = inline.replace(/^[ \t]*\n+/, "").replace(/\s+$/, "");
    if (text.trim()) blocks.push(escapeLineStarts(text.replace(/^ +/, "").replace(/ *\n */g, "\n")));
    inline = "";
  };
  parent.childNodes.forEach((child) => {
    if (child instanceof HTMLElement && BLOCK_TAGS.has(child.tagName)) {
      flush();
      blocks.push(...blockToWiki(child, ctx));
    } else {
      inline += inlineToWiki(child, ctx);
    }
  });
  flush();
  return blocks;
}

function blockToWiki(el: HTMLElement, ctx: Ctx): string[] {
  const tag = el.tagName;
  if (/^H[1-6]$/.test(tag)) {
    const text = inlineChildren(el, ctx).trim();
    return text ? [`h${tag[1]}. ${text}`] : [];
  }
  switch (tag) {
    case "HR":
      return ["----"];
    case "UL":
    case "OL":
      return [listToWiki(el, "", ctx)];
    case "TABLE":
      return [tableToWiki(el)];
    case "PRE":
      return [`{noformat}\n${preText(el)}\n{noformat}`];
    case "BLOCKQUOTE": {
      const inner = convertBlocks(el, ctx).join("\n\n");
      if (!inner.trim()) return [];
      return inner.includes("\n") ? [`{quote}\n${inner}\n{quote}`] : [`bq. ${inner}`];
    }
    case "DIV": {
      const cls = el.classList;
      if (cls.contains("code") && cls.contains("panel")) {
        const pre = el.querySelector("pre");
        const lang = [...(pre?.classList ?? [])].find((c) => c.startsWith("code-"))?.slice(5);
        return [`{code${lang ? `:${lang}` : ""}}\n${pre ? preText(pre) : el.textContent ?? ""}\n{code}`];
      }
      if (cls.contains("preformatted") && cls.contains("panel")) {
        const pre = el.querySelector("pre");
        return [`{noformat}\n${pre ? preText(pre) : el.textContent ?? ""}\n{noformat}`];
      }
      if (cls.contains("panel")) {
        const header = el.querySelector(":scope > .panelHeader");
        const content = el.querySelector(":scope > .panelContent") ?? el;
        const title = header?.textContent?.trim();
        const inner = convertBlocks(content, ctx).join("\n\n");
        return [`{panel${title ? `:title=${title}` : ""}}\n${inner}\n{panel}`];
      }
      return convertBlocks(el, ctx);
    }
    default:
      return convertBlocks(el, ctx);
  }
}

function preText(pre: Element): string {
  return (pre.textContent ?? "").replace(/\n$/, "");
}

function listToWiki(list: HTMLElement, prefix: string, ctx: Ctx): string {
  // class="alternate" 是用“-”写的列表（显示为短横线）
  const marker = prefix + (list.tagName === "OL" ? "#" : list.classList.contains("alternate") && !prefix ? "-" : "*");
  const lines: string[] = [];
  for (const li of Array.from(list.children)) {
    if (li.tagName === "UL" || li.tagName === "OL") {
      // 不规范的嵌套：列表直接放在列表下
      lines.push(listToWiki(li as HTMLElement, marker, ctx));
      continue;
    }
    const nested: HTMLElement[] = [];
    const holder = document.createElement("div");
    li.childNodes.forEach((child) => {
      if (child instanceof HTMLElement && (child.tagName === "UL" || child.tagName === "OL")) nested.push(child);
      else holder.appendChild(child.cloneNode(true));
    });
    // 列表项内的换行写成续行；空行会结束列表，多个段落用空格连接
    const text = convertBlocks(holder, ctx).join(" ").replace(/\n\s*\n/g, "\n");
    lines.push(`${marker} ${text}`);
    for (const sub of nested) lines.push(listToWiki(sub, marker, ctx));
  }
  return lines.join("\n");
}

function tableToWiki(table: HTMLElement): string {
  const rows = Array.from(table.querySelectorAll("tr")).filter((tr) => tr.closest("table") === table);
  return rows
    .map((tr) => {
      let line = "";
      let lastSep = "|";
      for (const cell of Array.from(tr.children)) {
        if (cell.tagName !== "TD" && cell.tagName !== "TH") continue;
        const sep = cell.tagName === "TH" ? "||" : "|";
        // 单元格内可以续行，但不能有空行（会结束表格）
        const content = convertBlocks(cell, { inTable: true }).join("\n").replace(/\n\s*\n/g, "\n").trim();
        line += `${sep}${content || " "}`;
        lastSep = sep;
      }
      return line ? line + lastSep : "";
    })
    .filter(Boolean)
    .join("\n");
}

function inlineChildren(el: Node, ctx: Ctx): string {
  let out = "";
  el.childNodes.forEach((child) => (out += inlineToWiki(child, ctx)));
  return out;
}

function inlineToWiki(node: Node, ctx: Ctx): string {
  if (node.nodeType === Node.TEXT_NODE) {
    // 只合并普通空白；不间断空格（&nbsp;）原样保留
    return escapeText((node.textContent ?? "").replace(/[ \t\r\n\f]+/g, " "), ctx);
  }
  if (!(node instanceof HTMLElement)) return "";
  const el = node;
  const tag = el.tagName;
  // 块级元素出现在行内上下文（例如列表项里的段落）时按文本处理
  if (BLOCK_TAGS.has(tag)) return " " + convertBlocks(el, ctx).join(" ") + " ";
  switch (tag) {
    case "BR":
      return "\n";
    case "B":
    case "STRONG":
      return wrap("*", inlineChildren(el, ctx));
    case "EM":
    case "I":
      return wrap("_", inlineChildren(el, ctx));
    case "INS":
    case "U":
      return wrap("+", inlineChildren(el, ctx));
    case "DEL":
    case "S":
    case "STRIKE":
      return wrap("-", inlineChildren(el, ctx));
    case "SUP":
      return wrap("^", inlineChildren(el, ctx));
    case "SUB":
      return wrap("~", inlineChildren(el, ctx));
    case "CITE":
      return wrap("??", inlineChildren(el, ctx));
    case "TT":
    case "CODE":
      return wrap("{{", (el.textContent ?? "").replace(/[{}]/g, (c) => `\\${c}`));
    case "FONT":
      return colored(el.getAttribute("color"), inlineChildren(el, ctx));
    case "IMG":
      return imageToWiki(el as HTMLImageElement);
    case "A":
      return linkToWiki(el as HTMLAnchorElement, ctx);
    case "SCRIPT":
    case "STYLE":
      return "";
    default:
      return styled(el, inlineChildren(el, ctx));
  }
}

/** 粘贴进来的内容常用 style 表达格式（如 <span style="font-weight:bold">）。 */
function styled(el: HTMLElement, inner: string): string {
  const style = el.style;
  let out = inner;
  if (style.color) out = colored(style.color, out);
  if (style.fontWeight === "bold" || Number(style.fontWeight) >= 600) out = wrap("*", out);
  if (style.fontStyle === "italic") out = wrap("_", out);
  if (style.textDecorationLine?.includes("underline") || style.textDecoration?.includes("underline")) out = wrap("+", out);
  if (style.textDecorationLine?.includes("line-through") || style.textDecoration?.includes("line-through")) out = wrap("-", out);
  return out;
}

function colored(color: string | null, inner: string): string {
  const hex = color ? toHex(color) : null;
  if (!hex || !inner.trim() || hex === "#000000" || hex === "#333333") return inner;
  return `{color:${hex}}${inner}{color}`;
}

/** Jira 只接受 #rrggbb 或颜色名，rgb() 需要转换。 */
function toHex(color: string): string | null {
  const c = color.trim().toLowerCase();
  if (/^#[0-9a-f]{6}$/.test(c)) return c;
  if (/^#[0-9a-f]{3}$/.test(c)) return `#${[...c.slice(1)].map((d) => d + d).join("")}`;
  const rgb = c.match(/^rgba?\((\d+),\s*(\d+),\s*(\d+)/);
  if (rgb) return `#${rgb.slice(1, 4).map((n) => Number(n).toString(16).padStart(2, "0")).join("")}`;
  if (/^[a-z]+$/.test(c)) return c;
  return null;
}

function linkToWiki(a: HTMLAnchorElement, ctx: Ctx): string {
  // @提及
  if (a.classList.contains("user-hover") && a.getAttribute("rel")) return `[~${a.getAttribute("rel")}]`;
  if (a.dataset.username) return `[~${a.dataset.username}]`;
  // 拖进编辑器、待上传的附件
  if (a.dataset.attachment) return `[^${a.dataset.attachment}]`;
  // 问题键会被 Jira 自动链接
  if (a.classList.contains("issue-link") && a.dataset.issueKey && (a.textContent ?? "").trim() === a.dataset.issueKey) return a.dataset.issueKey;
  // 附件图片外面包着的预览链接
  if (a.querySelector("img")) return inlineChildren(a, ctx);
  const href = a.getAttribute("href");
  const text = inlineChildren(a, ctx).trim();
  if (!href || href.startsWith("#")) return text;
  // 自动识别的网址：链接文字就是地址本身
  const raw = (a.textContent ?? "").trim();
  if (!raw || raw === href || safeDecode(raw) === safeDecode(href)) return `[${href}]`;
  return `[${text.replace(/[|\]]/g, (c) => `\\${c}`)}|${href}]`;
}

function safeDecode(url: string): string {
  try {
    return decodeURI(url);
  } catch {
    return url;
  }
}

function imageToWiki(img: HTMLImageElement): string {
  const filename = img.dataset.filename;
  const src = img.getAttribute("src") ?? "";
  // 缩略图，或 !图片|width=…,height=…! 指定的尺寸
  const params = img.dataset.thumb
    ? ["thumbnail"]
    : (["width", "height"] as const).flatMap((k) => (img.getAttribute(k) ? [`${k}=${img.getAttribute(k)}`] : []));
  const suffix = params.length ? `|${params.join(",")}` : "";
  if (filename) return `!${filename}${suffix}!`;
  const emoticon = src.match(/\/images\/icons\/emoticons\/([a-z_0-9]+)\.(png|gif)/);
  if (emoticon && EMOTICONS[emoticon[1]]) return EMOTICONS[emoticon[1]];
  if (/^https?:\/\//.test(src)) return `!${src}${suffix}!`;
  return "";
}

function wrap(mark: string, inner: string): string {
  if (!inner.trim()) return inner;
  const lead = inner.match(/^\s*/)![0];
  const trail = inner.match(/\s*$/)![0];
  const core = inner.slice(lead.length, inner.length - trail.length);
  return `${lead}${OPEN}${mark}${OPEN}${core}${CLOSE}${mark}${CLOSE}${trail}`;
}

const WORD = /[\p{L}\p{N}]/u;

/** 起止符号不同的标记：{{等宽}} */
const CLOSING: Record<string, string> = { "{{": "}}" };

/** 把占位的格式标记落实为 *x*，或在紧挨文字时写成 {*}x{*}。 */
function resolveMarks(text: string): string {
  const pattern = new RegExp(`${OPEN}([^${OPEN}]+?)${OPEN}`, "g");
  // 先找出每对标记，判断两侧字符
  let out = text;
  for (;;) {
    const open = pattern.exec(out);
    if (!open) break;
    const mark = open[1];
    const closeToken = `${CLOSE}${mark}${CLOSE}`;
    const closeAt = findClose(out, open.index + open[0].length, mark);
    if (closeAt < 0) {
      out = out.slice(0, open.index) + out.slice(open.index + open[0].length);
      pattern.lastIndex = 0;
      continue;
    }
    const before = visibleBefore(out, open.index);
    const after = visibleAfter(out, closeAt + closeToken.length);
    const braces = (before !== "" && WORD.test(before)) || (after !== "" && WORD.test(after));
    const closing = CLOSING[mark] ?? mark;
    const left = braces ? `{${mark}}` : mark;
    const right = braces ? `{${closing}}` : closing;
    out = out.slice(0, open.index) + left + out.slice(open.index + open[0].length, closeAt) + right + out.slice(closeAt + closeToken.length);
    pattern.lastIndex = 0;
  }
  return out.replace(new RegExp(`[${OPEN}${CLOSE}]`, "g"), "");
}

function findClose(text: string, from: number, mark: string): number {
  const openToken = `${OPEN}${mark}${OPEN}`;
  const closeToken = `${CLOSE}${mark}${CLOSE}`;
  let depth = 0;
  for (let i = from; i < text.length; i++) {
    if (text.startsWith(openToken, i)) depth++;
    else if (text.startsWith(closeToken, i)) {
      if (depth === 0) return i;
      depth--;
    }
  }
  return -1;
}

/** 前一个实际可见的字符（跳过其他占位标记）。 */
function visibleBefore(text: string, index: number): string {
  const head = text.slice(0, index).replace(new RegExp(`${OPEN}[^${OPEN}]+${OPEN}|${CLOSE}[^${CLOSE}]+${CLOSE}`, "g"), "");
  return head.slice(-1);
}

function visibleAfter(text: string, index: number): string {
  const tail = text.slice(index).replace(new RegExp(`${OPEN}[^${OPEN}]+${OPEN}|${CLOSE}[^${CLOSE}]+${CLOSE}`, "g"), "");
  return tail.slice(0, 1);
}

/**
 * 转义会被 Jira 当作标记的字符。格式符号只在可能构成格式时转义（例如日期 2026-07-17 中的“-”不转义），
 * 避免文本模式下满屏反斜杠。
 */
function escapeText(text: string, ctx: Ctx): string {
  let out = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    const prevSpace = i === 0 || /\s/.test(text[i - 1]);
    const nextSpace = i === text.length - 1 || /\s/.test(text[i + 1]);
    if ("\\{}[]".includes(c) || (c === "|" && ctx.inTable) || (c === "!" && !nextSpace)) {
      out += `\\${c}`;
    } else if ("*_+-^~?".includes(c) && prevSpace !== nextSpace) {
      // 一侧是空白、另一侧是文字：可能成为格式的起止标记
      out += `\\${c}`;
    } else {
      out += c;
    }
  }
  return out;
}

/** 段落中以列表、标题、引用、分隔线写法开头的行需要转义，否则会被当作对应的块。 */
function escapeLineStarts(text: string): string {
  return text
    .split("\n")
    .map((line) => (/^(\*+|#+|-+)\s|^(h[1-6]|bq)\.\s|^-{4}/.test(line) ? `\\${line}` : line))
    .join("\n");
}
