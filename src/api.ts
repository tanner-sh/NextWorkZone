// Rust command 的类型化封装。前端只通过这里与 Rust 层交互。
import { invoke as tauriInvoke, type InvokeArgs } from "@tauri-apps/api/core";

/** 窗口相关的命令由 Tauri 端直接处理，其余命令都经过应用层的统一入口 `core`。 */
const PLATFORM_COMMANDS = new Set(["web_login", "capture_hide", "capture_clipboard", "clipboard_read_text", "clip_hide", "clip_open_main", "clip_drag", "dev_eval_result"]);

function invoke<T>(cmd: string, args?: InvokeArgs): Promise<T> {
  return PLATFORM_COMMANDS.has(cmd) ? tauriInvoke<T>(cmd, args) : tauriInvoke<T>("core", { cmd, args: args ?? {} });
}

export type Service = "jira" | "confluence" | "gitlab";

// ---------- 设置 ----------

export interface ServiceSettings {
  service: Service;
  label: string;
  baseUrl: string;
  hasToken: boolean;
  supportsWebLogin: boolean;
  webUsername: string;
  hasWebPassword: boolean;
}

export interface Settings {
  proxy: string;
  services: ServiceSettings[];
  weeklyPageId: string;
  weeklyPersonName: string;
}

export interface SettingsInput {
  proxy: string;
  baseUrls: Partial<Record<Service, string>>;
  tokens: Partial<Record<Service, string>>;
  weeklyPage: string;
  weeklyPersonName: string;
  /** 只包含支持网页登录的系统；密码为空表示不修改。 */
  webAccounts: Partial<Record<Service, { username: string; password: string }>>;
}

/** 访问附件、图片等网页路径的方式：Token 即可 / 已网页登录 / 需要网页登录。 */
export type WebAccess = "token" | "session" | "loginRequired";

export interface ConnectionInfo {
  service: Service;
  username: string;
  displayName: string;
  serverVersion: string | null;
}

// ---------- Jira ----------

export interface JiraStatus {
  name: string;
  /** new / indeterminate / done */
  category: string;
}

export interface Named {
  name: string;
  iconUrl: string | null;
}

export interface IssueSummary {
  key: string;
  summary: string;
  status: JiraStatus;
  issueType: Named;
  priority: Named | null;
  project: Named;
  assignee: string | null;
  /** 经办人的用户名 */
  assigneeName: string | null;
  reporter: string | null;
  /** 报告人的用户名 */
  reporterName: string | null;
  /** 当前用户在 Jira 网页上最近一次查看的时间 */
  lastViewed: string | null;
  resolution: string | null;
  created: string;
  updated: string;
  dueDate: string | null;
  /** 额外显示的字段：字段 id → 文本 */
  extra?: Record<string, string>;
}

export interface FieldInfo {
  id: string;
  name: string;
  custom: boolean;
  /** date / datetime / array / user / string / number … */
  kind: string;
}

export interface SearchResult {
  total: number;
  issues: IssueSummary[];
}

export interface DisplayField {
  id: string;
  name: string;
  text: string;
  html: string | null;
  /** 值是另一个问题（例如 Epic 链接）时为该问题的键 */
  issueKey?: string;
  /** 不在问题界面上（网页中不显示，多为隐藏字段的默认值） */
  hidden: boolean;
}

export interface IssueRef {
  key: string;
  summary: string;
  status: JiraStatus | null;
  issueType: Named | null;
}

export interface IssueLink extends IssueRef {
  id: string;
  /** 从当前问题看过去的关系描述 */
  relation: string;
}

export interface TimeTracking {
  originalEstimate: string | null;
  remainingEstimate: string | null;
  timeSpent: string | null;
  originalEstimateSeconds: number | null;
  remainingEstimateSeconds: number | null;
  timeSpentSeconds: number | null;
}

export interface Attachment {
  id: string;
  filename: string;
  size: number;
  mimeType: string;
  contentUrl: string;
  thumbnailUrl: string | null;
  author: string;
  created: string;
}

export interface Comment {
  id: string;
  author: string;
  authorName: string;
  /** 自己写的评论可以修改、删除 */
  mine: boolean;
  created: string;
  updated: string;
  /** wiki 标记原文 */
  body: string;
  bodyHtml: string;
  /** 仅部分用户可见时的范围；null 为所有用户可见 */
  visibility: CommentVisibility | null;
}

/** 评论的可见范围（项目角色或用户组） */
export interface CommentVisibility {
  type: "role" | "group";
  value: string;
}

export interface CommentLevel {
  visibility: CommentVisibility;
  label: string;
}

export interface Watchers {
  watching: boolean;
  count: number;
}

export interface SimilarIssues {
  /** 对应的查询，用于在列表中查看全部；概要中没有可用的关键词时为空 */
  jql: string | null;
  /** local：本机问题库；jira：本机没有该项目的数据，直接查询 Jira */
  source: "local" | "jira";
  issues: IssueHit[];
}

export interface BriefComment {
  author: string;
  authorName: string;
  created: string;
  /** 纯文本 */
  body: string;
}

/** 本机问题库的搜索结果、相似问题。 */
export interface IssueHit extends IssueSummary {
  /** 解决时间 */
  resolved: string | null;
  commentCount: number;
  /** 描述或评论中匹配处附近的文字 */
  snippet: { source: "description" | "comment"; author: string | null; text: string } | null;
  /** 最后几条评论（相似问题） */
  lastComments: BriefComment[];
}

export interface IndexQuery {
  text: string;
  project: string;
  state: "all" | "unresolved" | "resolved";
  /** 只看我参与过的（经办、报告或评论过） */
  mine: boolean;
  limit?: number;
}

export interface IndexStatus {
  enabled: boolean;
  count: number;
  projects: { key: string; name: string; count: number }[];
  lastSync: string | null;
  running: boolean;
  progress: { scope: string; done: number; total: number; finished: number; scopes: number } | null;
  error: string | null;
}

/** Jira 本机增强功能的设置。 */
export interface JiraToolsSettings {
  indexEnabled: boolean;
  /** 为空时自动选择“我经办过或报告过问题的项目” */
  indexJql: string;
  /** 只同步最近多少天内创建的问题；0 表示不限 */
  indexDays: number;
  /** 为空时自动识别 */
  dueField: string;
  dueSoonDays: number;
  /** 0 表示不提醒 */
  staleDays: number;
  remind: boolean;
}

export type ReminderKind = "overdue" | "today" | "soon" | "stale";

