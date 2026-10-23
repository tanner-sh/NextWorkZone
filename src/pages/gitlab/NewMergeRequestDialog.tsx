import { useEffect, useMemo, useState } from "react";
import { GitPullRequestCreate } from "lucide-react";
import { api, errorMessage, type Branch, type Comparison, type MergeRequest, type Project } from "../../api";
import { ErrorBox, Modal } from "../../components/common";
import { issueKeysIn } from "../../lib/gitlabMarkdown";
import { useSettings } from "../../state/settings";

/**
 * 从自己最近的标题中学习团队的标题格式：问题号前的固定前缀（如 `KEY-1` 前面的标记）
 * 和多数标题共有的结尾（如审核标记）。没有明显规律时都为空。
 */
export function learnTitlePattern(titles: string[]): { prefix: string; suffix: string } {
  const prefixes = new Map<string, number>();
  for (const t of titles) {
    const key = issueKeysIn(t)[0];
    if (!key) continue;
    const prefix = t.slice(0, t.indexOf(key));
    if (prefix.length <= 15) prefixes.set(prefix, (prefixes.get(prefix) ?? 0) + 1);
  }
  const [prefix = ""] = [...prefixes.entries()].filter(([, n]) => n >= 2).sort((a, b) => b[1] - a[1])[0] ?? [];

  // 结尾：空白之后的一段文字，至少 3 个、且不少于四成的标题以它结尾
  const need = Math.max(3, Math.ceil(titles.length * 0.4));
  let suffix = "";
  for (const t of titles) {
    for (let i = 1; i < t.length; i++) {
      if (!/\s/.test(t[i - 1]) || /\s/.test(t[i])) continue;
      const tail = t.slice(i).trimEnd();
      if (tail.length < 2 || tail.length > 24 || tail.length <= suffix.trim().length) continue;
      const count = titles.filter((x) => x.trimEnd().endsWith(tail) && /\s/.test(x.trimEnd().slice(-tail.length - 1, -tail.length))).length;
      if (count >= need) {
        // 保留原标题中结尾前的空白
        const gap = t.slice(0, i).match(/\s+$/)?.[0] ?? " ";
        suffix = gap + tail;
      }
    }
  }
  return { prefix, suffix };
}

