import { Component, type ReactNode } from "react";

/** 页面渲染出错时显示错误信息，而不是整个窗口白屏。 */
export class ErrorBoundary extends Component<{ children: ReactNode; resetKey: string }, { error: Error | null; key: string }> {
  state = { error: null as Error | null, key: this.props.resetKey };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  // 切换到其他页面时清除错误
  static getDerivedStateFromProps(props: { resetKey: string }, state: { key: string }) {
    return props.resetKey !== state.key ? { error: null, key: props.resetKey } : null;
  }

  render() {
    if (!this.state.error) return this.props.children;
    return (
      <section className="page">
        <div className="notice error">
          页面出错：{this.state.error.message}
          <button className="btn" onClick={() => window.location.reload()}>
            重新加载
          </button>
        </div>
      </section>
    );
  }
}
