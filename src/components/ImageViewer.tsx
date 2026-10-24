import { useEffect, useState } from "react";
import { usePageActive } from "../state/nav";
import { Maximize2, Minimize2, X } from "lucide-react";

/** 全屏查看图片：默认适应窗口，点击图片切换原始大小（可滚动查看），Esc 或点击空白处关闭。 */
export function ImageViewer({ src, alt, onClose }: { src: string; alt?: string; onClose: () => void }) {
  const [actual, setActual] = useState(false);
  const [failed, setFailed] = useState(false);

  // 所在页面隐藏时不响应按键
  const active = usePageActive();
  useEffect(() => {
    if (!active) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        onClose();
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [onClose, active]);

  return (
    <div className="image-viewer" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="image-viewer-bar">
        <span className="ellipsis">{alt}</span>
        <span className="spacer" />
        <button className="btn subtle icon" title={actual ? "适应窗口" : "原始大小"} onClick={() => setActual((v) => !v)}>
          {actual ? <Minimize2 size={16} /> : <Maximize2 size={16} />}
        </button>
        <button className="btn subtle icon" title="关闭（Esc）" onClick={onClose}>
          <X size={18} />
        </button>
      </div>
      <div className={`image-viewer-stage${actual ? " actual" : ""}`} onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
        {failed ? (
          <span className="muted">图片加载失败</span>
        ) : (
          <img src={src} alt={alt ?? ""} onClick={() => setActual((v) => !v)} onError={() => setFailed(true)} />
        )}
      </div>
    </div>
  );
}
