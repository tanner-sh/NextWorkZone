import { useEffect, useState } from "react";
import { TicketCheck } from "lucide-react";
import { api, type CodeTarget, type RelatedIssue } from "../../api";
import { StatusPill, SysImg } from "../../components/common";
import { useMenus } from "../../components/MenuHost";
import { useNav } from "../../state/nav";
import { useSettings } from "../../state/settings";

/** 提到这个分支、提交或合并请求的 Jira 问题：标题等中的问题键，以及问题中链接了它的。没有时不显示。 */
export function RelatedIssues({ target }: { target: CodeTarget }) {
  const { isReady } = useSettings();
  const { navigate } = useNav();
  const menus = useMenus();
  const [issues, setIssues] = useState<RelatedIssue[] | null>(null);
  const ready = isReady("jira");
  const { projectPath, branch, sha, iid, text } = target;

  useEffect(() => {
    if (!ready) return;
    let alive = true;
    setIssues(null);
    api.codeRelatedIssues({ projectPath, branch, sha, iid, text }).then(
      (list) => alive && setIssues(list),
      () => alive && setIssues([]),
    );
    return () => {
      alive = false;
    };
  }, [ready, projectPath, branch, sha, iid, text]);

  if (!ready || !issues || issues.length === 0) return null;
  return (
    <section className="block related-issues">
      <h2>
        <TicketCheck size={16} className="muted" />
        相关问题 <span className="count">{issues.length}</span>
      </h2>
      <ul className="links">
        {issues.map((i) => (
          <li
            key={i.key}
            className={`clickable${menus.target === i.key ? " menu-target" : ""}`}
            onClick={() => navigate({ page: "jira", issueKey: i.key })}
            onContextMenu={(e) => menus.open(e, menus.issue(i), i.key)}
          >
            <SysImg service="jira" src={i.issueType.iconUrl} className="icon16" />
            <span className="issue-key nowrap">{i.key}</span>
            <span className="ellipsis grow" title={i.snippet?.text ?? i.summary}>
              {i.summary}
            </span>
            <span className="muted small nowrap">{i.via === "key" ? "提到问题键" : i.snippet?.author ? `${i.snippet.author} 的评论中链接了它` : "问题中链接了它"}</span>
            <StatusPill status={i.status} />
          </li>
        ))}
      </ul>
    </section>
  );
}
