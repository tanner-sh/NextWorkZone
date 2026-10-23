// 输入 [[ 弹出文档列表，选中后插入指向该文档的链接（ws://doc/<id>）；没有匹配时可直接新建笔记。
import { Extension, type Editor, type Range } from "@tiptap/core";
import { PluginKey } from "@tiptap/pm/state";
import Suggestion from "@tiptap/suggestion";
import { api, type DocSummary } from "../../../api";
import { workspaceChanged } from "../../../lib/workspace";
import { DOC_PREFIX } from "./convert";

interface Choice {
  id: string | null;
  title: string;
  kind: string;
}

const KIND_LABEL: Record<string, string> = { note: "笔记", page: "知识库", daily: "日记" };

let cache: { at: number; docs: DocSummary[] } | null = null;

async function allDocs(): Promise<DocSummary[]> {
  if (cache && Date.now() - cache.at < 10_000) return cache.docs;
  const [notes, pages] = await Promise.all([api.wsDocs("note"), api.wsDocs("page")]);
  cache = { at: Date.now(), docs: [...pages, ...notes] };
  return cache.docs;
}

function insertLink(editor: Editor, range: Range, id: string, title: string) {
  editor
    .chain()
    .focus()
    .insertContentAt(range, [
      { type: "text", text: title || "无标题", marks: [{ type: "link", attrs: { href: `${DOC_PREFIX}${id}` } }] },
      { type: "text", text: " " },
    ])
    .run();
}

export const DocLinks = Extension.create<{ currentId: () => string | null }>({
  name: "docLinks",
  addOptions() {
    return { currentId: () => null };
  },
  addProseMirrorPlugins() {
    const currentId = this.options.currentId;
    return [
      Suggestion<Choice>({
        editor: this.editor,
        pluginKey: new PluginKey("docLinks"),
        char: "[[",
        allowSpaces: true,
        startOfLine: false,
        items: async ({ query }) => {
          const q = query.trim().toLowerCase();
          const docs = (await allDocs()).filter((d) => d.id !== currentId() && (!q || d.title.toLowerCase().includes(q)));
          const choices: Choice[] = docs.slice(0, 8).map((d) => ({ id: d.id, title: d.title, kind: d.kind }));
          if (q && !docs.some((d) => d.title.toLowerCase() === q)) choices.push({ id: null, title: query.trim(), kind: "new" });
          return choices;
        },
        command: ({ editor, range, props }) => {
          if (props.id) {
            insertLink(editor, range, props.id, props.title);
            return;
          }
          // 新建一篇同名笔记并链接过去
          void api.wsSaveDoc({ kind: "note", title: props.title, content: "" }).then((doc) => {
            cache = null;
            workspaceChanged();
            insertLink(editor, range, doc.id, doc.title);
          });
        },
        render: () => {
          let popup: HTMLDivElement | null = null;
          let items: Choice[] = [];
          let active = 0;
          let choose: (item: Choice) => void = () => {};

          const draw = () => {
            if (!popup) return;
            popup.replaceChildren(
              ...(items.length === 0
                ? [Object.assign(document.createElement("div"), { className: "picker-empty muted small", textContent: "没有匹配的文档" })]
                : items.map((item, i) => {
                    const button = document.createElement("button");
                    button.type = "button";
                    button.className = i === active ? "active" : "";
                    const label = document.createElement("span");
                    label.textContent = item.id ? item.title || "无标题" : `新建笔记“${item.title}”`;
                    const kind = document.createElement("span");
                    kind.className = "muted small";
                    kind.textContent = item.id ? (KIND_LABEL[item.kind] ?? "") : "";
                    button.append(label, kind);
                    button.onmousedown = (e) => e.preventDefault();
                    button.onclick = () => choose(item);
                    return button;
                  })),
            );
          };
          const place = (rect: DOMRect | null | undefined) => {
            if (!popup || !rect) return;
            popup.style.left = `${Math.min(rect.left, window.innerWidth - 300)}px`;
            popup.style.top = `${rect.bottom + 6}px`;
          };

          return {
            onStart: (props) => {
              popup = document.createElement("div");
              popup.className = "picker-menu doc-link-menu";
              document.body.appendChild(popup);
              items = props.items;
              active = 0;
              choose = (item) => props.command(item);
              draw();
              place(props.clientRect?.());
            },
            onUpdate: (props) => {
              items = props.items;
              active = Math.min(active, Math.max(items.length - 1, 0));
              choose = (item) => props.command(item);
              draw();
              place(props.clientRect?.());
            },
            onKeyDown: ({ event }) => {
              if (event.key === "ArrowDown") {
                active = Math.min(active + 1, items.length - 1);
                draw();
                return true;
              }
              if (event.key === "ArrowUp") {
                active = Math.max(active - 1, 0);
                draw();
                return true;
              }
              if (event.key === "Enter" && items[active]) {
                choose(items[active]);
                return true;
              }
              return event.key === "Escape";
            },
            onExit: () => {
              popup?.remove();
              popup = null;
            },
          };
        },
      }),
    ];
  },
});
