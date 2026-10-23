// Wiki 的界面辅助：收藏的页面、页面中 Jira 宏的实时状态、目录。
import { useEffect, useState } from "react";
import { api, type IssueSummary } from "../api";

// ---------- 收藏 ----------

export interface FavoritePage {
  id: string;
  title: string;
  space: string;
}

const FAVORITES_KEY = "nextworkzone.wiki.favorites";
const FAVORITES_EVENT = "nextworkzone-wiki-favorites";

export function loadFavorites(): FavoritePage[] {
  try {
    return JSON.parse(localStorage.getItem(FAVORITES_KEY) ?? "[]") as FavoritePage[];
  } catch {
    return [];
  }
}

function storeFavorites(list: FavoritePage[]) {
  try {
    localStorage.setItem(FAVORITES_KEY, JSON.stringify(list));
  } catch {
    // 不保存
  }
  window.dispatchEvent(new Event(FAVORITES_EVENT));
}

export function toggleFavorite(page: FavoritePage) {
  const list = loadFavorites();
  storeFavorites(list.some((p) => p.id === page.id) ? list.filter((p) => p.id !== page.id) : [page, ...list]);
}

/** 收藏的页面标题有变化时更新。 */
export function refreshFavorite(page: FavoritePage) {
  const list = loadFavorites();
  const old = list.find((p) => p.id === page.id);
  if (old && (old.title !== page.title || old.space !== page.space)) storeFavorites(list.map((p) => (p.id === page.id ? page : p)));
}

export function useFavorites(): FavoritePage[] {
  const [list, setList] = useState(loadFavorites);
  useEffect(() => {
    const update = () => setList(loadFavorites());
    window.addEventListener(FAVORITES_EVENT, update);
    return () => window.removeEventListener(FAVORITES_EVENT, update);
  }, []);
  return list;
}

// ---------- Jira 宏 ----------

const ISSUE_KEY = /^[A-Z][A-Z0-9_]+-\d+$/;

/** 页面 HTML 中 Jira 宏和问题链接引用的问题键（按出现顺序去重）。 */
export function issueKeysIn(root: ParentNode, jiraBase: string): string[] {
  const keys: string[] = [];
  const add = (key: string | null | undefined) => {
    if (key && ISSUE_KEY.test(key) && !keys.includes(key)) keys.push(key);
  };
  root.querySelectorAll<HTMLElement>("[data-jira-key]").forEach((el) => add(el.dataset.jiraKey));
  if (jiraBase) {
    root.querySelectorAll<HTMLAnchorElement>("a[href]").forEach((a) => {
      const href = a.getAttribute("href") ?? "";
      if (href.startsWith(`${jiraBase}/browse/`)) add(href.slice(jiraBase.length + 8).split(/[?#]/)[0]);
    });
  }
  return keys;
}

/** 批量查询问题的概要和状态（Jira 未配置或查询失败时为空）。 */
export async function fetchIssues(keys: string[]): Promise<Map<string, IssueSummary>> {
  const map = new Map<string, IssueSummary>();
  for (let i = 0; i < keys.length; i += 100) {
    const chunk = keys.slice(i, i + 100);
    try {
      const result = await api.jiraSearch(`key in (${chunk.join(",")})`, 0, chunk.length);
      result.issues.forEach((issue) => map.set(issue.key, issue));
    } catch {
      // 某个问题不存在或没有权限时整批会失败，逐个再试
      for (const key of chunk) {
        try {
          const result = await api.jiraSearch(`key = ${key}`, 0, 1);
          result.issues.forEach((issue) => map.set(issue.key, issue));
        } catch {
          // 跳过
        }
      }
    }
  }
  return map;
}

/** 把 Jira 宏的占位（“正在获取问题细节”）换成问题的概要和状态。 */
export function fillJiraMacros(root: ParentNode, issues: Map<string, IssueSummary>) {
  root.querySelectorAll<HTMLElement>(".jira-issue[data-jira-key]").forEach((el) => {
    const issue = issues.get(el.dataset.jiraKey ?? "");
    const summary = el.querySelector(".summary");
    const lozenge = el.querySelector(".aui-lozenge");
    el.querySelectorAll(".aui-icon-wait").forEach((icon) => icon.remove());
    if (!issue) {
      summary?.remove();
      lozenge?.remove();
      return;
    }
    if (summary) summary.textContent = issue.summary;
    if (lozenge) {
      lozenge.textContent = issue.status.name;
      lozenge.className = `status status-${issue.status.category}`;
    }
  });
}

// ---------- 目录 ----------

export interface TocItem {
  id: string;
  text: string;
  level: number;
}

/** 页面中的标题（给没有 id 的标题补上 id）。 */
export function headingsOf(root: HTMLElement): TocItem[] {
  const items: TocItem[] = [];
  root.querySelectorAll<HTMLHeadingElement>("h1, h2, h3, h4").forEach((h, i) => {
    const text = h.textContent?.trim() ?? "";
    if (!text) return;
    if (!h.id) h.id = `nwz-h-${i}`;
    items.push({ id: h.id, text, level: Number(h.tagName[1]) });
  });
  return items;
}

/** Confluence 地址中的页面 id。 */
export function pageIdOf(url: string | null | undefined): string | null {
  return url?.match(/[?&]pageId=(\d+)/)?.[1] ?? null;
}
