//! 开发辅助工具：不启动 GUI，直接对真实系统做**只读**调用，用于验证适配器。
//!
//! 地址读取应用保存的配置（`~/Library/Application Support/com.nextworkzone.desktop/config.json`），
//! Token 从 `~/.nextworkzone/tokens.env` 读取（`JIRA_PAT` / `WIKI_PAT` / `GITLAB_PAT`）。
//!
//! ```sh
//! cargo run -p nextworkzone-devtools -- ping
//! cargo run -p nextworkzone-devtools -- jira-search "assignee = currentUser() AND resolution = Unresolved"
//! cargo run -p nextworkzone-devtools -- jira-issue ABC-123
//! ```

use std::path::PathBuf;

use nextworkzone_confluence::ConfluenceClient;
use nextworkzone_core::secrets::parse_tokens_env;
use nextworkzone_core::{AppConfig, Result, Service, http};
use nextworkzone_gitlab::GitlabClient;
use nextworkzone_jira::JiraClient;

struct Env {
    config: AppConfig,
    tokens: Vec<(Service, String)>,
    http: reqwest::Client,
}

impl Env {
    fn load() -> Self {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| exit("无法确定 HOME 目录")));
        let config_path = home.join("Library/Application Support/com.nextworkzone.desktop/config.json");
        let config = AppConfig::load(&config_path).unwrap_or_else(|e| exit(&e.to_string()));
        let tokens_path = home.join(".nextworkzone/tokens.env");
        let content = std::fs::read_to_string(&tokens_path)
            .unwrap_or_else(|e| exit(&format!("读取 {} 失败：{e}", tokens_path.display())));
        let http = http::build_client(config.proxy.as_deref()).unwrap_or_else(|e| exit(&e.to_string()));
        Env { config, tokens: parse_tokens_env(&content), http }
    }

    fn parts(&self, service: Service) -> (reqwest::Client, String, String) {
        let base = self.config.base_url(service).unwrap_or_else(|e| exit(&e.to_string()));
        let token = self
            .tokens
            .iter()
            .find(|(s, _)| *s == service)
            .map(|(_, t)| t.clone())
            .unwrap_or_else(|| exit(&format!("tokens.env 中没有 {} 的 Token", service.label())));
        (self.http.clone(), base.to_string(), token)
    }

    fn jira(&self) -> JiraClient {
        let (h, b, t) = self.parts(Service::Jira);
        JiraClient::new(h, b, t)
    }

    fn confluence(&self) -> ConfluenceClient {
        let (h, b, t) = self.parts(Service::Confluence);
        ConfluenceClient::new(h, b, t)
    }

    fn gitlab(&self) -> GitlabClient {
        let (h, b, t) = self.parts(Service::Gitlab);
        GitlabClient::new(h, b, t)
    }
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let env = Env::load();
    let arg = |i: usize| args.get(i).cloned().unwrap_or_else(|| exit("缺少参数"));
    let result: Result<()> = async {
        match args.first().map(String::as_str) {
            Some("ping") => ping(&env).await,
            Some("jira-activity") => {
                // 最近若干小时的动态：jira-activity 72
                let jira = env.jira();
                let me = jira.my_username().await?;
                let hours: i64 = arg(1).parse().unwrap_or(72);
                let cutoff = chrono::Local::now().fixed_offset() - chrono::Duration::hours(hours);
                let since = cutoff.format("%Y/%m/%d %H:%M").to_string();
                print(&jira.activity(&me, &since, cutoff).await?)
            }
            Some("jira-get") => print(&env.jira().get_path(&arg(1)).await?),
            Some("jira-search") => print(&env.jira().search(&arg(1), 0, 20).await?),
            Some("jira-issue") => print(&env.jira().issue(&arg(1)).await?),
            Some("jira-transitions") => print(&env.jira().transitions(&arg(1)).await?),
            Some("jira-edit-fields") => print(&env.jira().edit_fields(&arg(1)).await?),
            Some("jira-create-projects") => print(&env.jira().create_projects().await?),
            Some("jira-create-fields") => print(&env.jira().create_fields(&arg(1), &arg(2)).await?),
            Some("jira-worklogs") => print(&env.jira().worklogs(&arg(1)).await?),
            Some("jira-history") => print(&env.jira().history(&arg(1)).await?),
            Some("jira-link-types") => print(&env.jira().link_types().await?),
            Some("jira-users") => print(&env.jira().find_users(&arg(1), args.get(2).map_or("", String::as_str), args.get(3).map(String::as_str), None).await?),
            Some("jira-labels") => print(&env.jira().suggest_labels(&arg(1)).await?),
            Some("jira-epics") => print(&env.jira().search_epics(&arg(1), &arg(2)).await?),
            Some("jira-pick") => print(&env.jira().pick_issues(&arg(1), args.get(2).map(String::as_str), false).await?),
            Some("gl-projects") => print(&env.gitlab().projects(args.get(1).map(String::as_str), 20).await?),
            Some("gl-branches") => print(&env.gitlab().branches(num(&arg(1)), None).await?),
            Some("gl-tree") => print(&env.gitlab().tree(num(&arg(1)), &arg(2), args.get(3).map_or("", String::as_str)).await?),
            Some("gl-file") => {
                let f = env.gitlab().file(num(&arg(1)), &arg(2), &arg(3)).await?;
                println!("size={} binary={} too_large={} image={} text_len={:?}", f.size, f.binary, f.too_large, f.image_data_url.is_some(), f.text.map(|t| t.len()));
                Ok(())
            }
            Some("gl-commits") => print(&env.gitlab().commits(num(&arg(1)), &arg(2), None, 1).await?),
            Some("gl-commit") => {
                let c = env.gitlab().commit(num(&arg(1)), &arg(2)).await?;
                println!("{} {} files={}", c.commit.short_id, c.commit.title, c.diffs.len());
                Ok(())
            }
            Some("gl-pushes") => print(&env.gitlab().my_pushes(&arg(1)).await?),
            // 模拟另一台设备：ws-device 数据库路径 同步目录 [新待办标题]
            Some("ws-device") => {
                let ws = nextworkzone_workspace::Workspace::open(std::path::Path::new(&arg(1)))?;
                if let Some(title) = args.get(3) {
                    ws.save_todo(nextworkzone_workspace::TodoInput { title: title.clone(), ..Default::default() })?;
                }
                print(&ws.sync(std::path::Path::new(&arg(2)).join("NextWorkZone").as_path())?)?;
                println!("todos: {:?}", ws.todos()?.iter().map(|t| t.title.as_str()).collect::<Vec<_>>());
                Ok(())
            }
            // 同步本机问题库：jira-index-sync 数据库路径 [JQL] [天数]（JQL 为空则自动选择项目）
            Some("jira-index-sync") => {
                use nextworkzone_jira::index::{IndexScope, IssueIndex, sync};
                let index = IssueIndex::open(std::path::Path::new(&arg(1)))?;
                let scope = IndexScope { jql: args.get(2).cloned().unwrap_or_default(), days: args.get(3).and_then(|d| d.parse().ok()).unwrap_or(730) };
                let started = std::time::Instant::now();
                let changed = sync(&env.jira(), &index, &scope, |p| eprintln!("{} {}/{} （范围 {}/{}）", p.scope, p.done, p.total, p.finished + 1, p.scopes)).await?;
                println!("更新 {changed} 个问题，用时 {:?}", started.elapsed());
                print(&index.stats()?)
            }
            // 搜索本机问题库：jira-index-search 数据库路径 关键词 / jira-index-similar 数据库路径 KEY 概要
            Some("jira-index-search") => {
                let index = nextworkzone_jira::index::IssueIndex::open(std::path::Path::new(&arg(1)))?;
                let started = std::time::Instant::now();
                let hits = index.search(&nextworkzone_jira::index::IndexQuery { text: arg(2), limit: 10, ..Default::default() }, "")?;
                eprintln!("用时 {:?}", started.elapsed());
                for h in hits {
                    println!("{} {} [{}] {:?}", h.issue.key, h.issue.summary, h.issue.resolution.unwrap_or_default(), h.snippet.map(|s| s.text));
                }
                Ok(())
            }
            Some("jira-index-similar") => {
                let index = nextworkzone_jira::index::IssueIndex::open(std::path::Path::new(&arg(1)))?;
                let started = std::time::Instant::now();
                let hits = index.similar(&arg(2), &arg(3), true, 8)?.unwrap_or_default();
                eprintln!("用时 {:?}", started.elapsed());
                for h in hits {
                    println!("{} {} [{}] {} {:?}", h.issue.key, h.issue.summary, h.issue.resolution.unwrap_or_default(), h.issue.assignee.unwrap_or_default(), h.last_comments.last().map(|c| &c.body));
                }
                Ok(())
            }
            Some("wiki-search") => print(&env.confluence().search(&arg(1), 5).await?),
            Some("wiki-spaces") => print(&env.confluence().spaces().await?),
            Some("wiki-roots") => print(&env.confluence().space_roots(&arg(1)).await?),
            Some("wiki-children") => print(&env.confluence().children(&arg(1)).await?),
            Some("wiki-page") => {
                let p = env.confluence().page_detail(&arg(1)).await?;
                println!("{} v{} {} {} 可编辑={} 上级={:?} html={}字节", p.title, p.version, p.modified_by, p.modified, p.can_edit, p.ancestors.iter().map(|a| &a.title).collect::<Vec<_>>(), p.html.len());
                Ok(())
            }
            Some("wiki-attachments") => print(&env.confluence().attachments(&arg(1)).await?),
            Some("wiki-versions") => print(&env.confluence().versions(&arg(1)).await?.into_iter().take(5).collect::<Vec<_>>()),
            // 两个版本的差异：wiki-diff 页面 旧版本 新版本
            Some("wiki-diff") => {
                let c = env.confluence();
                let (old, new) = (c.version_storage(&arg(1), num(&arg(2))).await?, c.version_storage(&arg(1), num(&arg(3))).await?);
                println!("{}", nextworkzone_confluence::diff::unified(&old, &new));
                Ok(())
            }
            Some("wiki-comments") => print(&env.confluence().comments(&arg(1)).await?),
            Some("wiki-templates") => print(&env.confluence().templates(args.get(1).map(String::as_str)).await?),
            Some("wiki-resolve") => print(&env.confluence().resolve_page(&arg(1)).await?),
            Some("wiki-notifications") => print(&env.confluence().notifications().await?),
            Some("wiki-watched") => print(&env.confluence().watched_changes(num(&arg(1)) as i64).await?),
            Some("wiki-recent") => print(&env.confluence().recently_viewed(10).await?),
            Some("wiki-cql") => print(&env.confluence().cql_search(&nextworkzone_confluence::browse::CqlQuery { text: arg(1), limit: 5, ..Default::default() }, "").await?),
            // 页面转为可编辑内容再还原，检查是否逐字节一致：wiki-edit-roundtrip 页面
            Some("wiki-editable") => {
                let page = env.confluence().page(&arg(1)).await?;
                let ed = nextworkzone_confluence::edit::to_editable(&page.storage)?;
                println!("storage={}字节 html={}字节 占位块={} 用户={:?}", page.storage.len(), ed.html.len(), ed.fragments.len(), ed.users);
                println!("{}", ed.html.chars().take(1500).collect::<String>());
                Ok(())
            }
            // 同步本机 Wiki 库：wiki-index-sync 数据库路径 [空间,空间]
            Some("wiki-index-sync") => {
                use nextworkzone_confluence::index::{WikiIndex, WikiScope, sync};
                let index = WikiIndex::open(std::path::Path::new(&arg(1)))?;
                let spaces = args.get(2).map(|s| s.split(',').map(str::to_string).collect()).unwrap_or_default();
                let started = std::time::Instant::now();
                let changed = sync(&env.confluence(), &index, &WikiScope { spaces }, |p| eprintln!("{}/{}", p.done, p.total)).await?;
                println!("更新 {changed} 个页面，用时 {:?}", started.elapsed());
                print(&index.stats()?)
            }
            Some("wiki-index-search") => {
                let index = nextworkzone_confluence::index::WikiIndex::open(std::path::Path::new(&arg(1)))?;
                let started = std::time::Instant::now();
                let hits = index.search(&nextworkzone_confluence::index::WikiQuery { text: arg(2), limit: 10, ..Default::default() }, "")?;
                eprintln!("用时 {:?}", started.elapsed());
                for h in hits {
                    println!("{} {} [{}] {}", h.id, h.title, h.space_name, h.snippet);
                }
                Ok(())
            }
            Some("wiki-index-issue") => {
                let index = nextworkzone_confluence::index::WikiIndex::open(std::path::Path::new(&arg(1)))?;
                for h in index.pages_with_issue(&arg(2), 10)? {
                    println!("{} {} [{}]", h.id, h.title, h.space_name);
                }
                Ok(())
            }
            _ => exit("用法：nextworkzone-devtools <ping | jira-search JQL | jira-issue KEY | jira-transitions KEY | jira-edit-fields KEY | jira-create-projects | jira-create-fields 项目 类型ID | jira-worklogs KEY | jira-history KEY | jira-link-types | jira-users 文本 [字段 KEY] | jira-labels 文本 | jira-epics 文本 项目 | jira-pick 文本 [项目] | gl-projects [搜索] | gl-branches ID | gl-tree ID REF [PATH] | gl-file ID REF PATH | gl-commits ID REF | gl-commit ID SHA | gl-pushes YYYY-MM-DD | wiki-search 文本>"),
        }
    }
    .await;
    if let Err(e) = result {
        exit(&e.to_string());
    }
}

async fn ping(env: &Env) -> Result<()> {
    for service in Service::ALL {
        let info = match service {
            Service::Jira => env.jira().connection_info().await,
            Service::Confluence => env.confluence().connection_info().await,
            Service::Gitlab => env.gitlab().connection_info().await,
        };
        match info {
            Ok(info) => println!(
                "✓ {:<6} {}（{}） 版本 {}",
                service.label(),
                info.display_name,
                info.username,
                info.server_version.as_deref().unwrap_or("未知"),
            ),
            Err(e) => println!("✗ {:<6} {e}", service.label()),
        }
    }
    Ok(())
}

fn print<T: serde::Serialize>(value: &T) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
}

fn num(s: &str) -> u64 {
    s.parse().unwrap_or_else(|_| exit(&format!("不是有效的数字：{s}")))
}

fn exit(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(2);
}
