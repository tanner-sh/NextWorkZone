import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./styles.css";

// macOS 上窗口透明，侧边栏显示系统材质（见 tauri.conf.json 的 windowEffects）
if (navigator.userAgent.includes("Mac")) document.documentElement.classList.add("mac");

// 改名前的本地设置（已保存的查询、周报草稿等）迁移到新前缀，只执行一次
try {
  for (const key of Object.keys(localStorage)) {
    if (!key.startsWith("mywork.")) continue;
    const next = "nextworkzone." + key.slice("mywork.".length);
    if (localStorage.getItem(next) === null) localStorage.setItem(next, localStorage.getItem(key)!);
    localStorage.removeItem(key);
  }
} catch {
  // 存储不可用时忽略
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
