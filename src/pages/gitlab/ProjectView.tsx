import { useCallback, useEffect, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { api, errorMessage, type Branch, type Commit, type CommitDetail, type Comparison, type FileContent, type Project, type TreeEntry } from "../../api";
import { ArrowLeft, ChevronRight, CornerLeftUp, ExternalLink, FileCode2, Folder, GitBranch, GitCommitHorizontal, GitCompare, GitPullRequest, GitPullRequestCreate, Code2, Package, Search } from "lucide-react";
import { Avatar, ErrorBox, Skeleton, Spinner } from "../../components/common";
import { useMenus } from "../../components/MenuHost";
import { formatSize, formatTime } from "../../lib/format";
import { CodeView } from "./CodeView";
import { branchMenu, commitMenu, treeEntryMenu } from "./gitlabMenu";
import { DiffList } from "./DiffView";
import { MergeRequestView } from "./MergeRequestView";
import { MR_STATES, MrListBody, useMrList } from "./MrList";
import { NewMergeRequestDialog } from "./NewMergeRequestDialog";
import { RelatedIssues } from "./RelatedIssues";
import { toast } from "../../components/Toast";
import type { MrState } from "../../api";

type Tab = "code" | "mrs" | "commits" | "branches" | "compare";

/** 代码浏览的当前位置。 */
interface Location {
  path: string;
  isFile: boolean;
}

/**
 * `initialRef`：打开时显示的分支（可以是 tree/ 之后的路径，取其中最长的已有分支名）；
 * `initialCommit`：打开时显示的提交。
 */
export function ProjectView({ projectId, initialMr, initialRef, initialCommit }: { projectId: number; initialMr?: number; initialRef?: string; initialCommit?: string }) {
  const [project, setProject] = useState<Project | null>(null);
  const [branches, setBranches] = useState<Branch[]>([]);
  const [gitRef, setGitRef] = useState<string>("");
  const [tab, setTab] = useState<Tab>(initialMr ? "mrs" : initialRef || initialCommit ? "commits" : "code");
  /** 提交标签中打开的提交 */
  const [openCommit, setOpenCommit] = useState<string | null>(initialCommit ?? null);
  const [openMr, setOpenMr] = useState<number | null>(initialMr ?? null);
  /** 新建合并请求对话框（值为预选的源分支） */
  const [creating, setCreating] = useState<string | null>(null);
  const [location, setLocation] = useState<Location>({ path: "", isFile: false });
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    Promise.all([api.glProject(projectId), api.glBranches(projectId)])
      .then(([p, b]) => {
        if (cancelled) return;
        setProject(p);
        setBranches(b);
        const wanted = initialRef ? b.filter((x) => initialRef === x.name || initialRef.startsWith(`${x.name}/`)).sort((x, y) => y.name.length - x.name.length)[0] : undefined;
        if (initialRef && !wanted) toast(`分支 ${initialRef} 已不存在`, true);
        setGitRef(wanted?.name ?? p.defaultBranch ?? b[0]?.name ?? "");
      })
      .catch((e) => !cancelled && setError(errorMessage(e)));
    return () => {
      cancelled = true;
    };
    // 只在打开项目时应用一次
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId]);

  if (error) return <div className="detail-body"><ErrorBox message={error} /></div>;
  if (!project)
    return (
      <div className="detail-body">
        <Skeleton lines={2} height={22} />
        <Skeleton lines={10} />
      </div>
    );
  if (!gitRef) return <div className="detail-body"><p className="muted">这是一个空仓库。</p></div>;

  const openBranch = (name: string) => {
    setGitRef(name);
    setLocation({ path: "", isFile: false });
    setTab("code");
  };

  return (
    <div className="detail-body">
      <header className="issue-header">
        <div className="issue-header-top">
          <button className="link" onClick={() => openUrl(project.webUrl)} title="在浏览器中打开">
            {project.pathWithNamespace}
          </button>
          <ExternalLink size={12} />
        </div>
        <h1>{project.name}</h1>
        {project.description && <p className="muted">{project.description}</p>}
        <div className="issue-actions">
          <div className="segmented">
            {(
              [
                ["code", "代码", Code2],
                ["mrs", "合并请求", GitPullRequest],
                ["commits", "提交", GitCommitHorizontal],
                ["branches", `分支 ${branches.length}`, GitBranch],
                ["compare", "对比", GitCompare],
              ] as const
            ).map(([id, label, Icon]) => (
              <button
                key={id}
                className={tab === id ? "active" : ""}
                onClick={() => {
                  setTab(id);
                  if (id === "mrs") setOpenMr(null);
                  if (id === "commits") setOpenCommit(null);
                }}
              >
                <Icon size={14} />
                {label}
              </button>
            ))}
          </div>
          <span className="spacer" />
          {tab === "mrs" && !openMr && (
            <button className="btn primary" onClick={() => setCreating(gitRef !== project.defaultBranch ? gitRef : "")}>
              <GitPullRequestCreate size={14} />
              新建合并请求
            </button>
          )}
          {(tab === "code" || tab === "commits") && (
            <label className="ref-select">
              <GitBranch size={14} />
              <select value={gitRef} onChange={(e) => openBranch(e.target.value)}>
                {branches.map((b) => (
                  <option key={b.name} value={b.name}>
                    {b.name}
                  </option>
                ))}
              </select>
            </label>
          )}
        </div>
      </header>

      {tab === "code" && <CodeTab projectId={projectId} projectUrl={project.webUrl} gitRef={gitRef} location={location} onLocation={setLocation} />}
      {tab === "mrs" && (openMr ? <MergeRequestView key={openMr} mrRef={{ project: projectId, iid: openMr }} onBack={() => setOpenMr(null)} /> : <ProjectMrsTab projectId={projectId} onOpen={setOpenMr} />)}
      {tab === "commits" &&
        (openCommit ? (
          <CommitDetailView projectId={projectId} projectPath={project.pathWithNamespace} sha={openCommit} onBack={() => setOpenCommit(null)} />
        ) : (
          <>
            {gitRef !== project.defaultBranch && <RelatedIssues target={{ projectPath: project.pathWithNamespace, branch: gitRef, text: gitRef }} />}
            <CommitsTab projectId={projectId} gitRef={gitRef} onOpen={setOpenCommit} />
          </>
        ))}
      {tab === "branches" && <BranchesTab branches={branches} projectUrl={project.webUrl} onOpen={openBranch} onCreateMr={(name) => setCreating(name)} />}
      {tab === "compare" && <CompareTab projectId={projectId} branches={branches} defaultBranch={project.defaultBranch ?? ""} />}
      {creating !== null && (
        <NewMergeRequestDialog
          project={project}
          branches={branches}
          initialSource={creating || undefined}
          onClose={() => setCreating(null)}
          onCreated={(mr) => {
            setCreating(null);
            setTab("mrs");
            setOpenMr(mr.iid);
          }}
        />
      )}
    </div>
  );
}