export interface Reminder extends IssueSummary {
  kind: ReminderKind;
  due: string | null;
  /** 到期：距今天数（逾期为负）；停滞：多少天没有更新 */
  days: number;
}

export interface Reminders {
  dueField: { id: string; name: string } | null;
  items: Reminder[];
  /** 问题键 → 到期日期 */
  dueDates: Record<string, string>;
  remind: boolean;
}

/** Jira：comment … created；Wiki 另有 edit（关注的页面被修改）、share、task、like、other */
export type ActivityKind = "comment" | "mention" | "status" | "assigned" | "field" | "created" | "edit" | "share" | "task" | "like" | "other";

export interface ActivityEvent {
  id: string;
  issueKey: string;
  issueSummary: string;
  issueTypeIcon: string | null;
  kind: ActivityKind;
  actor: string;
  at: string;
  text: string;
  read: boolean;
  /** Wiki 动态的 issueKey 是页面 id、issueSummary 是页面标题 */
  system: "jira" | "wiki";
}

export interface ActivityFeed {
  events: ActivityEvent[];
  unread: number;
  lastCheck: string | null;
}

export type AttachmentPreview =
  | { kind: "text"; text: string; truncated: boolean; encoding: string }
  | { kind: "sheet"; sheets: { name: string; rows: string[][]; totalRows: number; totalCols: number }[] }
  | { kind: "document"; paragraphs: string[]; truncated: boolean }
  | { kind: "archive"; entries: { name: string; size: number; dir: boolean }[]; truncated: boolean }
  | { kind: "unsupported"; reason: string };

export interface JiraFilter {
  id: string;
  name: string;
  jql: string;
}

export interface Priority {
  id: string;
  name: string;
  iconUrl: string | null;
}

export interface IssueDetail extends IssueSummary {
  /** 问题的数字 id */
  id: string;
  descriptionHtml: string | null;
  fields: DisplayField[];
  timeTracking: TimeTracking | null;
  parent: IssueRef | null;
  subtasks: IssueRef[];
  links: IssueLink[];
  attachments: Attachment[];
  comments: Comment[];
}

export type FieldKind =
  | "text"
  | "textarea"
  | "number"
  | "date"
  | "datetime"
  | "select"
  | "multiselect"
  | "cascading"
  | "user"
  | "multiuser"
  | "labels"
  | "timetracking"
  | "epic"
  | "parent"
  | "unsupported";

export interface FieldOption {
  id: string;
  name: string;
  children?: FieldOption[];
  disabled: boolean;
}

export interface UserRef {
  name: string;
  displayName: string;
}

export interface IssueChoice {
  key: string;
  summary: string;
}

export interface TimeTrackingValue {
  originalEstimate?: string;
  remainingEstimate?: string;
}

/** 表单中字段的取值，形式随字段类型而定（见 Rust `meta` 模块说明）。 */
export type FieldValue = string | string[] | UserRef | UserRef[] | TimeTrackingValue | IssueChoice | null;

export interface FieldMeta {
  key: string;
  name: string;
  required: boolean;
  kind: FieldKind;
  options: FieldOption[];
  /** 编辑时为当前值，创建时为默认值 */
  value: FieldValue;
}

export interface Transition {
  id: string;
  name: string;
  to: JiraStatus;
  fields: FieldMeta[];
}

export interface CreateIssueType {
  id: string;
  name: string;
  iconUrl: string | null;
  subtask: boolean;
}

export interface CreateProject {
  id: string;
  key: string;
  name: string;
  issueTypes: CreateIssueType[];
}

export interface LinkType {
  id: string;
  name: string;
  inward: string;
  outward: string;
}

export interface Worklog {
  id: string;
  author: string;
  mine: boolean;
  started: string;
  timeSpent: string;
  timeSpentSeconds: number;
  comment: string;
}

export interface WorklogInput {
  /** 2026-10-22T09:00:00.000+0800 */
  started: string;
  /** 例如“3h 30m” */
  timeSpent: string;
  comment: string;
}

export interface HistoryItem {
  /** 字段 id，例如 status */
  fieldId: string;
  field: string;
  from: string | null;
  to: string | null;
}

export interface HistoryEntry {
  id: string;
  author: string;
  authorName: string;
  created: string;
  items: HistoryItem[];
}

// ---------- 周报 ----------

export interface OutlineItem {
  level: number;
  text: string;
}

export interface SectionInfo {
  title: string;
  coversToday: boolean;
}

export interface WeekEntry {
  sectionTitle: string;
  rowFound: boolean;
  content: OutlineItem[];
  risk: OutlineItem[];
  contentRaw: string;
  riskRaw: string;
  lossy: boolean;
}

export interface WeeklyView {
  pageId: string;
  pageTitle: string;
  pageUrl: string;
  version: number;
  modifiedBy: string;
  modifiedAt: string;
  personName: string;
  sections: SectionInfo[];
  currentWeekTitle: string;
  currentWeekExists: boolean;
  entry: WeekEntry | null;
}

export interface SaveResult {
  changed: boolean;
  version: number;
}

export interface DraftItem {
  /** 插入周报的文字，例如“修复导入 --100%” */
  text: string;
  /** 对应的 Jira 问题 */
  key: string | null;
  /** 依据：流转、评论、推送、合并请求、完成的待办等 */
  evidence: string[];
  /** 上周周报中同一件事的进度 */
  lastWeek: string | null;
}

export interface DraftGroup {
  title: string;
  source: "jira" | "worklog" | "gitlab" | "wiki" | "todo" | "daily";
  items: DraftItem[];
}

/** 上周没有完成的条目；thisWeek 为本周草稿中对应的条目，为空表示这一周没有相关记录。 */
export interface CarryOver {
  group: string;
  text: string;
  progress: string | null;
  thisWeek: string | null;
}

export interface Draft {
  from: string;
  to: string;
  groups: DraftGroup[];
  carryOver: CarryOver[];
  /** 上周周报所在的小节 */
  lastWeekTitle: string | null;
  /** 往周使用的进度写法，例如 " --" */
  separator: string;
  notes: string[];
}

// ---------- GitLab ----------

export interface Project {
  id: number;
  name: string;
  pathWithNamespace: string;
  description: string | null;
  defaultBranch: string | null;
  webUrl: string;
  lastActivityAt: string;
  /** 以下两项只有项目详情返回 */
  removeSourceBranchAfterMerge: boolean | null;
  squashOption: "never" | "always" | "default_on" | "default_off" | null;
}

export interface Commit {
  id: string;
  shortId: string;
  title: string;
  message: string;
  authorName: string;
  authoredDate: string;
  webUrl: string | null;
}

