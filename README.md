# NextWorkZone

个人工作空间：自带待办、笔记（含每日日记）、知识库，并与 Jira、Confluence（Wiki）、GitLab 集成——
Jira 问题自动进入待办、笔记里的问题键实时显示状态、问题可一键沉淀到知识库、知识库页面可发布到 Wiki。
工作空间数据保存在本机，可通过同步文件夹在多台电脑间同步。系统地址与凭据均可配置，目前支持 Jira / Confluence 的 Server 与 Data Center 版本。

技术栈：业务逻辑和各系统的接口都在 Rust 中（`crates/`），两个界面共用：

- **macOS**：SwiftUI 原生应用（`macos/`），最低 macOS 26，通过 UniFFI 调用 Rust（`crates/ffi`）；
- **Windows、Linux**：Tauri 2 + React + TypeScript + Vite（`src-tauri`、`src`）。

## 开发

```sh
cargo test --workspace     # Rust 测试

# macOS 原生版（只需要命令行工具，不需要 Xcode）
macos/build.sh             # 开发版：macos/build/NextWorkZone.app
macos/build.sh release     # 正式版

# Windows、Linux（Tauri）
npm install
npx tauri dev              # 开发模式运行（前端热更新，Rust 改动自动重启）
npx tauri build            # 打包安装包（target/release/bundle/）
```

不启动界面、直接对真实系统做只读调用（地址取自应用配置，Token 取自 `~/.nextworkzone/tokens.env`）：

```sh
cargo run -p nextworkzone-devtools -- ping
cargo run -p nextworkzone-devtools -- jira-search "assignee = currentUser()"
```

## 结构

| 目录 | 说明 |
|---|---|
| `crates/core` | 配置、HTTP 客户端（代理、GET 自动重试）、凭据存储、缓存、错误类型 |
| `crates/jira` | Jira REST v2：搜索、详情、流转、评论、附件、分配、关注、工作日志、相似问题、动态 |
| `crates/confluence` | Confluence REST v1：浏览、历史版本、评论、模板、通知（`browse.rs`）；storage 扫描器、纯文本与任务提取（`text.rs`）、版本差异（`diff.rs`）、页面编辑（`edit.rs`）、本机 Wiki 库（`index.rs`）、周报读写（`weekly.rs`） |
| `crates/gitlab` | GitLab REST v4：项目、分支、目录树、文件、提交、对比、推送记录；合并请求（列表、详情、改动、讨论与行内评论、审批、合并、新建）（`mr.rs`） |
| `crates/preview` | 附件预览：Excel/CSV 表格、Word 段落、文本（自动识别 UTF-8 / GB18030）、ZIP 文件清单 |
| `crates/workspace` | 工作空间本地数据（SQLite）：待办、文档、图片、引用与全文索引、多设备同步 |
| `crates/richdoc` | 富文本的统一文档模型，以及与 HTML、Markdown、Jira wiki 标记、Confluence XHTML 之间的转换；编辑 Wiki 时保留未修改的内容（`edit.rs`） |
| `crates/clipboard`、`crates/desktop` | 剪贴板历史；剪贴板读写、前台应用、模拟粘贴等系统能力（macOS、Windows、Linux） |
| `crates/app` | 不依赖界面的应用层：状态、全部命令（`dispatch` 统一入口）、后台同步与提醒、剪贴板记录 |
| `crates/ffi` | 供 Swift 调用的接口（UniFFI） |
| `crates/devtools` | 命令行调试工具 |
| `macos` | macOS 原生界面（SwiftUI + AppKit）；开发构建带本机测试通道（`DevBridge.swift`） |
| `src-tauri` | Windows、Linux 的 Tauri 外壳：`nextworkzone://` 图片代理、网页登录、托盘与浮动窗口；开发构建带本机测试通道（`devbridge.rs`） |
| `src` | Windows、Linux 的 React 前端 |

## 关键设计