function Breadcrumb({ path, onPath, root }: { path: string; onPath: (p: string) => void; root: string }) {
  const parts = path ? path.split("/") : [];
  return (
    <nav className="breadcrumb">
      <button className="link" onClick={() => onPath("")}>
        {root}
      </button>
      {parts.map((part, i) => (
        <span key={i} className="breadcrumb">
          <ChevronRight size={13} className="sep" />
          {i === parts.length - 1 ? <strong>{part}</strong> : <button className="link" onClick={() => onPath(parts.slice(0, i + 1).join("/"))}>{part}</button>}
        </span>
      ))}
    </nav>
  );
}

/** 代码浏览：`path` 为目录时列出内容，为文件时显示文件。 */
function CodeTab({ projectId, projectUrl, gitRef, location, onLocation }: { projectId: number; projectUrl: string; gitRef: string; location: Location; onLocation: (l: Location) => void }) {
  const { path, isFile } = location;
  const menus = useMenus();
  const [entries, setEntries] = useState<TreeEntry[] | null>(null);
  const [file, setFile] = useState<FileContent | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setError(null);
    setEntries(null);
    setFile(null);
    const request = isFile ? api.glFile(projectId, gitRef, path).then((f) => !cancelled && setFile(f)) : api.glTree(projectId, gitRef, path).then((t) => !cancelled && setEntries(t));
    request.catch((e) => !cancelled && setError(errorMessage(e)));
    return () => {
      cancelled = true;
    };
  }, [projectId, gitRef, path, isFile]);

  const go = (target: string, targetIsFile: boolean) => onLocation({ path: target, isFile: targetIsFile });

  return (
    <section className="block">
      <Breadcrumb path={path} root={gitRef} onPath={(p) => go(p, false)} />
      {error && <ErrorBox message={error} />}
      {!error && !isFile && !entries && <Spinner />}
      {entries && (
        <ul className="tree">
          {path && (
            <li>
              <button className="tree-item" onClick={() => go(path.split("/").slice(0, -1).join("/"), false)}>
                <CornerLeftUp size={15} />..
              </button>
            </li>
          )}
          {entries.map((e) => (
            <li key={e.path}>
              <button
                className={`tree-item${menus.target === e.path ? " menu-target" : ""}`}
                onClick={() => e.kind !== "commit" && go(e.path, e.kind === "blob")}
                onContextMenu={(ev) => menus.open(ev, treeEntryMenu(e, projectUrl, gitRef, () => go(e.path, e.kind === "blob")), e.path)}
                disabled={e.kind === "commit"}
              >
                {e.kind === "tree" ? <Folder size={15} className="dir-icon" fill="currentColor" fillOpacity={0.15} /> : e.kind === "commit" ? <Package size={15} /> : <FileCode2 size={15} />}
                <span className={e.kind === "tree" ? "dir" : ""}>{e.name}</span>
              </button>
            </li>
          ))}
          {entries.length === 0 && <li className="muted list-empty">空目录</li>}
        </ul>
      )}
      {isFile && !file && !error && <Spinner />}
      {file && <FileBody file={file} />}
    </section>
  );
}

