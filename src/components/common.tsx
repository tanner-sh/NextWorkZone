import { useEffect, useRef, useState, type ReactNode } from "react";
import { AlertCircle, KeyRound, Loader2, PlugZap, RotateCw, X } from "lucide-react";
import { api, type JiraStatus, type Service } from "../api";
import { assetUrl, systemPath } from "../lib/asset";
import { useSettings } from "../state/settings";

/** 显示来自某个系统的图片（图标、头像等），需要认证时自动经由代理加载。 */
export function SysImg({ service, src, alt = "", className }: { service: Service; src: string | null | undefined; alt?: string; className?: string }) {
  const { baseUrl, sessionVersion } = useSettings();
  const [loaded, setLoaded] = useState<string | null>(null);
  const [failed, setFailed] = useState<string | null>(null);
  if (!src) return null;
  const path = systemPath(src, baseUrl(service));
  const url = path ? assetUrl(service, path, sessionVersion) : src;
  // 加载成功前不占位，失败（例如需要网页登录）时不显示破损的图片
  if (failed === url) return null;
  return (
    <img
      className={className}
      src={url}
      alt={alt}
      style={loaded === url ? undefined : { display: "none" }}
      onLoad={() => setLoaded(url)}
      onError={() => setFailed(url)}
    />
  );
}

/** 网页路径（附件、图片）需要网页登录时显示提示；Token 即可访问或已登录时不显示。 */
export function WebLoginHint({ service, label }: { service: Service; label: string }) {
  const { webAccess } = useSettings();
  const [opening, setOpening] = useState(false);
  if (webAccess(service) !== "loginRequired") return null;
  const login = async () => {
    setOpening(true);
    try {
      await api.webLogin(service);
    } finally {
      setOpening(false);
    }
  };
  return (
    <div className="notice warn">
      <KeyRound size={15} />
      <span>{label} 的附件和图片需要网页登录后才能显示，登录一次即可。</span>
      <span className="spacer" />
      <button className="btn" onClick={login} disabled={opening}>
        网页登录
      </button>
    </div>
  );
}

const AVATAR_COLORS = ["#6366f1", "#0ea5e9", "#14b8a6", "#22c55e", "#f59e0b", "#ef4444", "#ec4899", "#8b5cf6", "#64748b"];

/** 人名头像：中文名取最后两个字，其他取首字母。 */
export function Avatar({ name, size = 24 }: { name: string | null | undefined; size?: number }) {
  const text = (name ?? "").trim();
  if (!text) return null;
  const isCjk = /[一-鿿]/.test(text);
  const initials = isCjk ? text.slice(-2) : text.split(/\s+/).map((w) => w[0]).join("").slice(0, 2).toUpperCase();
  const hash = [...text].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7);
  const color = AVATAR_COLORS[hash % AVATAR_COLORS.length];
  return (
    <span className="avatar" title={text} style={{ width: size, height: size, background: color, fontSize: Math.round(size * (isCjk ? 0.36 : 0.42)) }}>
      {initials}
    </span>
  );
}

export function StatusPill({ status }: { status: JiraStatus }) {
  return <span className={`status status-${status.category}`}>{status.name}</span>;
}

export function Spinner({ label = "加载中…" }: { label?: string }) {
  return (
    <div className="spinner">
      <Loader2 size={15} className="spin" />
      {label}
    </div>
  );
}

/** 加载占位：若干行灰色条，宽度依次变化。 */
export function Skeleton({ lines = 4, height = 14 }: { lines?: number; height?: number }) {
  const widths = ["92%", "78%", "85%", "64%", "88%", "70%"];
  return (
    <div className="skeleton-stack" aria-hidden>
      {Array.from({ length: lines }, (_, i) => (
        <div key={i} className="skeleton" style={{ height, width: widths[i % widths.length] }} />
      ))}
    </div>
  );
}

export function ErrorBox({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div className="notice error">
      <AlertCircle size={15} />
      <span className="grow">{message}</span>
      {onRetry && (
        <button className="btn" onClick={onRetry}>
          <RotateCw size={13} />
          重试
        </button>
      )}
    </div>
  );
}

/** 某个系统尚未配置时的占位提示。 */
export function NotConfigured({ label, onOpenSettings }: { label: string; onOpenSettings: () => void }) {
  return (
    <div className="empty">
      <PlugZap size={28} />
      <p>尚未配置 {label}</p>
      <button className="btn primary" onClick={onOpenSettings}>
        前往设置
      </button>
    </div>
  );
}

/** `wide` 用于字段较多的表单；`dirty` 时点击遮罩不关闭，避免误丢已填写的内容。 */
export function Modal(props: { title: string; children: ReactNode; onClose: () => void; footer?: ReactNode; wide?: boolean; dirty?: boolean }) {
  const { title, children, onClose, footer } = props;
  const ref = useRef<HTMLDivElement>(null);

  // 打开时聚焦第一个输入控件（没有则聚焦对话框本身），键盘焦点不离开对话框
  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    const first = dialog.querySelector<HTMLElement>(".modal-body input:not([disabled]), .modal-body select:not([disabled]), .modal-body textarea, .modal-body [contenteditable]");
    (first ?? dialog).focus();
  }, []);

  const onKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
    if (e.key === "Escape" && !e.defaultPrevented) {
      // 已填写内容时不响应 Esc，避免误丢
      if (!props.dirty) onClose();
      return;
    }
    if (e.key !== "Tab" || !ref.current) return;
    const focusable = Array.from(ref.current.querySelectorAll<HTMLElement>("button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [contenteditable], [tabindex]:not([tabindex='-1'])"));
    if (focusable.length === 0) return;
    const [first, last] = [focusable[0], focusable[focusable.length - 1]];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  };

  return (
    <div className="modal-backdrop" onMouseDown={(e) => e.target === e.currentTarget && !props.dirty && onClose()}>
      <div ref={ref} tabIndex={-1} className={`modal${props.wide ? " wide" : ""}`} role="dialog" aria-modal aria-label={title} onKeyDown={onKeyDown}>
        <header className="modal-header">
          <h2>{title}</h2>
          <button className="btn subtle icon" onClick={onClose} aria-label="关闭">
            <X size={16} />
          </button>
        </header>
        <div className="modal-body">{children}</div>
        {footer && <footer className="modal-footer">{footer}</footer>}
      </div>
    </div>
  );
}