export function NewMergeRequestDialog({ project, branches, initialSource, onClose, onCreated }: { project: Project; branches: Branch[]; initialSource?: string; onClose: () => void; onCreated: (mr: MergeRequest) => void }) {
  const { isReady } = useSettings();
  const defaultBranch = project.defaultBranch ?? branches[0]?.name ?? "";
  // 受保护的分支（开发、发布主干）一般是目标而不是源，排在后面
  const candidates = useMemo(() => [...branches.filter((b) => !b.default && !b.protected), ...branches.filter((b) => !b.default && b.protected)], [branches]);
  const [source, setSource] = useState(initialSource && initialSource !== defaultBranch ? initialSource : candidates[0]?.name ?? "");
  const [target, setTarget] = useState(defaultBranch);
  const [targetTouched, setTargetTouched] = useState(false);
  const [compareError, setCompareError] = useState<string | null>(null);
  const [title, setTitle] = useState("");
  const [titleTouched, setTitleTouched] = useState(false);
  const [description, setDescription] = useState("");
  const [descTouched, setDescTouched] = useState(false);
  const [removeSource, setRemoveSource] = useState(project.removeSourceBranchAfterMerge ?? true);
  const [squash, setSquash] = useState(project.squashOption === "default_on" || project.squashOption === "always");
  const [compare, setCompare] = useState<Comparison | null>(null);
  const [existing, setExisting] = useState<MergeRequest | null>(null);
  const [pattern, setPattern] = useState<{ prefix: string; suffix: string } | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // 自己最近在这个项目里的合并请求：学习标题格式，目标分支默认用最常合并到的分支
  useEffect(() => {
    let cancelled = false;
    Promise.all([api.glMergeRequests("created_by_me", { state: "all" }), api.glProjectMergeRequests(project.id, { state: "all" })])
      .then(([allMine, recent]) => {
        if (cancelled) return;
        // 优先用这个项目里自己的；太少时用自己在所有项目里的（团队的标题格式通常一致）
        const here = allMine.filter((m) => m.projectId === project.id);
        const mine = (here.length >= 3 ? here : allMine).slice(0, 10);
        setPattern(learnTitlePattern(mine.map((m) => m.title)));
        const counts = new Map<string, number>();
        for (const m of here.length > 0 ? here : recent.slice(0, 20)) counts.set(m.targetBranch, (counts.get(m.targetBranch) ?? 0) + 1);
        const usual = [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([name]) => name).find((name) => branches.some((b) => b.name === name));
        if (usual && !targetTouched) {
          setTarget(usual);
          setSource((s) => (s === usual ? candidates.find((b) => b.name !== usual)?.name ?? "" : s));
        }
      })
      .catch(() => !cancelled && setPattern({ prefix: "", suffix: "" }));
    return () => {
      cancelled = true;
    };
  }, [project.id]);

  // 源分支的提交、是否已有打开的合并请求（等默认目标分支确定后再对比，避免先对比一次用不上的分支）
  const patternReady = pattern !== null;
  useEffect(() => {
    setCompare(null);
    setCompareError(null);
    setExisting(null);
    if (!patternReady || !source || !target || source === target) return;
    let cancelled = false;
    api.glCompare(project.id, target, source).then(
      (c) => !cancelled && setCompare(c),
      (e) => !cancelled && setCompareError(errorMessage(e)),
    );
    api.glProjectMergeRequests(project.id, { state: "opened", sourceBranch: source }).then((list) => !cancelled && setExisting(list[0] ?? null), () => {});
    return () => {
      cancelled = true;
    };
  }, [project.id, source, target, patternReady]);

  // 预填标题和描述：分支名里有问题号时用问题标题，否则用唯一提交的标题
  useEffect(() => {
    if (!compare || !pattern) return;
    let cancelled = false;
    const commits = compare.commits;
    if (!descTouched) {
      const only = commits.length === 1 ? commits[0].message.trim().split("\n").slice(1).join("\n").trim() : "";
      // 提交很多（通常是选错了分支）时不逐条列出
      setDescription(commits.length > 1 && commits.length <= 30 ? commits.map((c) => `- ${c.title}`).join("\n") : only);
    }
    if (titleTouched) return;
    const fallback = commits.length === 1 ? commits[0].title : source;
    setTitle(fallback);
    const key = issueKeysIn(source)[0];
    if (key && isReady("jira")) {
      api.jiraIssue(key).then(
        (issue) => !cancelled && setTitle(`${pattern.prefix}${key} ${issue.summary}${pattern.suffix}`),
        () => {},
      );
    } else if (key) {
      setTitle(`${pattern.prefix}${key} ${fallback}${pattern.suffix}`);
    }
    return () => {
      cancelled = true;
    };
    // 只在分支对比结果变化时重新预填
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [compare, pattern]);

  const submit = async () => {
    setSubmitting(true);
    setError(null);
    try {
      onCreated(await api.glMrCreate(project.id, { sourceBranch: source, targetBranch: target, title: title.trim(), description, removeSourceBranch: removeSource, squash }));
    } catch (e) {
      setError(errorMessage(e));
      setSubmitting(false);
    }
  };

  const noChanges = compare !== null && compare.commits.length === 0;
  const dirty = titleTouched || descTouched;

  return (
    <Modal
      title={`新建合并请求 · ${project.name}`}
      wide
      dirty={dirty}
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>
            取消
          </button>
          <button className="btn primary" disabled={submitting || !source || source === target || !title.trim() || !!existing || noChanges} onClick={submit}>
            <GitPullRequestCreate size={14} />
            {submitting ? "创建中…" : "创建"}
          </button>
        </>
      }
    >
      <div className="form-grid">
        <label className="form-field">
          <span>源分支</span>
          <select value={source} onChange={(e) => setSource(e.target.value)}>
            {candidates.length === 0 && <option value="">没有可用的分支</option>}
            {candidates.map((b) => (
              <option key={b.name} value={b.name}>
                {b.name}
              </option>
            ))}
          </select>
        </label>
        <label className="form-field">
          <span>目标分支</span>
          <select
            value={target}
            onChange={(e) => {
              setTarget(e.target.value);
              setTargetTouched(true);
            }}
          >
            {branches.filter((b) => b.name !== source).map((b) => (
              <option key={b.name} value={b.name}>
                {b.name}
              </option>
            ))}
          </select>
        </label>
      </div>
      <p className="muted small">
        {compareError
          ? `对比分支失败：${compareError}`
          : !compare
          ? source && source !== target
            ? "正在对比分支…"
            : ""
          : noChanges
            ? `「${source}」相对「${target}」没有新提交，无需合并。`
            : `${compare.commits.length} 个提交，${compare.diffs.length} 个文件有改动。`}
      </p>
      {existing && <ErrorBox message={`这个分支已经有打开的合并请求 !${existing.iid}：${existing.title}`} />}
      <label className="form-field">
        <span>标题</span>
        <input
          value={title}
          onChange={(e) => {
            setTitle(e.target.value);
            setTitleTouched(true);
          }}
        />
      </label>
      {pattern && (pattern.prefix || pattern.suffix) && !titleTouched && <p className="muted small">已按你最近的标题格式预填。</p>}
      <label className="form-field">
        <span>描述（Markdown）</span>
        <textarea
          rows={8}
          value={description}
          onChange={(e) => {
            setDescription(e.target.value);
            setDescTouched(true);
          }}
        />
      </label>
      <label className="checkbox">
        <input type="checkbox" checked={removeSource} onChange={(e) => setRemoveSource(e.target.checked)} />
        合并后删除源分支
      </label>
      {project.squashOption !== "never" && (
        <label className="checkbox">
          <input type="checkbox" checked={squash} disabled={project.squashOption === "always"} onChange={(e) => setSquash(e.target.checked)} />
          合并时压缩为一个提交（squash）
        </label>
      )}
      {error && <ErrorBox message={error} />}
    </Modal>
  );
}