- **认证**：REST API 使用个人访问令牌（PAT）。附件、图片等网页路径先尝试用令牌访问；若服务器要求单独的网页登录（例如启用了 2FA / SSO），通过应用内的“网页登录”窗口获取会话（可配置账号密码自动填写，后台定期保活）。
- **凭据存储**：正式版全部凭据存在系统的凭据存储（macOS 钥匙串等）的一个条目中；开发版存放在应用配置目录下的 `dev-credentials.json`（权限 0600），避免每次重新编译后反复弹出钥匙串授权。
- **周报**：每周一个以日期范围开头的一级标题，表格中第一列为自己名字的那一行即为自己的周报；只改写这一行的后续单元格，页面其余内容逐字节保持不变；保存时基于最新版本改写，遇到版本冲突会自动重试；如果自己那一行在网页端被改过，会提示冲突，不会覆盖。
- **工作空间数据**：待办与文档（笔记、日记、知识库页面）存在应用数据目录的 `workspace.db`，正文为 Markdown；图片单独存放，正文中以 `ws://asset/<id>` 引用，文档之间以 `ws://doc/<id>` 链接。问题键、文档链接在保存时提取为引用关系，用于反向链接和问题页上的“工作空间”区块。
- **相似问题**：Jira 按单字索引中文，多字词会被当成“这些字都出现”。所以把概要拆成相邻两字的组合（去掉常用词和含虚词的组合），用 OR 连接查询，不指定排序时 Jira 按相关度返回。
- **动态**：Jira Server 没有通知接口。每 3 分钟查询经办、报告、关注或提到我的、最近更新过的问题，从评论和变更记录中找出上次检查之后别人造成的变化，保存在本机缓存中并记录已读；每次多看 5 分钟以应对索引延迟，重复的按 id 去掉。第一次检查回看 3 天，直接标为已读。
- **计时**：同一时间只计一个，状态保存在本机；停止后登记为所选问题的工作日志。
- **多设备同步**：在设置中选择一个同步文件夹（iCloud Drive、坚果云、NAS 等）。每台设备只追加写自己的变更日志 `NextWorkZone/devices/<设备>.jsonl`，读取其他设备的日志按修改时间合并；删除使用墓碑标记。文档记录了“基于哪个版本修改”，两台设备各自修改同一篇时，本地版本另存为“冲突副本”，内容不会丢。日志超过 8MB 时整理为最新版本，并更换代号通知其他设备从头读取。
- **Wiki**：应用内浏览空间和页面树、阅读页面（Jira 宏显示实时状态、页面任务可勾选、自动生成目录）、查看历史版本差异、评论。
  Jira、Wiki、GitLab 的链接在应用内打开（含 `/x/` 短链接、`/display/空间/标题`），附件在应用内预览。
- **本机 Wiki 库**：页面标题和正文（转为按段落分行的纯文本）存在 `wiki-index.db`，按最后修改时间增量同步，每天对比一次页面 id 清理已删除的页面；
  超长页面导致一批请求超时时自动缩小批量，单个页面失败则跳过。用于全文搜索、问题详情中“引用此问题的 Wiki 页面”（另合并 Jira 的远程链接）、找出 @我 的页面任务（同步为待办，勾选后回写 Wiki）。
- **编辑 Wiki 页面**：storage 本身是 XHTML，段落、标题、列表、表格、文字格式直接可视化编辑；宏、图片、页面链接、任务列表等替换为不可编辑的占位块，
  保存时换回原文，逐字节不变（未修改时与原文只差实体写法，如 `&rarr;` 与 `→`）。保存前显示文字差异，并检查页面是否在编辑期间被别人修改过，是则不覆盖。
- **知识库与 Wiki**：剪藏和发布时在地址中记下版本（`pageVersion=`），原页面有更新时提示并可查看变化、重新剪藏；再次发布时更新上次发布的页面，页面被别人改过时需确认才覆盖。
