// GitLab 对象的右键菜单：合并请求、文件、提交、分支。各列表和详情共用，顺序与 Jira、Wiki 的菜单一致：
// 打开 → 操作 → 复制 → 在浏览器中打开。
import { openUrl } from "@tauri-apps/plugin-opener";
import { CircleDot, Copy, ExternalLink, FileCode2, FolderGit2, GitBranch, GitCommitHorizontal, GitPullRequest, GitPullRequestCreate, Link } from "lucide-react";
import type { Branch, Commit, MergeRequest, TreeEntry } from "../../api";
import type { MenuInput } from "../../components/ContextMenu";
import { guarded, toast } from "../../components/Toast";
import { copyText } from "../../lib/clipboard";
import { issueKeysIn } from "../../lib/gitlabMarkdown";
import type { NavTarget } from "../../state/nav";
import { mrProjectPath } from "./MergeRequestView";

const copy = (label: string, text: string, icon?: React.ReactNode): MenuInput => ({
  label,
  icon,
  onSelect: guarded(async () => {
    await copyText(text);
    toast("已复制");
  }),
});

const browser = (url: string | null | undefined): MenuInput => url && { label: "在浏览器中打开", icon: <ExternalLink size={14} />, onSelect: guarded(() => openUrl(url)) };

/** 合并请求；`onOpen` 不提供时（正在查看）不显示“打开”。 */
export function mrMenu(mr: MergeRequest, navigate: (target: NavTarget) => void, options: { onOpen?: () => void; jira?: boolean } = {}): MenuInput[] {
  const keys = options.jira ? issueKeysIn(`${mr.title} ${mr.sourceBranch}`) : [];
  return [
    options.onOpen && { label: "打开", icon: <GitPullRequest size={14} />, onSelect: options.onOpen },
    { label: "打开项目", icon: <FolderGit2 size={14} />, onSelect: () => navigate({ page: "gitlab", projectId: mr.projectId }) },
    ...keys.map((key) => ({ label: `打开 ${key}`, icon: <CircleDot size={14} />, onSelect: () => navigate({ page: "jira", issueKey: key }) })),
    "separator",
    copy("复制链接", mr.webUrl, <Link size={14} />),
    copy("复制引用", mr.reference),
    copy("复制标题", mr.title, <Copy size={14} />),
    copy("复制源分支名", mr.sourceBranch, <GitBranch size={14} />),
    copy("复制为 Markdown 链接", `[${mrProjectPath(mr).split("/").pop()}!${mr.iid} ${mr.title}](${mr.webUrl})`),
    "separator",
    browser(mr.webUrl),
  ];
}

/** 代码浏览中的文件或目录。 */
export function treeEntryMenu(entry: TreeEntry, projectUrl: string, gitRef: string, onOpen: () => void): MenuInput[] {
  const url = `${projectUrl}/-/${entry.kind === "tree" ? "tree" : "blob"}/${encodeURIComponent(gitRef)}/${entry.path.split("/").map(encodeURIComponent).join("/")}`;
  return [
    entry.kind !== "commit" && { label: "打开", icon: <FileCode2 size={14} />, onSelect: onOpen },
    "separator",
    copy("复制路径", entry.path, <Copy size={14} />),
    copy("复制名称", entry.name),
    copy("复制链接", url, <Link size={14} />),
    "separator",
    browser(url),
  ];
}

export function commitMenu(commit: Commit, onOpen: () => void): MenuInput[] {
  return [
    { label: "查看提交", icon: <GitCommitHorizontal size={14} />, onSelect: onOpen },
    "separator",
    copy("复制提交 SHA", commit.id, <Copy size={14} />),
    copy("复制短 SHA", commit.shortId),
    copy("复制提交信息", commit.message || commit.title),
    commit.webUrl && copy("复制链接", commit.webUrl, <Link size={14} />),
    "separator",
    browser(commit.webUrl),
  ];
}

export function branchMenu(branch: Branch, projectUrl: string, options: { onOpen: () => void; onCreateMr?: () => void }): MenuInput[] {
  const url = `${projectUrl}/-/tree/${encodeURIComponent(branch.name)}`;
  return [
    { label: "浏览代码", icon: <FileCode2 size={14} />, onSelect: options.onOpen },
    options.onCreateMr && { label: "发起合并请求…", icon: <GitPullRequestCreate size={14} />, onSelect: options.onCreateMr },
    "separator",
    copy("复制分支名", branch.name, <GitBranch size={14} />),
    copy("复制最新提交 SHA", branch.commit.id),
    copy("复制链接", url, <Link size={14} />),
    "separator",
    browser(url),
  ];
}
