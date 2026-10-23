export const JQL_PRESETS = [
  { id: "mine", label: "未解决", jql: "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC" },
  { id: "reported", label: "我报告的", jql: "reporter = currentUser() AND resolution = Unresolved ORDER BY updated DESC" },
  { id: "recent", label: "近两周", jql: "assignee was currentUser() AND updated >= -14d ORDER BY updated DESC" },
] as const;

export const MY_UNRESOLVED_JQL = JQL_PRESETS[0].jql;

/** 问题键的前缀就是项目键，例如 ABC-123 → ABC。 */
export function projectKeyOf(issueKey: string): string {
  return issueKey.replace(/-\d+$/, "");
}

/** JQL 字符串中的文字需要转义引号和反斜杠。 */
export function jqlString(text: string): string {
  return `"${text.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

export const SORTS = [
  { id: "default", label: "默认", order: null },
  { id: "updated", label: "最近更新", order: "updated DESC" },
  { id: "created", label: "最近创建", order: "created DESC" },
  { id: "priority", label: "优先级", order: "priority DESC, updated DESC" },
  { id: "key", label: "问题键", order: "key DESC" },
] as const;

/** 预设排序，或按某个字段排序：`field:<字段 id>:asc|desc`。 */
export type SortId = (typeof SORTS)[number]["id"] | `field:${string}`;

/** 字段在 JQL 中的写法：自定义字段用 cf[编号]。 */
function jqlField(id: string): string {
  const custom = /^customfield_(\d+)$/.exec(id);
  if (custom) return `cf[${custom[1]}]`;
  return id === "components" ? "component" : id;
}

export function fieldSort(id: string, dir: "asc" | "desc"): SortId {
  return `field:${id}:${dir}`;
}

/** 替换 JQL 的排序；“默认”保持原样（关键词搜索时为按相关度）。 */
export function withOrder(jql: string, sort: SortId): string {
  const byField = /^field:(.+):(asc|desc)$/.exec(sort);
  const order = byField ? `${jqlField(byField[1])} ${byField[2].toUpperCase()}, updated DESC` : SORTS.find((s) => s.id === sort)?.order;
  if (!order) return jql;
  return `${jql.replace(/\s+ORDER\s+BY\s+[\s\S]*$/i, "").trim()} ORDER BY ${order}`;
}

export interface SearchForm {
  text: string;
  /** all / unresolved / resolved */
  state: "all" | "unresolved" | "resolved";
  /** 经办人范围：任何人 / 我经办过 */
  who: "anyone" | "me";
  /** 项目键，空为全部 */
  project: string;
}

export const EMPTY_SEARCH: SearchForm = { text: "", state: "all", who: "anyone", project: "" };

/** 按表单拼出 JQL；有关键词时不指定排序（Jira 按相关度排序）。条件为空时返回 null。 */
export function searchJql(form: SearchForm): string | null {
  const clauses: string[] = [];
  const text = form.text.trim();
  if (text) {
    // 输入的是问题键时直接查这个问题
    clauses.push(/^[A-Za-z][A-Za-z0-9_]*-\d+$/.test(text) ? `key = ${jqlString(text.toUpperCase())}` : `text ~ ${jqlString(text)}`);
  }
  if (form.project) clauses.push(`project = ${jqlString(form.project)}`);
  if (form.state === "unresolved") clauses.push("resolution = Unresolved");
  if (form.state === "resolved") clauses.push("resolution is not EMPTY");
  if (form.who === "me") clauses.push("assignee was currentUser()");
  if (clauses.length === 0) return null;
  return text ? clauses.join(" AND ") : `${clauses.join(" AND ")} ORDER BY updated DESC`;
}

// ---------- 本机保存的常用查询 ----------

export interface SavedQuery {
  name: string;
  jql: string;
}

const SAVED_KEY = "nextworkzone.jira.savedQueries";

export function loadSavedQueries(): SavedQuery[] {
  try {
    return JSON.parse(localStorage.getItem(SAVED_KEY) ?? "[]") as SavedQuery[];
  } catch {
    return [];
  }
}

export function storeSavedQueries(list: SavedQuery[]) {
  try {
    localStorage.setItem(SAVED_KEY, JSON.stringify(list));
  } catch {
    // 不保存
  }
}