/** 找到问题与代码关联的线索。 */
export interface CodeRefSource {
  /** 描述中的链接 / 评论中的链接 / 合并请求的标题或描述含问题键 / 提交说明含问题键 */
  kind: "description" | "comment" | "mrSearch" | "commitSearch";
  author: string | null;
  at: string | null;
  commentId: string | null;
}

/** 问题中提到的代码。 */
export interface CodeRef {
  /** external：其他 GitLab 实例上的地址，只能在浏览器中打开 */
  kind: "mr" | "branch" | "commit" | "external";
  url: string;
  projectId: number | null;
  projectPath: string;
  projectName: string;
  branch: string | null;
  sha: string | null;
  iid: number | null;
  /** 合并请求标题、提交标题，或分支最近一次提交的标题 */
  title: string;
  /** 合并请求：opened / merged / closed / locked；分支：merged / missing；提交：missing */
  state: string | null;
  pipeline: string | null;
  author: string | null;
  at: string | null;
  /** 分支：线索时间前后的提交 */
  commits: Commit[];
  /** 无法访问时的说明 */
  unavailable: string | null;
  sources: CodeRefSource[];
}

/** 问题的一段正文，用于找出其中的代码链接。 */
export interface IssueText {
  source: "description" | "comment";
  commentId?: string;
  author?: string;
  at?: string;
  html: string;
}

/** 分支、提交或合并请求；text 是标题、分支名、提交说明等。 */
export interface CodeTarget {
  projectPath: string;
  branch?: string;
  sha?: string;
  iid?: number;
  text: string;
}

export interface RelatedIssue extends IssueHit {
  /** key：标题、分支名或提交说明中的问题键；link：问题中链接了它 */
  via: "key" | "link";
}

export interface Branch {
  name: string;
  default: boolean;
  protected: boolean;
  merged: boolean;
  commit: Commit;
}

export interface TreeEntry {
  name: string;
  path: string;
  kind: "tree" | "blob" | "commit";
}

export interface FileContent {
  path: string;
  size: number;
  text: string | null;
  imageDataUrl: string | null;
  tooLarge: boolean;
  binary: boolean;
}

export interface FileDiff {
  oldPath: string;
  newPath: string;
  diff: string;
  newFile: boolean;
  deletedFile: boolean;
  renamedFile: boolean;
}

export interface CommitDetail {
  commit: Commit;
  diffs: FileDiff[];
}

export interface Comparison {
  commits: Commit[];
  diffs: FileDiff[];
}

export interface GlUser {
  id: number;
  username: string;
  name: string;
}

export interface MergeRequest {
  id: number;
  iid: number;
  projectId: number;
  title: string;
  description: string;
  state: "opened" | "merged" | "closed" | "locked";
  draft: boolean;
  author: GlUser;
  assignees: GlUser[];
  reviewers: GlUser[];
  sourceBranch: string;
  targetBranch: string;
  sourceProjectId: number | null;
  createdAt: string;
  updatedAt: string;
  mergedAt: string | null;
  mergedBy: GlUser | null;
  closedAt: string | null;
  closedBy: GlUser | null;
  mergeStatus: string;
  hasConflicts: boolean;
  userNotesCount: number;
  upvotes: number;
  labels: string[];
  webUrl: string;
  /** 完整引用，例如 group/project!12 */
  reference: string;
  changesCount: string | null;
  sha: string | null;
  diffRefs: { baseSha: string; headSha: string; startSha: string } | null;
  headPipeline: { id: number; status: string; webUrl: string | null } | null;
  squash: boolean;
  forceRemoveSourceBranch: boolean | null;
  blockingDiscussionsResolved: boolean;
  mergeError: string | null;
  mergeWhenPipelineSucceeds: boolean;
  /** 只有详情返回 */
  canMerge: boolean;
}

export interface NotePosition {
  baseSha: string;
  startSha: string;
  headSha: string;
  oldPath: string;
  newPath: string;
  oldLine: number | null;
  newLine: number | null;
}

export interface MrNote {
  id: number;
  body: string;
  author: GlUser;
  createdAt: string;
  updatedAt: string | null;
  system: boolean;
  resolvable: boolean;
  resolved: boolean;
  resolvedBy: GlUser | null;
  position: NotePosition | null;
}

export interface Discussion {
  id: string;
  individualNote: boolean;
  notes: MrNote[];
}

export interface Approvals {
  approved: boolean;
  userHasApproved: boolean;
  userCanApprove: boolean;
  approvedBy: GlUser[];
}

export type MrScope = "created_by_me" | "assigned_to_me" | "reviewer";
export type MrState = "opened" | "merged" | "closed" | "all";

export interface MrQuery {
  state?: MrState;
  search?: string | null;
  sourceBranch?: string | null;
  page?: number;
}

/** 合并请求的项目可以是 id 或路径。 */
export type GlProjectRef = number | string;

// ---------- 工作空间 ----------

export interface Todo {
  id: string;
  title: string;
  notes: string;
  done: boolean;
  completedAt: number | null;
  /** YYYY-MM-DD */
  due: string | null;
  /** 0 无、1 低、2 中、3 高 */
  priority: number;
  sort: number;
  refSystem: string | null;
  refKey: string | null;
  refTitle: string | null;
  /** 自动创建的来源，例如 jira */
  source: string | null;
  autoDone: boolean;
  createdAt: number;
  updatedAt: number;
  /** 提醒时间（毫秒） */
  remindAt: number | null;
  repeat: Repeat | null;
  checklist: ChecklistItem[];
}

export type Repeat = "daily" | "weekdays" | "weekly" | "monthly";

export interface ChecklistItem {
  id: string;
  text: string;
  done: boolean;
}

export interface TodoInput {
  id?: string | null;
  title: string;
  notes?: string;
  done?: boolean;
  due?: string | null;
  priority?: number;
  refSystem?: string | null;
  refKey?: string | null;
  refTitle?: string | null;
  remindAt?: number | null;
  repeat?: Repeat | null;
  checklist?: ChecklistItem[];
}

/** 需要处理的一件事（今天页“需要处理”）：从各系统汇总的动态、到期问题、合并请求。 */
export interface InboxItem {
  id: string;
  source: "activity" | "due" | "mr";
  title: string;
  detail: string;
  at: number;
  system: "jira" | "wiki" | "gitlab" | null;
  key: string | null;
  url: string | null;
  mr: { projectId: number; iid: number; reference: string } | null;
  events: ActivityEvent[];
  dueKind: "overdue" | "today" | null;
  dueDays: number | null;
  snoozeUntil: number | null;
}

