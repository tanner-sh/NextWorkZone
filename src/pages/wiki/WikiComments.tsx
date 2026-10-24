import { useCallback, useEffect, useMemo, useState } from "react";
import { MessageSquare, Reply } from "lucide-react";
import { api, errorMessage, type WikiComment } from "../../api";
import { Avatar, ErrorBox, Skeleton } from "../../components/common";
import { CommentBox } from "../../components/CommentBox";
import { RichHtml } from "../../components/RichHtml";
import { formatTime } from "../../lib/format";

/** 页面评论：页面底部的评论和行内评论，按回复关系缩进显示；可以发表评论和回复。 */
export function WikiComments({ pageId }: { pageId: string }) {
  const [comments, setComments] = useState<WikiComment[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [replyTo, setReplyTo] = useState<string | null>(null);

  const load = useCallback(() => {
    setError(null);
    api.wikiComments(pageId).then(setComments, (e) => setError(errorMessage(e)));
  }, [pageId]);
  useEffect(load, [load]);

  // 按回复关系排成树：顶层评论按时间，回复跟在被回复的评论后面
  const ordered = useMemo(() => {
    const list = comments ?? [];
    const byParent = new Map<string | null, WikiComment[]>();
    for (const c of list) {
      const parent = c.parentId && list.some((x) => x.id === c.parentId) ? c.parentId : null;
      byParent.set(parent, [...(byParent.get(parent) ?? []), c]);
    }
    const out: { comment: WikiComment; depth: number }[] = [];
    const walk = (parent: string | null, depth: number) => {
      for (const c of byParent.get(parent) ?? []) {
        out.push({ comment: c, depth });
        walk(c.id, depth + 1);
      }
    };
    walk(null, 0);
    return out;
  }, [comments]);

  return (
    <section className="block">
      <h2>
        <MessageSquare size={16} className="muted" />
        评论 {comments && comments.length > 0 && <span className="count">{comments.length}</span>}
      </h2>
      {error && <ErrorBox message={error} onRetry={load} />}
      {!comments && !error && <Skeleton lines={3} />}
      {ordered.length > 0 && (
        <ul className="wiki-comments">
          {ordered.map(({ comment: c, depth }) => (
            <li key={c.id} className="wiki-comment" style={{ marginLeft: Math.min(depth, 4) * 24 }}>
              <div className="wiki-comment-head">
                <Avatar name={c.author} size={22} />
                <strong>{c.author}</strong>
                <span className="muted small">{formatTime(c.created)}</span>
                <span className="spacer" />
                <button className="btn subtle small-btn" onClick={() => setReplyTo(replyTo === c.id ? null : c.id)}>
                  <Reply size={13} />
                  回复
                </button>
              </div>
              {c.inlineText && <blockquote className="wiki-inline-quote muted small">行内评论：{c.inlineText}</blockquote>}
              <RichHtml service="confluence" html={c.html} />
              {replyTo === c.id && (
                <CommentBox
                  placeholder={`回复 ${c.author}`}
                  onCancel={() => setReplyTo(null)}
                  onSubmit={async (text) => {
                    setComments(await api.wikiAddComment(pageId, c.id, text));
                    setReplyTo(null);
                  }}
                />
              )}
            </li>
          ))}
        </ul>
      )}
      {comments && comments.length === 0 && <p className="muted small">还没有评论</p>}
      <CommentBox placeholder="发表评论（Ctrl+Enter 发送）" onSubmit={async (text) => setComments(await api.wikiAddComment(pageId, null, text))} />
    </section>
  );
}
