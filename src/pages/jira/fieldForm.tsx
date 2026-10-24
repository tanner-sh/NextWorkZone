// 编辑、创建、流转界面共用的字段表单：按字段类型生成控件，并把表单取值转换为 Jira REST API 的格式。
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { X } from "lucide-react";
import {
  api,
  type FieldMeta,
  type FieldOption,
  type FieldValue,
  type IssueChoice,
  type TimeTrackingValue,
  type UserRef,
} from "../../api";
import { usePageActive } from "../../state/nav";
import { WikiEditor, type PendingImage } from "./wiki/WikiEditor";

export type Values = Record<string, FieldValue>;

/** 搜索用户、问题时需要的上下文：编辑时是当前问题，创建时是所选项目。 */
export interface FieldContext {
  issueKey: string | null;
  projectKey: string | null;
  /** 在多行文本中粘贴了图片 */
  onImage?: (image: PendingImage) => void;
}

/** 占满整行的字段类型 */
const FULL_WIDTH: FieldMeta["kind"][] = ["textarea", "multiselect", "multiuser", "labels", "timetracking"];

export function initialValues(fields: FieldMeta[]): Values {
  return Object.fromEntries(fields.map((f) => [f.key, f.value]));
}

export function isEmpty(value: FieldValue | undefined): boolean {
  if (value === null || value === undefined) return true;
  if (typeof value === "string") return value.trim() === "";
  if (Array.isArray(value)) return value.length === 0;
  if ("key" in value) return !(value as IssueChoice).key;
  if ("name" in value) return !(value as UserRef).name;
  return Object.values(value).every((v) => !v || !String(v).trim());
}

/** 可以在工作台中填写的字段；不支持的可选字段（多为插件自动计算的字段）不显示。 */
export function editableFields(fields: FieldMeta[]): FieldMeta[] {
  return fields.filter((f) => f.kind !== "unsupported");
}

export function missingRequired(fields: FieldMeta[], values: Values): FieldMeta[] {
  return editableFields(fields).filter((f) => f.required && isEmpty(values[f.key]));
}

export function unsupportedRequired(fields: FieldMeta[]): FieldMeta[] {
  return fields.filter((f) => f.required && f.kind === "unsupported");
}

/**
 * 按 Jira REST API 的要求构造字段取值。
 * 传入 `initial`（编辑时的原值）时只包含有变化的字段，被清空的字段显式置空；否则跳过空字段。
 */
export function toPayload(fields: FieldMeta[], values: Values, initial?: Values): Record<string, unknown> {
  const payload: Record<string, unknown> = {};
  for (const field of editableFields(fields)) {
    const value = values[field.key];
    const before = initial?.[field.key];
    if (initial && sameValue(value, before)) continue;
    if (isEmpty(value)) {
      if (initial && !isEmpty(before)) payload[field.key] = emptyValue(field);
      continue;
    }
    if (field.kind === "timetracking" && initial) {
      // 只提交改过的估算：未改动的值可能是本地化格式（如“1小时”），回传会被拒绝
      const now = value as TimeTrackingValue;
      const old = (before ?? {}) as TimeTrackingValue;
      const changed: TimeTrackingValue = {};
      if ((now.originalEstimate ?? "") !== (old.originalEstimate ?? "")) changed.originalEstimate = now.originalEstimate ?? "";
      if ((now.remainingEstimate ?? "") !== (old.remainingEstimate ?? "")) changed.remainingEstimate = now.remainingEstimate ?? "";
      payload[field.key] = changed;
      continue;
    }
    payload[field.key] = jiraValue(field, value as Exclude<FieldValue, null>);
  }
  return payload;
}

function jiraValue(field: FieldMeta, value: Exclude<FieldValue, null>): unknown {
  switch (field.kind) {
    case "number":
      return Number(value);
    case "datetime":
      return toJiraDateTime(value as string);
    case "select":
      return { id: value };
    case "multiselect":
      return (value as string[]).map((id) => ({ id }));
    case "cascading": {
      const [parent, child] = value as string[];
      return child ? { id: parent, child: { id: child } } : { id: parent };
    }
    case "user":
      return { name: (value as UserRef).name };
    case "multiuser":
      return (value as UserRef[]).map((u) => ({ name: u.name }));
    case "epic":
      return (value as IssueChoice).key;
    case "parent":
      return { key: (value as IssueChoice).key };
    case "timetracking": {
      const tt = value as TimeTrackingValue;
      return Object.fromEntries(Object.entries(tt).filter(([, v]) => v && v.trim()));
    }
    default:
      return value;
  }
}

function emptyValue(field: FieldMeta): unknown {
  return ["multiselect", "multiuser", "labels"].includes(field.kind) ? [] : null;
}