export interface InboxView {
  items: InboxItem[];
  snoozed: InboxItem[];
  notes: string[];
}

/** 工作记录中的一件事。 */
export interface WorkEvent {
  at: number;
  system: "jira" | "gitlab" | "wiki" | "todo";
  kind: string;
  title: string;
  key: string | null;
  detail: string;
  projectId: number | null;
}

export interface WorkLog {
  day: string;
  events: WorkEvent[];
  notes: string[];
}

export type DocKind = "note" | "daily" | "page";

export interface Doc {
  id: string;
  kind: DocKind;
  title: string;
  content: string;
  parentId: string | null;
  sort: number;
  tags: string[];
  day: string | null;
  pinned: boolean;
  sourceSystem: string | null;
  sourceKey: string | null;
  sourceUrl: string | null;
  /** 发布到的 Wiki 页面地址（带 pageVersion） */
  publishedUrl: string | null;
  createdAt: number;
  updatedAt: number;
}

export interface DocSummary {
  id: string;
  kind: DocKind;
  title: string;
  excerpt: string;
  parentId: string | null;
  sort: number;
  tags: string[];
  day: string | null;
  pinned: boolean;
  sourceSystem: string | null;
  sourceKey: string | null;
  publishedUrl: string | null;
  updatedAt: number;
}

/** Jira 评论、流转模板，内容为 JSON（见 lib/templates）。不出现在搜索中。 */
export const TEMPLATE_KIND = "jira-template";

export interface DocInput {
  id?: string | null;
  kind: DocKind | typeof TEMPLATE_KIND;
  title: string;
  content: string;
  parentId?: string | null;
  tags?: string[];
  pinned?: boolean;
  sourceSystem?: string | null;
  sourceKey?: string | null;
  sourceUrl?: string | null;
}

export interface Backlink {
  itemType: "todo" | "doc";
  id: string;
  kind: DocKind | "todo";
  title: string;
  done: boolean;
  updatedAt: number;
}

export interface WorkspaceHit {
  itemType: "todo" | "doc";
  id: string;
  kind: DocKind | "todo";
  title: string;
  snippet: string;
  done: boolean;
}

export interface SyncReport {
  exported: number;
  imported: number;
  conflicts: number;
  devices: number;
  finishedAt: number;
}

export interface WorkspaceSettings {
  syncDir: string;
  jiraTodos: boolean;
  deviceId: string;
  lastSync: SyncReport | null;
  lastError: string | null;
  captureShortcut: string;
  captureError: string | null;
}

export interface JiraTodoSync {
  added: number;
  completed: number;
  reopened: number;
}

/** 其他设备的修改合并进来后 Rust 发出的事件。 */
export const WORKSPACE_SYNCED_EVENT = "workspace-synced";
/** 托盘菜单中的操作（载荷为 `quick-todo`、`search`、`page:<页面>`、`tool:<工具>[:<标签>]` 或 `url:<地址>`），由后端发出。 */
export const TRAY_EVENT = "tray-action";
/** 需要处理的事有变化（稍后提醒到时）时由后端发出。 */
export const INBOX_EVENT = "inbox-changed";

// ---------- 剪贴板 ----------

/** text / link / code / color / image / file */
export type ClipKind = "text" | "link" | "code" | "color" | "image" | "file";

export interface ClipItem {
  id: string;
  kind: ClipKind;
  /** 文字的开头一部分（完整内容用 clipText 取） */
  text: string;
  textLength: number;
  hasHtml: boolean;
  /** 用户起的名字 */
  title: string;
  image: { width: number; height: number; bytes: number } | null;
  files: string[];
  appId: string | null;
  appName: string | null;
  /** 来源应用图标的主色 */
  appColor: string | null;
  appIcon: boolean;
  createdAt: number;
  copiedAt: number;
  copyCount: number;
  pinboard: string | null;
}

export interface ClipQuery {
  text?: string;
  kind?: ClipKind | null;
  /** 置顶板 id；"*" 表示所有置顶的条目 */
  pinboard?: string | null;
  app?: string | null;
  before?: number | null;
  limit?: number;
}

export interface Pinboard {
  id: string;
  name: string;
  color: string;
  sort: number;
  count: number;
}

export interface IgnoredApp {
  id: string;
  name: string;
}

export interface ClipboardConfig {
  enabled: boolean;
  shortcut: string;
  autoPaste: boolean;
  plainText: boolean;
  keepDays: number;
  maxItems: number;
  saveImages: boolean;
  maxImageMb: number;
  skipSecrets: boolean;
  ignoredApps: IgnoredApp[];
}

export interface ClipSettings {
  config: ClipboardConfig;
  builtinIgnored: IgnoredApp[];
  stats: { items: number; pinned: number; imageBytes: number };
  pasteSupport: "ready" | "needsPermission" | "unsupported";
  pasteNote: string | null;
  /** 暂停记录到何时；Number.MAX_SAFE_INTEGER 以上表示直到手动恢复 */
  pausedUntil: number | null;
  shortcutError: string | null;
  dataDir: string;
}

export interface ClipApp {
  id: string;
  name: string;
  color: string | null;
  icon: boolean;
  count: number;
}

/** 剪贴板记录到新内容时由后端发出，载荷为 ClipItem。 */
export const CLIP_CHANGED_EVENT = "clipboard-changed";
/** 剪贴板的设置、暂停状态或条目（删除、置顶等）有变化时由后端发出。 */
export const CLIP_SETTINGS_EVENT = "clipboard-settings";
/** 显示剪贴板面板时发给面板，载荷为 { target: 将要粘贴到的应用名称 }。 */
export const CLIP_OPEN_EVENT = "clipboard-open";

// ---------- Wiki ----------

export interface WikiSpace {
  key: string;
  name: string;
  homepageId: string | null;
  description: string;
}

export interface WikiNode {
  id: string;
  title: string;
  hasChildren: boolean;
}

export interface WikiAncestor {
  id: string;
  title: string;
}

export interface WikiPageDetail {
  id: string;
  kind: "page" | "blogpost";
  title: string;
  spaceKey: string;
  spaceName: string;
  version: number;
  modifiedBy: string;
  modified: string;
  versionMessage: string;
  createdBy: string;
  created: string;
  ancestors: WikiAncestor[];
  labels: string[];
  html: string;
  url: string;
  canEdit: boolean;
}

export interface WikiRecent {
  id: string;
  title: string;
  space: string;
  at: number;
  source: "app" | "web";
}

