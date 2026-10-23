import { Wrench } from "lucide-react";
import { useNav } from "../state/nav";
import { TOOLS, useHiddenTools } from "./registry";

/** 设置页中的“工具”卡片：每个工具的简要设置、是否在侧边栏显示，以及进入完整设置。 */
export function ToolsSettingsCard() {
  const { navigate } = useNav();
  const [hidden, setHidden] = useHiddenTools();
  return (
    <div className="card">
      <div className="service-head">
        <span className="service-icon">
          <Wrench size={16} />
        </span>
        <div>
          <h2>工具</h2>
          <p className="muted small">提高效率的小工具。每个工具都可以从侧边栏、⌘K 搜索中打开。</p>
        </div>
      </div>
      {TOOLS.map((tool) => (
        <div key={tool.id} className="tool-row">
          <span className="tool-row-icon">
            <tool.icon size={16} />
          </span>
          <div className="grow">
            <div className="tool-row-title">
              <b>{tool.name}</b>
              <span className="muted small">{tool.description}</span>
            </div>
            {tool.Summary && <tool.Summary />}
            <label className="checkbox small">
              <input
                type="checkbox"
                checked={!hidden.includes(tool.id)}
                onChange={(e) => void setHidden(e.target.checked ? hidden.filter((id) => id !== tool.id) : [...hidden, tool.id])}
              />
              在侧边栏显示
            </label>
          </div>
          <button className="btn" onClick={() => navigate({ page: "tools", tool: tool.id, toolTab: "settings" })}>
            设置…
          </button>
        </div>
      ))}
    </div>
  );
}
