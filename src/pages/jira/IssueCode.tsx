// 问题详情中的“代码”：描述、评论里链接的分支、提交、合并请求，以及标题含问题键的合并请求、提交说明含问题键的提交。
import { useEffect, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { Code2, Copy, ExternalLink, GitBranch, GitCommitHorizontal, GitPullRequest, Link } from "lucide-react";
import { api, type CodeRef, type CodeRefSource, type Commit, type IssueDetail, type IssueText } from "../../api";
import { Skeleton } from "../../components/common";
import type { MenuInput } from "../../components/ContextMenu";
import { useMenus } from "../../components/MenuHost";
import { guarded, toast } from "../../components/Toast";
import { copyText } from "../../lib/clipboard";
import { formatTime } from "../../lib/format";
import { useNav, type NavTarget } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { PIPELINE_LABELS, STATE_LABELS } from "../gitlab/labels";

/** 结果缓存一段时间：在问题之间来回切换时不重复请求 GitLab。 */
const CACHE_MS = 5 * 60 * 1000;
const cache = new Map<string, { at: number; refs: CodeRef[] }>();
/** 分支下默认显示的提交数。 */
const COMMITS_SHOWN = 3;

function issueTexts(issue: IssueDetail): IssueText[] {
  const texts: IssueText[] = [];
  if (issue.descriptionHtml) texts.push({ source: "description", author: issue.reporter ?? undefined, at: issue.created, html: issue.descriptionHtml });
  for (const c of issue.comments) texts.push({ source: "comment", commentId: c.id, author: c.author, at: c.created, html: c.bodyHtml });
  return texts;
}

/** 正文变化（新评论、编辑描述）后缓存失效。 */
function cacheKey(issue: IssueDetail): string {
  return `${issue.key}|${issue.updated}|${issue.comments.length}`;
}

export function IssueCode({ issue, onCount }: { issue: IssueDetail; onCount?: (n: number) => void }) {
  const { isReady } = useSettings();
  const [refs, setRefs] = useState<CodeRef[] | null>(null);
  const ready = isReady("gitlab");
  const key = cacheKey(issue);

  useEffect(() => {
    let alive = true;
    const hit = cache.get(key);
    if (hit && Date.now() - hit.at < CACHE_MS) {
      setRefs(hit.refs);
      return;
    }
    setRefs(null);
    api.issueCodeRefs(issue.key, issueTexts(issue)).then(
      (list) => {
        cache.set(key, { at: Date.now(), refs: list });
        if (alive) setRefs(list);
      },
      () => alive && setRefs([]),
    );
    return () => {
      alive = false;
    };
    // issue 的内容由 key 概括
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, ready]);

  useEffect(() => {
    onCount?.(refs?.length ?? 0);
  }, [refs, onCount]);

  if (refs && refs.length === 0) return null;
  // 没配置 GitLab 且正文里没有其他实例的链接时，加载中也不占位
  if (!refs && !ready) return null;
  return (
    <section className="block" id="issue-code">
      <h2>
        <Code2 size={16} className="muted" />
        代码 {refs && <span className="count">{refs.length}</span>}
      </h2>
      {!refs && <Skeleton lines={2} />}
      {refs && (
        <ul className="code-refs">
          {refs.map((r) => (
            <CodeRefItem key={`${r.kind}|${r.url}`} item={r} issueKey={issue.key} />
          ))}
        </ul>
      )}
    </section>
  );
}

function targetOf(r: CodeRef): NavTarget | null {
  if (r.unavailable || r.kind === "external" || !r.projectId) return null;
  if (r.kind === "mr" && r.iid) return { page: "gitlab", projectId: r.projectId, mrIid: r.iid };
  if (r.kind === "commit" && r.sha && r.state !== "missing") return { page: "gitlab", projectId: r.projectId, commitSha: r.sha };
  if (r.kind === "branch" && r.branch && r.state !== "missing") return { page: "gitlab", projectId: r.projectId, gitRef: r.branch };
  return null;
}

function copyItem(label: string, text: string, icon?: React.ReactNode): MenuInput {
  return {
    label,
    icon,
    onSelect: guarded(async () => {
      await copyText(text);
      toast("已复制");
    }),
  };
}

function refMenu(r: CodeRef, open: (() => void) | null): MenuInput[] {
  return [
    open && { label: "打开", icon: r.kind === "mr" ? <GitPullRequest size={14} /> : r.kind === "branch" ? <GitBranch size={14} /> : <GitCommitHorizontal size={14} />, onSelect: open },
    "separator",
    r.branch && r.kind !== "commit" && copyItem("复制分支名", r.branch, <GitBranch size={14} />),
    r.sha && copyItem("复制提交 SHA", r.sha, <Copy size={14} />),
    copyItem("复制链接", r.url, <Link size={14} />),
    "separator",
    { label: "在浏览器中打开", icon: <ExternalLink size={14} />, onSelect: guarded(() => openUrl(r.url)) },
  ];
}

function CodeRefItem({ item: r, issueKey }: { item: CodeRef; issueKey: string }) {
  const { navigate } = useNav();
  const menus = useMenus();
  const [expanded, setExpanded] = useState(false);
  const target = targetOf(r);
  const open = target ? () => navigate(target) : r.kind === "external" || r.unavailable ? () => void openUrl(r.url) : null;
  const Icon = r.kind === "mr" ? GitPullRequest : r.kind === "branch" ? GitBranch : r.kind === "commit" ? GitCommitHorizontal : ExternalLink;
  const commits = expanded ? r.commits : r.commits.slice(0, COMMITS_SHOWN);
  const menuKey = `code:${r.url}`;

  return (
    <li className={`code-ref${r.unavailable || r.kind === "external" ? " unavailable" : ""}`}>
      <div className={`code-ref-main clickable${menus.target === menuKey ? " menu-target" : ""}`} onClick={open ?? undefined} onContextMenu={(e) => menus.open(e, refMenu(r, target ? () => navigate(target) : null), menuKey)}>
        <Icon size={15} className="muted" />
        <span className="code-ref-name ellipsis">
          <RefName item={r} />
        </span>
        <RefState item={r} />
        <span className="muted small nowrap code-ref-project" title={r.projectPath}>
          {r.kind === "external" ? "其他 GitLab" : r.projectName}
        </span>
      </div>
      <div className="code-ref-detail muted small">
        <Sources sources={r.sources} issueKey={issueKey} />
        {r.unavailable && <span>· {r.unavailable}</span>}
        {r.kind === "external" && <span>· 不在已配置的 GitLab 中，只能在浏览器中打开</span>}
        {r.kind === "branch" && r.commits.length === 0 && r.title && (
          <span className="ellipsis">
            · 最近提交：{r.title}
            {r.author && ` · ${r.author}`}
            {r.at && ` · ${formatTime(r.at)}`}
          </span>
        )}
        {r.kind !== "branch" && r.author && (
          <span className="nowrap">
            · {r.author}
            {r.at && ` · ${formatTime(r.at)}`}
          </span>
        )}
      </div>
      {r.kind === "branch" && commits.length > 0 && r.projectId && (
        <ul className="code-ref-commits">
          {commits.map((c) => (
            <BranchCommit key={c.id} commit={c} onOpen={() => navigate({ page: "gitlab", projectId: r.projectId!, commitSha: c.id })} />
          ))}
          {r.commits.length > COMMITS_SHOWN && (
            <li>
              <button className="link small" onClick={() => setExpanded((v) => !v)}>
                {expanded ? "收起" : `展开全部 ${r.commits.length} 个提交`}
              </button>
            </li>
          )}
        </ul>
      )}
    </li>
  );
}

function RefName({ item: r }: { item: CodeRef }) {
  if (r.kind === "mr")
    return (
      <>
        <span className="code-ref-id">!{r.iid}</span> {r.title || r.branch}
      </>
    );
  if (r.kind === "commit")
    return (
      <>
        <code>{r.sha?.slice(0, 8)}</code> {r.title}
      </>
    );
  if (r.kind === "branch") return <code>{r.branch}</code>;
  return <>{r.url.replace(/^https?:\/\//, "")}</>;
}

function RefState({ item: r }: { item: CodeRef }) {
  if (r.kind === "mr" && r.state) {
    const cls = r.state === "merged" ? "status-done" : r.state === "opened" ? "status-indeterminate" : "status-new";
    return (
      <>
        {r.pipeline && <span className={`pipeline-dot ${r.pipeline}`} title={PIPELINE_LABELS[r.pipeline] ?? r.pipeline} />}
        <span className={`status ${cls}`}>{STATE_LABELS[r.state] ?? r.state}</span>
      </>
    );
  }
  if (r.state === "merged") return <span className="tag muted-tag">已合并</span>;
  if (r.state === "missing") return <span className="tag muted-tag">{r.kind === "branch" ? "已删除" : "找不到"}</span>;
  return null;
}

const SOURCE_LABELS: Record<CodeRefSource["kind"], string> = {
  description: "描述中的链接",
  comment: "评论中的链接",
  mrSearch: "标题或描述含",
  commitSearch: "提交说明含",
};

/** 线索：哪条评论、标题含问题键等；评论可点击跳到原处。 */
function Sources({ sources, issueKey }: { sources: CodeRefSource[]; issueKey: string }) {
  const first = sources[0];
  if (!first) return null;
  const more = sources.length > 1 ? ` 等 ${sources.length} 处` : "";
  if (first.kind === "comment")
    return (
      <span className="nowrap">
        来自{" "}
        <button
          className="link"
          onClick={() => {
            const el = document.getElementById(`comment-${first.commentId}`);
            if (el) el.scrollIntoView({ behavior: "smooth", block: "center" });
            else toast("这条评论在下方「评论」标签中");
          }}
          title="跳到这条评论"
        >
          {first.author ?? "某人"} 的评论
        </button>
        {first.at && ` · ${formatTime(first.at)}`}
        {more}
      </span>
    );
  if (first.kind === "description") return <span className="nowrap">{SOURCE_LABELS.description + more}</span>;
  return (
    <span className="nowrap">
      {SOURCE_LABELS[first.kind]} {issueKey}
      {more}
    </span>
  );
}

function BranchCommit({ commit: c, onOpen }: { commit: Commit; onOpen: () => void }) {
  return (
    <li>
      <button className="code-ref-commit" onClick={onOpen} title={c.message || c.title}>
        <code>{c.shortId}</code>
        <span className="ellipsis grow">{c.title}</span>
        <span className="muted nowrap">
          {c.authorName} · {formatTime(c.authoredDate)}
        </span>
      </button>
    </li>
  );
}