export interface WikiVersion {
  number: number;
  by: string;
  when: string;
  message: string;
  minorEdit: boolean;
}

export interface WikiComment {
  id: string;
  author: string;
  created: string;
  html: string;
  parentId: string | null;
  inlineText: string | null;
  version: number;
}

export interface WikiPageHit {
  id: string;
  kind: string;
  title: string;
  spaceKey: string;
  spaceName: string;
  ancestors: WikiAncestor[];
  authorName: string;
  modified: string;
  snippet: string;
}

export interface WikiQuery {
  text: string;
  space?: string;
  mine?: boolean;
  days?: number;
  kind?: string;
  limit?: number;
}

export interface WikiSearchResult {
  source: "local" | "server";
  total: number;
  hits: WikiPageHit[];
}

export interface WikiTemplate {
  id: string;
  name: string;
  description: string;
  spaceKey: string | null;
}

/** 编辑会话：可编辑的 HTML，以及宏等不可编辑内容的原文。 */
export interface WikiEditSession {
  pageId: string | null;
  title: string;
  spaceKey: string;
  version: number;
  html: string;
  fragments: string[];
  users: string[];
}

export interface WikiSavePreview {
  storage: string;
  diff: string;
  changed: boolean;
}

export interface WikiIndexStatus {
  enabled: boolean;
  count: number;
  spaces: { key: string; name: string; count: number }[];
  lastSync: string | null;
  running: boolean;
  progress: { done: number; total: number } | null;
  error: string | null;
}

export interface WikiToolsSettings {
  indexEnabled: boolean;
  indexSpaces: string[];
  taskTodos: boolean;
  activity: boolean;
  mutedPages: string[];
}

/** 本机 Wiki 库有变化时 Rust 发出的事件。 */
export const WIKI_INDEX_EVENT = "wiki-index-changed";

// ---------- 全局搜索 ----------

export interface WikiHit {
  id: string;
  title: string;
  space: string;
  url: string;
  excerpt: string;
}

export interface SearchResults {
  /** 本机问题库的结果带匹配处附近的文字 */
  issues: IssueHit[];
  /** local：本机问题库；jira：服务器搜索；没有搜索时为空 */
  issuesSource: "local" | "jira" | null;
  projects: Project[];
  mergeRequests: MergeRequest[];
  pages: WikiHit[];
  workspace: WorkspaceHit[];
  clips: ClipItem[];
  errors: string[];
}

/** phase：local 只查本机数据（快），remote 只查服务器；不填两步都做。limit：每类结果的条数 */
export interface SearchOptions {
  phase?: "local" | "remote";
  limit?: number;
}

