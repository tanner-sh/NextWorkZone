// 把系统地址（Jira 问题、Wiki 页面、GitLab 项目）转成应用内的跳转目标，避免打开浏览器。
import { openUrl } from "@tauri-apps/plugin-opener";
import { api, type Service } from "../api";
import type { NavTarget } from "../state/nav";

type BaseUrl = (service: Service) => string;

/** 地址属于哪个已配置的系统，返回该系统和站内路径（含查询参数与锚点）。 */
function systemOf(url: string, baseUrl: BaseUrl): { service: Service; path: string } | null {
  for (const service of ["jira", "confluence", "gitlab"] as const) {
    const base = baseUrl(service);
    if (base && (url === base || url.startsWith(`${base}/`) || url.startsWith(`${base}?`))) return { service, path: url.slice(base.length) || "/" };
  }
  return null;
}

/** GitLab 地址中不是项目的路径开头。 */
const GITLAB_RESERVED = new Set(["users", "dashboard", "explore", "help", "admin", "profile", "search", "-", "api", "assets", "uploads"]);

/** 旧式（不带 /-/）的项目内页面路径。 */
const GITLAB_PROJECT_PAGES = new Set(["tree", "blob", "commits", "commit", "merge_requests", "issues", "branches", "tags", "compare", "raw", "blame", "pipelines", "jobs", "wikis"]);

/**
 * 能直接判断的应用内目标：Jira 问题、带 pageId 的 Wiki 页面、GitLab 项目、合并请求、分支和提交。
 * 其他 Wiki 地址（短链接、/display/…）需要向服务器解析，返回 `"wiki"` 表示交给 `resolveLink`。
 */
export function routeUrl(url: string, baseUrl: BaseUrl): NavTarget | "wiki" | null {
  const sys = systemOf(url.trim(), baseUrl);
  if (!sys) return null;
  const hash = sys.path.includes("#") ? decodeURIComponent(sys.path.split("#")[1]) : undefined;
  if (sys.service === "jira") {
    const key = sys.path.match(/^\/browse\/([A-Z][A-Z0-9_]+-\d+)/)?.[1] ?? new URLSearchParams(sys.path.split("?")[1]?.split("#")[0] ?? "").get("selectedIssue");
    return key ? { page: "jira", issueKey: key } : null;
  }
  if (sys.service === "confluence") {
    // 附件下载等不是页面的地址不处理
    if (/^\/(download|rest|plugins|images|s)\//.test(sys.path)) return null;
    const id = sys.path.match(/[?&]pageId=(\d+)/)?.[1] ?? sys.path.match(/^\/pages\/(\d+)(\/|$)/)?.[1];
    if (id) return { page: "wiki", wikiPage: id, anchor: hash };
    if (/^\/(x|display|spaces|pages)\//.test(sys.path)) return "wiki";
    return null;
  }
  const segments = sys.path.split(/[?#]/)[0].split("/").filter(Boolean);
  if (segments.length < 2 || GITLAB_RESERVED.has(segments[0])) return null;
  // 项目可以在多级群组下；项目内页面以 /-/ 分隔，旧式地址直接跟 tree、blob 等
  const dash = segments.indexOf("-");
  const legacy = segments.findIndex((s, i) => i >= 2 && GITLAB_PROJECT_PAGES.has(s));
  const end = dash > 0 ? dash : legacy;
  const projectPath = (end > 0 ? segments.slice(0, end) : segments).join("/");
  const page = dash > 0 ? end + 1 : end;
  const kind = end > 0 ? segments[page] : undefined;
  const args = end > 0 ? segments.slice(page + 1).map(decodeSegment) : [];
  const mr = kind === "merge_requests" ? Number(args[0]) : NaN;
  if (Number.isInteger(mr) && mr > 0) return { page: "gitlab", projectPath, mrIid: mr };
  if (kind === "commit" && /^[0-9a-f]{7,40}$/i.test(args[0] ?? "")) return { page: "gitlab", projectPath, commitSha: args[0].toLowerCase() };
  // 分支名可以含 /，带着目录时由项目页按已有分支确定
  if ((kind === "tree" || kind === "commits" || kind === "blob") && args.length > 0) return { page: "gitlab", projectPath, gitRef: args.join("/") };
  return { page: "gitlab", projectPath };
}

function decodeSegment(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}

/** 解析地址为应用内目标（Wiki 的短链接等需要请求服务器）；不是系统地址时返回 `null`。 */
export async function resolveLink(url: string, baseUrl: BaseUrl): Promise<NavTarget | null> {
  const route = routeUrl(url, baseUrl);
  if (route !== "wiki") return route;
  const id = await api.wikiResolve(url).catch(() => null);
  return id ? { page: "wiki", wikiPage: id, anchor: url.includes("#") ? decodeURIComponent(url.split("#")[1]) : undefined } : null;
}

/** 点击链接：系统内的地址在应用内打开，其他地址用浏览器打开。 */
export async function openLink(url: string, baseUrl: BaseUrl, navigate: (target: NavTarget) => void) {
  const target = await resolveLink(url, baseUrl);
  if (target) navigate(target);
  else void openUrl(url);
}
