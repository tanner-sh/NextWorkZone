import { useEffect, useState, type ReactNode } from "react";
import { GitBranch, Link2, Plus, X } from "lucide-react";
import { api, errorMessage, type IssueChoice, type IssueDetail, type IssueRef, type LinkType } from "../../api";
import { ErrorBox, StatusPill, SysImg } from "../../components/common";
import { useMenus } from "../../components/MenuHost";
import { useNav } from "../../state/nav";
import { Picker } from "./fieldForm";

/** 在工作台内打开另一个问题。 */
function IssueRow({ issue, prefix, actions }: { issue: IssueRef; prefix?: string; actions?: ReactNode }) {
  const { navigate } = useNav();
  const menus = useMenus();
  return (
    <li className={menus.target === issue.key ? "menu-target" : undefined} onContextMenu={(e) => menus.open(e, menus.issue(issue), issue.key)}>
      {prefix && <span className="muted nowrap">{prefix}</span>}
      <SysImg service="jira" src={issue.issueType?.iconUrl} className="icon16" alt={issue.issueType?.name} />
      <button className="link nowrap" onClick={() => navigate({ page: "jira", issueKey: issue.key })}>
        {issue.key}
      </button>
      <span className="ellipsis grow">{issue.summary}</span>
      {issue.status && <StatusPill status={issue.status} />}
      {actions}
    </li>
  );
}

export function Subtasks({ issue, onCreate }: { issue: IssueDetail; onCreate: () => void }) {
  // 子任务下不能再建子任务
  if (issue.parent && issue.subtasks.length === 0) return null;
  const done = issue.subtasks.filter((s) => s.status?.category === "done").length;
  return (
    <section className="block">
      <div className="block-title">
        <h2>
          <GitBranch size={16} className="muted" />
          子任务 {issue.subtasks.length > 0 && <span className="count">{done}/{issue.subtasks.length}</span>}
        </h2>
        {!issue.parent && (
          <button className="btn" onClick={onCreate}>
            <Plus size={14} />
            新建子任务
          </button>
        )}
      </div>
      {issue.subtasks.length > 0 ? (
        <ul className="links">
          {issue.subtasks.map((s) => (
            <IssueRow key={s.key} issue={s} />
          ))}
        </ul>
      ) : (
        <p className="muted small">暂无子任务</p>
      )}
    </section>
  );
}

/** 链接关系：每种链接类型按方向拆成两种可选的关系。 */
interface Relation {
  id: string;
  typeId: string;
  outward: boolean;
  label: string;
}

export function Links({ issue, onChanged }: { issue: IssueDetail; onChanged: (detail: IssueDetail) => void }) {
  const [adding, setAdding] = useState(false);
  const [confirming, setConfirming] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const remove = async (linkId: string) => {
    setBusy(true);
    setError(null);
    try {
      onChanged(await api.jiraDeleteLink(issue.key, linkId));
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
      setConfirming(null);
    }
  };

  return (
    <section className="block">
      <div className="block-title">
        <h2>
          <Link2 size={16} className="muted" />
          关联问题 {issue.links.length > 0 && <span className="count">{issue.links.length}</span>}
        </h2>
        {!adding && (
          <button className="btn" onClick={() => setAdding(true)}>
            <Plus size={14} />
            添加链接
          </button>
        )}
      </div>
      {adding && (
        <LinkForm
          issueKey={issue.key}
          onCancel={() => setAdding(false)}
          onDone={(detail) => {
            setAdding(false);
            onChanged(detail);
          }}
        />
      )}
      {error && <ErrorBox message={error} />}
      {issue.links.length > 0 ? (
        <ul className="links">
          {issue.links.map((l) => (
            <IssueRow
              key={l.id}
              issue={l}
              prefix={l.relation}
              actions={
                confirming === l.id ? (
                  <span className="inline-confirm">
                    <button className="btn danger small-btn" disabled={busy} onClick={() => remove(l.id)}>
                      删除链接
                    </button>
                    <button className="btn small-btn" onClick={() => setConfirming(null)}>
                      取消
                    </button>
                  </span>
                ) : (
                  <button className="btn subtle icon" title="删除链接" onClick={() => setConfirming(l.id)}>
                    <X size={14} />
                  </button>
                )
              }
            />
          ))}
        </ul>
      ) : (
        !adding && <p className="muted small">暂无关联问题</p>
      )}
    </section>
  );
}

let linkTypesCache: LinkType[] | null = null;

function LinkForm({ issueKey, onCancel, onDone }: { issueKey: string; onCancel: () => void; onDone: (detail: IssueDetail) => void }) {
  const [types, setTypes] = useState<LinkType[] | null>(linkTypesCache);
  const [relation, setRelation] = useState<Relation | null>(null);
  const [targets, setTargets] = useState<IssueChoice[]>([]);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (linkTypesCache) return;
    api.jiraLinkTypes().then(
      (list) => {
        linkTypesCache = list;
        setTypes(list);
      },
      (e) => setError(errorMessage(e)),
    );
  }, []);

  const relations: Relation[] = (types ?? []).flatMap((t) => {
    const both: Relation[] = [{ id: `${t.id}:out`, typeId: t.id, outward: true, label: t.outward }];
    // 双向描述相同的类型（如“相关”）只列一次
    if (t.inward !== t.outward) both.push({ id: `${t.id}:in`, typeId: t.id, outward: false, label: t.inward });
    return both;
  });

  const save = async () => {
    if (!relation || targets.length === 0) return;
    setSaving(true);
    setError(null);
    try {
      let detail: IssueDetail | null = null;
      for (const target of targets) {
        detail = await api.jiraAddLink(issueKey, relation.typeId, target.key, relation.outward);
      }
      onDone(detail!);
    } catch (e) {
      setError(errorMessage(e));
      setSaving(false);
    }
  };

  return (
    <div className="inline-form">
      <div className="form-grid">
        <div className="form-field">
          <span>
            {issueKey} 的关系<em className="required">*</em>
          </span>
          <Picker<Relation>
            selected={relation ? [relation] : []}
            onChange={(list) => setRelation(list[0] ?? null)}
            search={(q) => relations.filter((r) => r.label.toLowerCase().includes(q.trim().toLowerCase()))}
            label={(r) => r.label}
            detail={(r) => types?.find((t) => t.id === r.typeId)?.name ?? ""}
            id={(r) => r.id}
            placeholder={types ? "搜索关系，例如“阻塞”" : "正在加载链接类型…"}
            searchOnFocus
          />
        </div>
        <div className="form-field">
          <span>
            问题<em className="required">*</em>
          </span>
          <Picker<IssueChoice>
            multiple
            selected={targets}
            onChange={setTargets}
            search={async (q) => {
              if (!q.trim()) return [];
              const found = await api.jiraPickIssues(q, null, false);
              return found.filter((i) => i.key !== issueKey).map((i) => ({ key: i.key, summary: i.summary }));
            }}
            label={(c) => c.key}
            detail={(c) => c.summary}
            id={(c) => c.key}
            placeholder="输入问题键或概要搜索"
          />
        </div>
      </div>
      {error && <ErrorBox message={error} />}
      <div className="composer-actions">
        <button className="btn" onClick={onCancel}>
          取消
        </button>
        <button className="btn primary" disabled={!relation || targets.length === 0 || saving} onClick={save}>
          {saving ? "添加中…" : "添加链接"}
        </button>
      </div>
    </div>
  );
}