export const api = {
  getSettings: () => invoke<Settings>("get_settings"),
  saveSettings: (input: SettingsInput) => invoke<Settings>("save_settings", { input }),
  clearToken: (service: Service) => invoke<Settings>("clear_token", { service }),
  importTokensEnv: () => invoke<Service[]>("import_tokens_env"),
  testConnection: (service: Service) => invoke<ConnectionInfo>("test_connection", { service }),

  jiraCachedSearch: (jql: string, fields: string[] = []) => invoke<SearchResult | null>("jira_cached_search", { jql, fields }),
  /** `fields` 为列表中额外显示的字段，结果在 `extra` 中 */
  jiraSearch: (jql: string, startAt = 0, maxResults = 100, fields: string[] = []) =>
    invoke<SearchResult>("jira_search", { jql, startAt, maxResults, fields }),
  jiraFields: (refresh = false) => invoke<FieldInfo[]>("jira_fields", { refresh }),
  /** from、to 为 YYYY-MM-DD（含两端） */
  jiraMyWorklogs: (from: string, to: string) => invoke<{ key: string; summary: string; seconds: number }[]>("jira_my_worklogs", { from, to }),
  jiraIssue: (key: string) => invoke<IssueDetail>("jira_issue", { key }),
  jiraTransitions: (key: string) => invoke<Transition[]>("jira_transitions", { key }),
  jiraTransition: (key: string, transitionId: string, fields: Record<string, unknown>, comment: string | null, visibility: CommentVisibility | null = null) =>
    invoke<IssueDetail>("jira_transition", { key, transitionId, fields, comment, visibility }),
  jiraAddComment: (key: string, body: string, visibility: CommentVisibility | null = null) => invoke<Comment>("jira_add_comment", { key, body, visibility }),
  jiraUpdateComment: (key: string, id: string, body: string, visibility: CommentVisibility | null) =>
    invoke<Comment>("jira_update_comment", { key, id, body, visibility }),
  /** 评论可选的可见范围；没有网页登录时为空 */
  jiraCommentLevels: (key: string) => invoke<CommentLevel[]>("jira_comment_levels", { key }),
  jiraDeleteComment: (key: string, id: string) => invoke<void>("jira_delete_comment", { key, id }),
  jiraMe: () => invoke<string>("jira_me"),
  jiraAssign: (key: string, assignee: string | null) => invoke<IssueDetail>("jira_assign", { key, assignee }),
  jiraWatchers: (key: string) => invoke<Watchers>("jira_watchers", { key }),
  jiraSetWatching: (key: string, watching: boolean) => invoke<Watchers>("jira_set_watching", { key, watching }),
  jiraPriorities: () => invoke<Priority[]>("jira_priorities"),
  jiraSetPriority: (key: string, priorityId: string) => invoke<IssueDetail>("jira_set_priority", { key, priorityId }),
  jiraActivity: () => invoke<ActivityFeed>("jira_activity"),
  jiraActivityPoll: () => invoke<{ feed: ActivityFeed; fresh: ActivityEvent[] }>("jira_activity_poll"),
  /** 不传 ids 时全部标为已读 */
  jiraActivityRead: (ids: string[] | null) => invoke<ActivityFeed>("jira_activity_read", { ids }),
  jiraPreviewAttachment: (url: string, filename: string, mime: string, service: Service = "jira") => invoke<AttachmentPreview>("jira_preview_attachment", { url, filename, mime, service }),
  jiraFavouriteFilters: () => invoke<JiraFilter[]>("jira_favourite_filters"),
  jiraSimilarIssues: (key: string, summary: string, resolvedOnly: boolean) => invoke<SimilarIssues>("jira_similar_issues", { key, summary, resolvedOnly }),
  jiraIndexStatus: () => invoke<IndexStatus>("jira_index_status"),
  jiraIndexSync: () => invoke<void>("jira_index_sync"),
  jiraIndexRebuild: () => invoke<IndexStatus>("jira_index_rebuild"),
  jiraIndexSearch: (query: IndexQuery) => invoke<IssueHit[]>("jira_index_search", { query }),
  /** 上次在本应用中查看的时间（毫秒）；没有记录的问题以 baseline 为准 */
  jiraViewed: (keys: string[]) => invoke<{ viewed: Record<string, number>; baseline: number }>("jira_viewed", { keys }),
  /** 记录查看，返回上一次的查看时间 */
  jiraMarkViewed: (key: string, updated: string | null) => invoke<number | null>("jira_mark_viewed", { key, updated }),
  jiraToolsSettings: () => invoke<JiraToolsSettings>("jira_tools_settings"),
  jiraSaveToolsSettings: (settings: JiraToolsSettings) => invoke<JiraToolsSettings>("jira_save_tools_settings", { settings }),
  jiraReminders: () => invoke<Reminders>("jira_reminders"),
  localImagePreview: (path: string) => invoke<string | null>("local_image_preview", { path }),
  jiraUploadAttachments: (key: string, paths: string[]) =>
    invoke<Attachment[]>("jira_upload_attachments", { key, paths }),
  jiraOpenAttachment: (url: string, filename: string, service: Service = "jira") =>
    invoke<string>("jira_open_attachment", { url, filename, service }),
  jiraEditFields: (key: string) => invoke<FieldMeta[]>("jira_edit_fields", { key }),
  jiraUpdateIssue: (key: string, fields: Record<string, unknown>) => invoke<IssueDetail>("jira_update_issue", { key, fields }),
  jiraCachedCreateProjects: () => invoke<CreateProject[] | null>("jira_cached_create_projects"),
  jiraCreateProjects: () => invoke<CreateProject[]>("jira_create_projects"),
  jiraCreateFields: (projectKey: string, issueTypeId: string) => invoke<FieldMeta[]>("jira_create_fields", { projectKey, issueTypeId }),
  jiraCreateIssue: (fields: Record<string, unknown>, attachments: string[]) =>
    invoke<{ key: string; attachmentError: string | null }>("jira_create_issue", { fields, attachments }),
  jiraFindUsers: (query: string, field: string, issueKey: string | null, projectKey: string | null) =>
    invoke<UserRef[]>("jira_find_users", { query, field, issueKey, projectKey }),
  jiraSuggestedAssignees: (key: string) => invoke<UserRef[]>("jira_suggested_assignees", { key }),
  jiraSuggestLabels: (query: string) => invoke<string[]>("jira_suggest_labels", { query }),
  jiraSearchEpics: (query: string, projectKey: string) => invoke<IssueRef[]>("jira_search_epics", { query, projectKey }),
  jiraPickIssues: (query: string, projectKey: string | null, standardOnly: boolean) =>
    invoke<IssueSummary[]>("jira_pick_issues", { query, projectKey, standardOnly }),
  jiraLinkTypes: () => invoke<LinkType[]>("jira_link_types"),
  jiraAddLink: (key: string, typeId: string, other: string, outward: boolean) =>
    invoke<IssueDetail>("jira_add_link", { key, typeId, other, outward }),
  jiraDeleteLink: (key: string, linkId: string) => invoke<IssueDetail>("jira_delete_link", { key, linkId }),
  jiraWorklogs: (key: string) => invoke<Worklog[]>("jira_worklogs", { key }),
  jiraSaveWorklog: (key: string, id: string | null, input: WorklogInput) => invoke<Worklog[]>("jira_save_worklog", { key, id, input }),
  jiraDeleteWorklog: (key: string, id: string) => invoke<Worklog[]>("jira_delete_worklog", { key, id }),
  jiraHistory: (key: string) => invoke<HistoryEntry[]>("jira_history", { key }),
  jiraRenderWiki: (markup: string, issueKey: string | null) => invoke<string>("jira_render_wiki", { markup, issueKey }),
  /** 保存粘贴的图片到本地，返回路径。 */
  jiraSavePastedImage: (base64: string, filename: string) => invoke<string>("jira_save_pasted_image", { data: base64, filename }),

  weeklyLoad: (section: string | null = null) => invoke<WeeklyView>("weekly_load", { section }),
  weeklySave: (input: { section: string; contentRaw: string; riskRaw: string; content: OutlineItem[]; risk: OutlineItem[] }) =>
    invoke<SaveResult>("weekly_save", { input }),
  weeklyCreateWeek: () => invoke<WeeklyView>("weekly_create_week"),
  weeklyDraft: (section: string | null) => invoke<Draft>("weekly_draft", { section }),

  glCachedProjects: () => invoke<Project[] | null>("gl_cached_projects"),
  glProjects: (search: string | null = null) => invoke<Project[]>("gl_projects", { search }),
  glProject: (id: number) => invoke<Project>("gl_project", { id }),
  glBranches: (project: number) => invoke<Branch[]>("gl_branches", { project }),
  glTree: (project: number, gitRef: string, path: string) => invoke<TreeEntry[]>("gl_tree", { project, gitRef, path }),
  glFile: (project: number, gitRef: string, path: string) => invoke<FileContent>("gl_file", { project, gitRef, path }),
  glCommits: (project: number, gitRef: string, path: string | null, page: number) =>
    invoke<Commit[]>("gl_commits", { project, gitRef, path, page }),
  glCommit: (project: number, sha: string) => invoke<CommitDetail>("gl_commit", { project, sha }),
  glCompare: (project: number, from: string, to: string) => invoke<Comparison>("gl_compare", { project, from, to }),
  issueCodeRefs: (key: string, texts: IssueText[]) => invoke<CodeRef[]>("issue_code_refs", { key, texts }),
  codeRelatedIssues: (target: CodeTarget) => invoke<RelatedIssue[]>("code_related_issues", { target }),
  glMe: () => invoke<GlUser>("gl_me"),
  glMergeRequests: (scope: MrScope, query: MrQuery) => invoke<MergeRequest[]>("gl_merge_requests", { scope, query }),
  glProjectMergeRequests: (project: GlProjectRef, query: MrQuery) =>
    invoke<MergeRequest[]>("gl_project_merge_requests", { project: String(project), query }),
  glMergeRequest: (project: GlProjectRef, iid: number) => invoke<MergeRequest>("gl_merge_request", { project: String(project), iid }),
  glMrChanges: (project: GlProjectRef, iid: number) =>
    invoke<{ diffs: FileDiff[]; overflow: boolean }>("gl_mr_changes", { project: String(project), iid }),
  glMrCommits: (project: GlProjectRef, iid: number) => invoke<Commit[]>("gl_mr_commits", { project: String(project), iid }),
  glMrDiscussions: (project: GlProjectRef, iid: number) => invoke<Discussion[]>("gl_mr_discussions", { project: String(project), iid }),
  glMrApprovals: (project: GlProjectRef, iid: number) => invoke<Approvals>("gl_mr_approvals", { project: String(project), iid }),
  glMrAddNote: (project: GlProjectRef, iid: number, body: string, position: NotePosition | null = null) =>
    invoke<Discussion>("gl_mr_add_note", { project: String(project), iid, body, position }),
  glMrReply: (project: GlProjectRef, iid: number, discussion: string, body: string) =>
    invoke<MrNote>("gl_mr_reply", { project: String(project), iid, discussion, body }),
  glMrEditNote: (project: GlProjectRef, iid: number, note: number, body: string) =>
    invoke<MrNote>("gl_mr_edit_note", { project: String(project), iid, note, body }),
  glMrDeleteNote: (project: GlProjectRef, iid: number, note: number) => invoke<void>("gl_mr_delete_note", { project: String(project), iid, note }),
  glMrResolve: (project: GlProjectRef, iid: number, discussion: string, resolved: boolean) =>
    invoke<Discussion>("gl_mr_resolve", { project: String(project), iid, discussion, resolved }),
  glMrApprove: (project: GlProjectRef, iid: number, approve: boolean) =>
    invoke<Approvals>("gl_mr_approve", { project: String(project), iid, approve }),
  glMrMerge: (project: GlProjectRef, iid: number, options: { squash: boolean; removeSourceBranch: boolean; sha: string | null }) =>
    invoke<MergeRequest>("gl_mr_merge", { project: String(project), iid, options }),
  glMrUpdate: (
    project: GlProjectRef,
    iid: number,
    update: { title?: string; description?: string; targetBranch?: string; stateEvent?: "close" | "reopen"; removeSourceBranch?: boolean; squash?: boolean },
  ) => invoke<MergeRequest>("gl_mr_update", { project: String(project), iid, update }),
  glMrCreate: (
    project: GlProjectRef,
    mr: { sourceBranch: string; targetBranch: string; title: string; description: string; removeSourceBranch: boolean; squash: boolean },
  ) => invoke<MergeRequest>("gl_mr_create", { project: String(project), mr }),

  wsTodos: () => invoke<Todo[]>("ws_todos"),
  wsSaveTodo: (input: TodoInput) => invoke<Todo>("ws_save_todo", { input }),
  wsSetTodoDone: (id: string, done: boolean) => invoke<Todo>("ws_set_todo_done", { id, done }),
  wsMoveTodo: (id: string, sort: number) => invoke<void>("ws_move_todo", { id, sort }),
  wsDeleteTodo: (id: string) => invoke<void>("ws_delete_todo", { id }),
  wsRefreshJiraTodos: () => invoke<JiraTodoSync | null>("ws_refresh_jira_todos"),
  wsDocs: (kind: DocKind) => invoke<DocSummary[]>("ws_docs", { kind }),
  wsDoc: (id: string) => invoke<Doc | null>("ws_doc", { id }),
  /** 某类文档的完整内容（模板等） */
  wsFullDocs: (kind: DocKind | typeof TEMPLATE_KIND) => invoke<Doc[]>("ws_full_docs", { kind }),
  wsDaily: (day: string) => invoke<Doc>("ws_daily", { day }),
  wsDailyDays: () => invoke<string[]>("ws_daily_days"),
  wsSaveDoc: (input: DocInput) => invoke<Doc>("ws_save_doc", { input }),
  wsMoveDoc: (id: string, parentId: string | null, sort: number) => invoke<Doc>("ws_move_doc", { id, parentId, sort }),
  wsDeleteDoc: (id: string) => invoke<number>("ws_delete_doc", { id }),
  wsTags: () => invoke<{ name: string; count: number }[]>("ws_tags"),
  wsBacklinks: (system: string, key: string) => invoke<Backlink[]>("ws_backlinks", { system, key }),
  wsSearch: (query: string) => invoke<WorkspaceHit[]>("ws_search", { query }),
  wsSaveAsset: (base64: string, mime: string) => invoke<{ id: string; mime: string }>("ws_save_asset", { data: base64, mime }),
  wsSettings: () => invoke<WorkspaceSettings>("ws_settings"),
  wsSaveSettings: (syncDir: string, jiraTodos: boolean) => invoke<WorkspaceSettings>("ws_save_settings", { syncDir, jiraTodos }),
  wsSync: () => invoke<SyncReport | null>("ws_sync"),
  wsSaveCaptureShortcut: (shortcut: string) => invoke<WorkspaceSettings>("ws_save_capture_shortcut", { shortcut }),
  wsInbox: () => invoke<InboxView>("ws_inbox"),
  wsInboxHandle: (input: { id: string; title: string; eventIds?: string[] }) => invoke<void>("ws_inbox_handle", { input }),
  wsInboxSnooze: (id: string, title: string, until: number | null) => invoke<void>("ws_inbox_snooze", { id, title, until }),
  wsWorklog: (day: string) => invoke<WorkLog>("ws_worklog", { day }),
  captureHide: () => invoke<void>("capture_hide"),
  captureClipboard: () => invoke<string | null>("capture_clipboard"),
  clipboardReadText: () => invoke<string | null>("clipboard_read_text"),
  toolsHidden: () => invoke<string[]>("tools_hidden"),
  toolsSetHidden: (hidden: string[]) => invoke<string[]>("tools_set_hidden", { hidden }),
  clipList: (query: ClipQuery) => invoke<ClipItem[]>("clip_list", { query }),
  clipText: (id: string) => invoke<{ text: string; html: string | null }>("clip_text", { id }),
  /** 粘贴到打开面板前使用的应用；返回 pasted（已粘贴）或 copied（只复制了） */
  clipPaste: (ids: string[], plain?: boolean, edited?: string) => invoke<"pasted" | "copied">("clip_paste", { ids, plain, edited }),
  clipCopy: (ids: string[], plain?: boolean, edited?: string) => invoke<void>("clip_copy", { ids, plain, edited }),
  clipHide: (restore: boolean) => invoke<void>("clip_hide", { restore }),
  /** 收起面板，在主窗口中打开（载荷格式同托盘菜单事件） */
  clipOpenMain: (target: string) => invoke<void>("clip_open_main", { target }),
  clipDelete: (ids: string[]) => invoke<void>("clip_delete", { ids }),
  clipClear: () => invoke<number>("clip_clear"),
  clipSetPinboard: (ids: string[], pinboard: string | null) => invoke<void>("clip_set_pinboard", { ids, pinboard }),
  clipRename: (id: string, title: string) => invoke<ClipItem | null>("clip_rename", { id, title }),
  clipUpdateText: (id: string, text: string) => invoke<ClipItem | null>("clip_update_text", { id, text }),
  clipPinboards: () => invoke<Pinboard[]>("clip_pinboards"),
  clipSavePinboard: (id: string | null, name: string, color: string) => invoke<Pinboard>("clip_save_pinboard", { id, name, color }),
  clipDeletePinboard: (id: string) => invoke<void>("clip_delete_pinboard", { id }),
  clipOrderPinboards: (ids: string[]) => invoke<void>("clip_order_pinboards", { ids }),
  clipApps: () => invoke<ClipApp[]>("clip_apps"),
  clipIssues: (keys: string[]) => invoke<IssueHit[]>("clip_issues", { keys }),
  clipSettings: () => invoke<ClipSettings>("clip_settings"),
  clipSaveSettings: (config: ClipboardConfig) => invoke<ClipSettings>("clip_save_settings", { config }),
  /** 暂停记录：minutes 为 0 表示恢复，负数表示直到手动恢复 */
  clipPause: (minutes: number) => invoke<ClipSettings>("clip_pause", { minutes }),
  clipIgnoreCandidates: () => invoke<IgnoredApp[]>("clip_ignore_candidates"),
  /** 标记为刚刚使用（拖到其他应用后） */
  clipTouch: (ids: string[]) => invoke<void>("clip_touch", { ids }),
  /** 把图片、文件条目作为文件拖到其他应用（需在按住鼠标拖动时调用） */
  clipDrag: (ids: string[]) => invoke<void>("clip_drag", { ids }),
  wsWikiPage: (page: string) => invoke<{ id: string; title: string; spaceKey: string; url: string; html: string; version: number }>("ws_wiki_page", { page }),
  /** mode：create 在 parent 下新建；update 更新上次发布的页面（被别人改过时报冲突）；overwrite 覆盖别人的修改 */
  wsPublishToWiki: (docId: string | null, mode: "create" | "update" | "overwrite", parent: string, title: string, storage: string, assets: string[]) =>
    invoke<{ url: string; updated: boolean; doc: Doc | null }>("ws_publish_to_wiki", { docId, mode, parent, title, storage, assets }),

  wikiCachedSpaces: () => invoke<WikiSpace[] | null>("wiki_cached_spaces"),
  wikiSpaces: () => invoke<WikiSpace[]>("wiki_spaces"),
  wikiSpaceRoots: (space: string) => invoke<WikiNode[]>("wiki_space_roots", { space }),
  wikiChildren: (page: string) => invoke<WikiNode[]>("wiki_children", { page }),
  /** page 为页面 id 或地址 */
  wikiPage: (page: string) => invoke<WikiPageDetail>("wiki_page", { page }),
  wikiResolve: (input: string) => invoke<string | null>("wiki_resolve", { input }),
  wikiAttachments: (page: string) => invoke<Attachment[]>("wiki_attachments", { page }),
  wikiRecent: (limit = 30) => invoke<WikiRecent[]>("wiki_recent", { limit }),
  wikiVersions: (page: string) => invoke<WikiVersion[]>("wiki_versions", { page }),
  wikiDiff: (page: string, from: number, to: number) => invoke<string>("wiki_diff", { page, from, to }),
  wikiVersionHtml: (page: string, version: number) => invoke<string>("wiki_version_html", { page, version }),
  wikiPageVersion: (page: string) => invoke<{ title: string; version: number; by: string; when: string }>("wiki_page_version", { page }),
  wikiComments: (page: string) => invoke<WikiComment[]>("wiki_comments", { page }),
  wikiAddComment: (page: string, parent: string | null, text: string) => invoke<WikiComment[]>("wiki_add_comment", { page, parent, text }),
  wikiSetTask: (page: string, task: string, done: boolean) => invoke<void>("wiki_set_task", { page, task, done }),
  wikiUsers: (keys: string[]) => invoke<Record<string, string>>("wiki_users", { keys }),
  wikiSearch: (query: WikiQuery, server = false, start = 0) => invoke<WikiSearchResult>("wiki_search", { query: { limit: 50, ...query }, server, start }),
  wikiIssuePages: (key: string) => invoke<WikiPageHit[]>("wiki_issue_pages", { key }),
  wikiEdit: (page: string) => invoke<WikiEditSession>("wiki_edit", { page }),
  wikiNewPage: (space: string, template: string | null, storage: string | null) => invoke<WikiEditSession>("wiki_new_page", { space, template, storage }),
  wikiTemplates: (space: string | null) => invoke<WikiTemplate[]>("wiki_templates", { space }),
  wikiPreviewSave: (page: string | null, xhtml: string, fragments: string[]) => invoke<WikiSavePreview>("wiki_preview_save", { page, xhtml, fragments }),
  wikiSave: (input: { page: string; title: string; xhtml: string; fragments: string[]; baseVersion: number; minorEdit: boolean; message: string }) =>
    invoke<number>("wiki_save", input),
  wikiCreate: (input: { space: string; parent: string | null; title: string; xhtml: string; fragments: string[] }) => invoke<string>("wiki_create", input),
  wikiIndexStatus: () => invoke<WikiIndexStatus>("wiki_index_status"),
  wikiIndexSync: () => invoke<void>("wiki_index_sync"),
  wikiIndexRebuild: () => invoke<WikiIndexStatus>("wiki_index_rebuild"),
  wikiToolsSettings: () => invoke<WikiToolsSettings>("wiki_tools_settings"),
  wikiSaveToolsSettings: (settings: WikiToolsSettings) => invoke<WikiToolsSettings>("wiki_save_tools_settings", { settings }),

  globalSearch: (query: string, options?: SearchOptions) => invoke<SearchResults>("global_search", { query, options }),

  webAccessStatus: () => invoke<Partial<Record<Service, WebAccess>>>("web_access_status"),
  webLogin: (service: Service) => invoke<void>("web_login", { service }),
  webLogout: (service: Service) => invoke<void>("web_logout", { service }),
};

/** 网页会话状态变化（登录成功、会话失效）时 Rust 发出的事件，载荷为服务名。 */
export const WEB_SESSION_EVENT = "web-session";

/** Rust 侧的错误被序列化为字符串，这里统一转成可显示的文本。 */
export function errorMessage(error: unknown): string {
  return typeof error === "string" ? error : error instanceof Error ? error.message : String(error);
}