function FileBody({ file }: { file: FileContent }) {
  if (file.tooLarge) return <p className="muted">文件过大（{formatSize(file.size)}），请在浏览器中查看。</p>;
  if (file.imageDataUrl) return <img className="file-image" src={file.imageDataUrl} alt={file.path} />;
  if (file.binary || file.text === null) return <p className="muted">二进制文件（{formatSize(file.size)}），无法预览。</p>;
  return <CodeView code={file.text} path={file.path} />;
}

function CommitsTab({ projectId, gitRef, onOpen }: { projectId: number; gitRef: string; onOpen: (sha: string) => void }) {
  const [commits, setCommits] = useState<Commit[]>([]);
  const [page, setPage] = useState(1);
  const [hasMore, setHasMore] = useState(true);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadPage = useCallback(
    async (p: number) => {
      setLoading(true);
      setError(null);
      try {
        const list = await api.glCommits(projectId, gitRef, null, p);
        setCommits((old) => (p === 1 ? list : [...old, ...list]));
        setHasMore(list.length === 50);
        setPage(p);
      } catch (e) {
        setError(errorMessage(e));
      } finally {
        setLoading(false);
      }
    },
    [projectId, gitRef],
  );

  useEffect(() => {
    void loadPage(1);
  }, [loadPage]);

  return (
    <section className="block">
      {error && <ErrorBox message={error} />}
      <CommitList commits={commits} onOpen={onOpen} />
      {hasMore && commits.length > 0 && (
        <button className="btn" onClick={() => loadPage(page + 1)} disabled={loading}>
          {loading ? "加载中…" : "加载更多"}
        </button>
      )}
      {loading && commits.length === 0 && <Spinner />}
    </section>
  );
}

export function CommitList({ commits, onOpen }: { commits: Commit[]; onOpen: (sha: string) => void }) {
  const menus = useMenus();
  return (
    <ul className="commits">
      {commits.map((c) => (
        <li key={c.id}>
          <button className={`commit-item${menus.target === c.id ? " menu-target" : ""}`} onClick={() => onOpen(c.id)} onContextMenu={(e) => menus.open(e, commitMenu(c, () => onOpen(c.id)), c.id)}>
            <Avatar name={c.authorName} size={26} />
            <span className="commit-text">
              <span className="commit-title ellipsis">{c.title}</span>
              <span className="muted small">
                {c.authorName} · {formatTime(c.authoredDate)}
              </span>
            </span>
            <code>{c.shortId}</code>
          </button>
        </li>
      ))}
    </ul>
  );
}

/** `projectPath` 有值时显示提到这个提交的问题。 */
export function CommitDetailView({ projectId, projectPath, sha, onBack }: { projectId: number; projectPath?: string; sha: string; onBack: () => void }) {
  const [detail, setDetail] = useState<CommitDetail | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api.glCommit(projectId, sha).then(setDetail, (e) => setError(errorMessage(e)));
  }, [projectId, sha]);

  return (
    <section className="block">
      <button className="btn subtle" onClick={onBack} style={{ alignSelf: "flex-start" }}>
        <ArrowLeft size={14} />
        返回
      </button>
      {error && <ErrorBox message={error} />}
      {!detail && !error && <Spinner />}
      {detail && (
        <>
          <div className="commit-head">
            <h2>{detail.commit.title}</h2>
            <p className="muted small">
              {detail.commit.authorName} · {formatTime(detail.commit.authoredDate)} · <code>{detail.commit.shortId}</code>
              {detail.commit.webUrl && (
                <>
                  {" "}
                  ·{" "}
                  <button className="link" onClick={() => openUrl(detail.commit.webUrl!)}>
                    在浏览器中打开
                  </button>
                </>
              )}
            </p>
            {detail.commit.message.trim() !== detail.commit.title.trim() && <pre className="commit-message">{detail.commit.message.trim()}</pre>}
          </div>
          {projectPath && <RelatedIssues target={{ projectPath, sha: detail.commit.id, text: detail.commit.message || detail.commit.title }} />}
          <DiffList diffs={detail.diffs} />
        </>
      )}
    </section>
  );
}