function sameValue(a: FieldValue | undefined, b: FieldValue | undefined): boolean {
  if (isEmpty(a) && isEmpty(b)) return true;
  return JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
}

/** `2026-10-22T09:30`（本地时间）→ `2026-10-22T09:30:00.000+0800` */
export function toJiraDateTime(local: string): string {
  const date = new Date(local);
  const offset = -date.getTimezoneOffset();
  const sign = offset >= 0 ? "+" : "-";
  const abs = Math.abs(offset);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${local.slice(0, 16)}:00.000${sign}${pad(Math.floor(abs / 60))}${pad(abs % 60)}`;
}

/** 把 Jira 错误信息中的字段 id（如 customfield_10002）替换为字段名称。 */
export function explainError(message: string, fields: FieldMeta[]): string {
  return fields.reduce((text, f) => text.split(`${f.key}：`).join(`${f.name}：`), message);
}

// ---------- 表单 ----------

export function FieldList(props: { fields: FieldMeta[]; values: Values; onChange: (key: string, value: FieldValue) => void; context: FieldContext }) {
  return (
    <div className="form-grid">
      {editableFields(props.fields).map((field) => (
        <div className={`form-field${FULL_WIDTH.includes(field.kind) ? " full" : ""}`} key={field.key}>
          <span>
            {field.name}
            {field.required && <em className="required">*</em>}
          </span>
          <FieldInput field={field} value={props.values[field.key] ?? null} onChange={(v) => props.onChange(field.key, v)} context={props.context} />
        </div>
      ))}
    </div>
  );
}

export function FieldInput({ field, value, onChange, context }: { field: FieldMeta; value: FieldValue; onChange: (v: FieldValue) => void; context: FieldContext }) {
  const str = typeof value === "string" ? value : "";
  switch (field.kind) {
    case "text":
      return <input value={str} onChange={(e) => onChange(e.target.value)} />;
    case "textarea":
      return <WikiEditor value={str} onChange={(v) => onChange(v)} issueKey={context.issueKey} onImage={context.onImage} minHeight={field.key === "description" ? 180 : 80} />;
    case "number":
      return <input type="number" value={str} onChange={(e) => onChange(e.target.value)} />;
    case "date":
      return <input type="date" value={str} onChange={(e) => onChange(e.target.value)} />;
    case "datetime":
      return <input type="datetime-local" value={str} onChange={(e) => onChange(e.target.value)} />;
    case "select":
      return <OptionSelect options={field.options} value={str || null} onChange={(id) => onChange(id)} />;
    case "multiselect": {
      const ids = (value as string[] | null) ?? [];
      const byId = new Map(field.options.map((o) => [o.id, o]));
      return (
        <Picker<FieldOption>
          multiple
          selected={ids.map((id) => byId.get(id) ?? { id, name: id, disabled: true })}
          onChange={(list) => onChange(list.map((o) => o.id))}
          search={(q) => field.options.filter((o) => !o.disabled && matches(o.name, q))}
          label={(o) => o.name}
          id={(o) => o.id}
        />
      );
    }
    case "cascading": {
      const [parentId, childId] = (value as string[] | null) ?? [];
      const parent = field.options.find((o) => o.id === parentId);
      return (
        <div className="cascading">
          <OptionSelect options={field.options} value={parentId ?? null} onChange={(id) => onChange(id ? [id] : null)} />
          {parent?.children && parent.children.length > 0 && (
            <OptionSelect options={parent.children} value={childId ?? null} onChange={(id) => onChange(id ? [parentId, id] : [parentId])} />
          )}
        </div>
      );
    }
    case "user":
    case "multiuser": {
      const users = field.kind === "user" ? (value ? [value as UserRef] : []) : ((value as UserRef[] | null) ?? []);
      return (
        <Picker<UserRef>
          multiple={field.kind === "multiuser"}
          selected={users}
          onChange={(list) => onChange(field.kind === "user" ? (list[0] ?? null) : list)}
          search={(q) => (q.trim() ? api.jiraFindUsers(q.trim(), field.key, context.issueKey, context.projectKey) : [])}
          label={(u) => u.displayName}
          detail={(u) => u.name}
          id={(u) => u.name}
          placeholder="输入姓名或用户名搜索"
        />
      );
    }
    case "labels":
      return (
        <Picker<string>
          multiple
          selected={(value as string[] | null) ?? []}
          onChange={(list) => onChange(list)}
          search={(q) => api.jiraSuggestLabels(q.trim())}
          create={(q) => (q.trim() && !/\s/.test(q.trim()) ? q.trim() : null)}
          label={(l) => l}
          id={(l) => l}
          placeholder="输入标签，回车添加（不能含空格）"
        />
      );
    case "timetracking": {
      const tt = (value as TimeTrackingValue | null) ?? {};
      const set = (k: keyof TimeTrackingValue, v: string) => onChange({ ...tt, [k]: v });
      return (
        <div className="cascading">
          <input value={tt.originalEstimate ?? ""} placeholder="初始估算，例如 2d 4h" onChange={(e) => set("originalEstimate", e.target.value)} />
          <input value={tt.remainingEstimate ?? ""} placeholder="剩余估算，例如 1d" onChange={(e) => set("remainingEstimate", e.target.value)} />
        </div>
      );
    }
    case "epic":
    case "parent": {
      const choice = value as IssueChoice | null;
      return (
        <Picker<IssueChoice>
          selected={choice ? [choice] : []}
          onChange={(list) => onChange(list[0] ?? null)}
          search={async (q) => {
            if (field.kind === "epic") return context.projectKey ? api.jiraSearchEpics(q.trim(), context.projectKey) : [];
            if (!q.trim()) return [];
            const issues = await api.jiraPickIssues(q, context.projectKey, true);
            return issues.map((i) => ({ key: i.key, summary: i.summary }));
          }}
          label={(c) => (c.summary ? `${c.key} ${c.summary}` : c.key)}
          id={(c) => c.key}
          placeholder={field.kind === "epic" ? "搜索 Epic 名称" : "输入问题键或概要搜索"}
          searchOnFocus={field.kind === "epic"}
        />
      );
    }
    default:
      return null;
  }
}

function matches(text: string, query: string): boolean {
  return text.toLowerCase().includes(query.trim().toLowerCase());
}

/** 单选：选项少时用原生下拉框，选项多时用可搜索的选择器。 */
function OptionSelect({ options, value, onChange }: { options: FieldOption[]; value: string | null; onChange: (id: string | null) => void }) {
  const visible = options.filter((o) => !o.disabled || o.id === value);
  if (visible.length <= 12) {
    return (
      <select value={value ?? ""} onChange={(e) => onChange(e.target.value || null)}>
        <option value="">请选择</option>
        {visible.map((o) => (
          <option key={o.id} value={o.id}>
            {o.name}
          </option>
        ))}
      </select>
    );
  }
  const selected = options.find((o) => o.id === value);
  return (
    <Picker<FieldOption>
      selected={selected ? [selected] : []}
      onChange={(list) => onChange(list[0]?.id ?? null)}
      search={(q) => visible.filter((o) => !o.disabled && matches(o.name, q))}
      label={(o) => o.name}
      id={(o) => o.id}
      searchOnFocus
    />
  );
}

// ---------- 通用选择器 ----------

interface PickerProps<T> {
  multiple?: boolean;
  selected: T[];
  onChange: (selected: T[]) => void;
  /** 返回候选项；可以是同步过滤，也可以是异步搜索。 */
  search: (query: string) => T[] | Promise<T[]>;
  label: (item: T) => string;
  detail?: (item: T) => string;
  id: (item: T) => string;
  /** 允许直接添加输入的内容（例如新标签）。 */
  create?: (query: string) => T | null;
  placeholder?: string;
  /** 获得焦点时即显示候选项（不输入也搜索）。 */
  searchOnFocus?: boolean;
  /** 未输入时候选列表上方的标题（如“建议”）。 */
  idleHeading?: string;
}

/** 带搜索的单选 / 多选控件：已选项显示为标签，输入时在下方列出候选项。 */
export function Picker<T>(props: PickerProps<T>) {
  const { multiple = false, selected, onChange, search, label, detail, id, create } = props;
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(false);
  const [results, setResults] = useState<T[]>([]);
  const [loading, setLoading] = useState(false);
  const [active, setActive] = useState(0);
  // 候选列表放在 body 下，所在页面隐藏时要自己隐藏
  const pageActive = usePageActive();
  const requestId = useRef(0);
  const boxRef = useRef<HTMLDivElement>(null);
  const [menuStyle, setMenuStyle] = useState<CSSProperties>({});
  const searchRef = useRef(search);
  searchRef.current = search;

  useEffect(() => {
    if (!open) return;
    if (!query.trim() && !props.searchOnFocus) {
      setResults([]);
      return;
    }
    const current = ++requestId.current;
    const run = async () => {
      setLoading(true);
      try {
        const found = await searchRef.current(query);
        if (current === requestId.current) {
          setResults(found.slice(0, 50));
          setActive(0);
        }
      } catch {
        if (current === requestId.current) setResults([]);
      } finally {
        if (current === requestId.current) setLoading(false);
      }
    };
    // 同步过滤立即执行，远程搜索稍作防抖
    const timer = setTimeout(run, query ? 250 : 0);
    return () => clearTimeout(timer);
  }, [query, open, props.searchOnFocus]);

  const selectedIds = useMemo(() => new Set(selected.map(id)), [selected, id]);
  const candidates = results.filter((r) => !selectedIds.has(id(r)));
  const created = create?.(query) ?? null;
  const showCreate = created !== null && !candidates.some((c) => id(c) === id(created)) && !selectedIds.has(id(created));
  const items: { item: T; isNew: boolean }[] = [...candidates.map((item) => ({ item, isNew: false })), ...(showCreate ? [{ item: created!, isNew: true }] : [])];

  // 候选列表挂到 body 上并按输入框位置固定定位，避免被对话框等可滚动容器裁掉；下方空间不够时向上展开
  useLayoutEffect(() => {
    if (!open) return;
    const place = () => {
      const rect = boxRef.current?.getBoundingClientRect();
      if (!rect) return;
      const below = window.innerHeight - rect.bottom - 12;
      const above = rect.top - 12;
      const up = below < 160 && above > below;
      setMenuStyle({
        left: rect.left,
        width: rect.width,
        maxHeight: Math.min(240, up ? above : below),
        ...(up ? { bottom: window.innerHeight - rect.top + 4 } : { top: rect.bottom + 4 }),
      });
    };
    place();
    window.addEventListener("resize", place);
    window.addEventListener("scroll", place, true);
    return () => {
      window.removeEventListener("resize", place);
      window.removeEventListener("scroll", place, true);
    };
  }, [open, selected.length]);

  const pick = (item: T) => {
    onChange(multiple ? [...selected, item] : [item]);
    setQuery("");
    if (!multiple) setOpen(false);
  };
  const remove = (item: T) => onChange(selected.filter((s) => id(s) !== id(item)));

  return (
    <div className={`picker${open ? " open" : ""}`}>
      <div className="picker-box" ref={boxRef}>
        {multiple &&
          selected.map((item) => (
            <span className="chip" key={id(item)}>
              {label(item)}
              <button type="button" onClick={() => remove(item)} aria-label={`移除 ${label(item)}`}>
                <X size={11} />
              </button>
            </span>
          ))}
        <input
          value={!multiple && !open && selected[0] ? label(selected[0]) : query}
          placeholder={selected.length > 0 && multiple ? "" : (props.placeholder ?? "输入以搜索")}
          onFocus={() => setOpen(true)}
          onBlur={() => setTimeout(() => setOpen(false), 150)}
          onChange={(e) => {
            setQuery(e.target.value);
            setOpen(true);
          }}
          onKeyDown={(e) => {
            if (e.key === "ArrowDown") {
              e.preventDefault();
              setActive((i) => Math.min(i + 1, items.length - 1));
            } else if (e.key === "ArrowUp") {
              e.preventDefault();
              setActive((i) => Math.max(i - 1, 0));
            } else if (e.key === "Enter") {
              e.preventDefault();
              const target = items[active] ?? items[0];
              if (target) pick(target.item);
            } else if (e.key === "Backspace" && !query && multiple && selected.length > 0) {
              remove(selected[selected.length - 1]);
            } else if (e.key === "Escape" && open) {
              // 先收起候选列表，不关闭所在的对话框
              e.preventDefault();
              setOpen(false);
            }
          }}
        />
        {!multiple && selected[0] && (
          <button type="button" className="picker-clear" onClick={() => onChange([])} aria-label="清除">
            <X size={13} />
          </button>
        )}
      </div>
      {open && pageActive && (items.length > 0 || loading || query.trim()) && createPortal(
        <ul className="picker-menu" style={menuStyle} onMouseDown={(e) => e.preventDefault()}>
          {props.idleHeading && !query.trim() && items.length > 0 && <li className="picker-heading">{props.idleHeading}</li>}
          {items.map(({ item, isNew }, i) => (
            <li key={`${isNew ? "new:" : ""}${id(item)}`}>
              <button type="button" className={i === active ? "active" : ""} onMouseDown={(e) => e.preventDefault()} onClick={() => pick(item)} onMouseEnter={() => setActive(i)}>
                {isNew ? <span className="muted">添加“{label(item)}”</span> : label(item)}
                {!isNew && detail && <span className="muted small">{detail(item)}</span>}
              </button>
            </li>
          ))}
          {loading && items.length === 0 && <li className="picker-empty muted small">搜索中…</li>}
          {!loading && items.length === 0 && <li className="picker-empty muted small">没有匹配项</li>}
        </ul>,
        document.body,
      )}
    </div>
  );
}

/** 表单底部的提示：必填但不支持的字段需要到网页处理。 */
export function UnsupportedNotice({ fields, action }: { fields: FieldMeta[]; action: ReactNode }) {
  const blocked = unsupportedRequired(fields);
  if (blocked.length === 0) return null;
  return (
    <div className="notice error">
      必填字段「{blocked.map((f) => f.name).join("、")}」暂不支持在工作台中填写，{action}
    </div>
  );
}
