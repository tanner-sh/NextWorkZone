// GitLab 的 Markdown（MR 描述、评论）→ HTML，交给 RichHtml 清洗和显示。
import { marked } from "marked";

/** 常见的表情短码；其余短码原样显示。 */
const EMOJI: Record<string, string> = {
  "+1": "👍", "-1": "👎", thumbsup: "👍", thumbsdown: "👎", smile: "😄", laughing: "😆", joy: "😂", tada: "🎉", rocket: "🚀",
  heart: "❤️", fire: "🔥", eyes: "👀", thinking: "🤔", pray: "🙏", clap: "👏", ok_hand: "👌", muscle: "💪", star: "⭐",
  white_check_mark: "✅", heavy_check_mark: "✔️", ballot_box_with_check: "☑️", x: "❌", negative_squared_cross_mark: "❎",
  warning: "⚠️", exclamation: "❗", question: "❓", no_entry: "⛔", no_entry_sign: "🚫", stop_sign: "🛑",
  bug: "🐛", mag: "🔍", mag_right: "🔎", memo: "📝", pencil: "📝", pencil2: "✏️", bulb: "💡", wrench: "🔧", hammer: "🔨",
  construction: "🚧", lock: "🔒", unlock: "🔓", key: "🔑", sparkles: "✨", zap: "⚡", boom: "💥", art: "🎨", recycle: "♻️",
  package: "📦", link: "🔗", books: "📚", book: "📖", clipboard: "📋", chart_with_upwards_trend: "📈", hourglass: "⌛",
  red_circle: "🔴", large_orange_diamond: "🔶", large_blue_circle: "🔵", green_heart: "💚", information_source: "ℹ️",
  arrow_right: "➡️", point_right: "👉", see_no_evil: "🙈", rotating_light: "🚨", wastebasket: "🗑️", truck: "🚚",
};

/**
 * `projectUrl` 是项目网页地址，用于补全项目内的相对地址（`/uploads/…` 指项目下的上传文件）。
 * 代码块中的内容不做表情替换。
 */
export function gitlabMarkdown(body: string, projectUrl: string): string {
  const parts = body.split(/(```[\s\S]*?```|`[^`\n]*`)/);
  const text = parts
    .map((part, i) => (i % 2 === 1 ? part : part.replace(/:([a-z0-9_+-]+):/g, (m, name: string) => EMOJI[name] ?? m).replace(/\]\(\/uploads\//g, `](${projectUrl}/uploads/`)))
    .join("");
  return marked.parse(text, { async: false, gfm: true, breaks: true }) as string;
}

/** 正文中的 Jira 问题号（形如 ABC-123），按出现顺序去重。 */
export function issueKeysIn(text: string): string[] {
  return [...new Set(text.match(/\b[A-Z][A-Z0-9_]+-\d+\b/g) ?? [])];
}