function ProjectMrsTab({ projectId, onOpen }: { projectId: number; onOpen: (iid: number) => void }) {
  const [state, setState] = useState<MrState>("opened");
  const [input, setInput] = useState("");
  const [search, setSearch] = useState("");
  const list = useMrList({ project: projectId }, state, search);
  return (
    <section className="block">
      <div className="compare-bar">
        <div className="segmented small-seg">
          {MR_STATES.map(([id, label]) => (
            <button key={id} className={state === id ? "active" : ""} onClick={() => setState(id)}>
              {label}
            </button>
          ))}
        </div>
        <form
          className="input-icon"
          onSubmit={(e) => {
            e.preventDefault();
            setSearch(input.trim());
          }}
        >
          <Search size={14} />
          <input value={input} placeholder="搜索标题、描述，回车" onChange={(e) => setInput(e.target.value)} />
        </form>
      </div>
      <div className="project-mrs">
        <MrListBody list={list} selected={null} showProject={false} onOpen={(mr) => onOpen(mr.iid)} empty="没有符合条件的合并请求" />
      </div>
    </section>
  );
}

function BranchesTab({ branches, projectUrl, onOpen, onCreateMr }: { branches: Branch[]; projectUrl: string; onOpen: (name: string) => void; onCreateMr: (name: string) => void }) {
  const menus = useMenus();
  const [filter, setFilter] = useState("");
  const visible = branches.filter((b) => b.name.toLowerCase().includes(filter.trim().toLowerCase()));
  return (
    <section className="block">
      <input value={filter} placeholder="筛选分支" onChange={(e) => setFilter(e.target.value)} style={{ maxWidth: 320 }} />
      <ul className="commits">
        {visible.map((b) => (
          <li key={b.name}>
            <button
              className={`commit-item${menus.target === `branch:${b.name}` ? " menu-target" : ""}`}
              onClick={() => onOpen(b.name)}
              onContextMenu={(e) => menus.open(e, branchMenu(b, projectUrl, { onOpen: () => onOpen(b.name), onCreateMr: !b.default && !b.merged ? () => onCreateMr(b.name) : undefined }), `branch:${b.name}`)}
            >
              <GitBranch size={15} className="muted" />
              <span className="commit-text">
              <span className="commit-title">
                {b.name}
                {b.default && <span className="tag">默认</span>}
                {b.protected && <span className="tag">保护</span>}
                {b.merged && <span className="tag muted-tag">已合并</span>}
              </span>
              <span className="muted small ellipsis">
                {b.commit.title} · {b.commit.authorName} · {formatTime(b.commit.authoredDate)}
              </span>
              </span>
              {!b.default && !b.merged && (
                <span
                  className="btn subtle small-btn branch-mr"
                  role="button"
                  tabIndex={0}
                  title="以这个分支发起合并请求"
                  onClick={(e) => {
                    e.stopPropagation();
                    onCreateMr(b.name);
                  }}
                >
                  <GitPullRequestCreate size={13} />
                  发起合并请求
                </span>
              )}
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}

function CompareTab({ projectId, branches, defaultBranch }: { projectId: number; branches: Branch[]; defaultBranch: string }) {
  const [from, setFrom] = useState(defaultBranch);
  const [to, setTo] = useState(branches.find((b) => b.name !== defaultBranch)?.name ?? defaultBranch);
  const [result, setResult] = useState<Comparison | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<string | null>(null);

  const compare = async () => {
    setLoading(true);
    setError(null);
    setResult(null);
    try {
      setResult(await api.glCompare(projectId, from, to));
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setLoading(false);
    }
  };

  if (selected) return <CommitDetailView projectId={projectId} sha={selected} onBack={() => setSelected(null)} />;

  const select = (value: string, onChange: (v: string) => void) => (
    <select value={value} onChange={(e) => onChange(e.target.value)}>
      {branches.map((b) => (
        <option key={b.name} value={b.name}>
          {b.name}
        </option>
      ))}
    </select>
  );

  return (
    <section className="block">
      <div className="compare-bar">
        {select(from, setFrom)}
        <span className="muted">…</span>
        {select(to, setTo)}
        <button className="btn primary" onClick={compare} disabled={loading || from === to}>
          {loading ? "对比中…" : "对比"}
        </button>
      </div>
      <p className="muted small">显示从「{from}」到「{to}」新增的提交与改动。</p>
      {error && <ErrorBox message={error} />}
      {result && (
        <>
          <h2>提交 ({result.commits.length})</h2>
          {result.commits.length === 0 ? <p className="muted">没有差异。</p> : <CommitList commits={result.commits} onOpen={setSelected} />}
          {result.diffs.length > 0 && (
            <>
              <h2>改动文件 ({result.diffs.length})</h2>
              <DiffList diffs={result.diffs} />
            </>
          )}
        </>
      )}
    </section>
  );
}
