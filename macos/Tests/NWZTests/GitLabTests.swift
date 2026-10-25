import Foundation
import Testing
import NWZCore
import NWZGitLab

@Suite struct GitLabTests {
    func doc(_ text: String) throws -> JSONDocument { try JSONDocument(data: Data(text.utf8)) }
    let base = "https://git.example.com"
    @Test func parsesBranchCommitAndMergeRequestLinks() {
        #expect(GitLabLinks.parse(base: base, url: base + "/group/sub/app/-/tree/release") == GitLabLink(projectPath: "group/sub/app", target: .branch(rest: "release")))
        #expect(GitLabLinks.parse(base: base, url: base + "/group/app/-/tree/feature/PROJ-1/src/main.swift?ref_type=heads")?.target == .branch(rest: "feature/PROJ-1/src/main.swift"))
        #expect(GitLabLinks.parse(base: base, url: base + "/group/app/-/commit/ABCDEF1234567")?.target == .commit(sha: "abcdef1234567"))
        #expect(GitLabLinks.parse(base: base, url: base + "/group/app/-/merge_requests/42#note_1")?.target == .mergeRequest(iid: 42))
        #expect(GitLabLinks.parse(base: base, url: base + "/group/app/commit/abcdef1")?.target == .commit(sha: "abcdef1"))
        #expect(GitLabLinks.parse(base: base, url: base + "/group/app/-/commits/%E4%BF%AE%E5%A4%8D")?.target == .branch(rest: "修复"))
    }
    @Test func ignoresOtherPagesAndHosts() {
        for url in [base + "/group/app", base + "/group/app/-/issues/3", base + "/group/app/-/commit/xyz", base + "/dashboard/merge_requests/1", base + ".evil.example.com/group/app/-/merge_requests/1", "https://other.example.com/group/app/-/merge_requests/1"] { #expect(GitLabLinks.parse(base: base, url: url) == nil) }
        #expect(GitLabLinks.looksLikeGitLab("https://other.example.com/group/app/-/tree/dev"))
        #expect(!GitLabLinks.looksLikeGitLab("https://other.example.com/browse/PROJ-1"))
        #expect(!GitLabLinks.looksLikeGitLab("https://github.com/org/repo/commit/abcdef1"))
    }
    @Test func extractsURLsFromHTMLAndText() {
        let html = #"已提交至 <a href="https://git.example.com/g/app/-/tree/dev?a=1&amp;b=2">https://git.example.com/g/app/-/tree/dev?a=1&amp;b=2</a>。另见 https://x.example.com/a，谢谢"#
        #expect(GitLabLinks.urls(html) == [base + "/g/app/-/tree/dev?a=1&b=2", "https://x.example.com/a"])
    }
    @Test func findsIssueKeys() {
        #expect(GitLabLinks.issueKeys("jira=PROJ-12 修复 feature/ABC-3") == ["PROJ-12", "ABC-3"])
        #expect(GitLabLinks.mentions("bugfix/PROJ-12", key: "PROJ-12"))
        #expect(!GitLabLinks.mentions("PROJ-123 修复", key: "PROJ-12"))
        #expect(!GitLabLinks.mentions("XPROJ-12", key: "PROJ-12"))
    }
    @Test func listsBranchCandidatesLongestFirst() {
        #expect(GitLabLinks.branchCandidates("feature/x/src/a.swift", limit: 3) == ["feature/x/src/a.swift", "feature/x/src", "feature/x"])
        #expect(GitLabLinks.branchCandidates("dev", limit: 6) == ["dev"])
    }
    @Test func convertsEventsToWorkRecords() throws {
        let push = GitLabEvent(raw: try doc(#"{"action_name":"pushed to","project_id":7,"created_at":"2026-10-22T03:00:00.000Z","push_data":{"ref":"feature-x","commit_title":"修复导入","commit_count":2}}"#))
        #expect(push?.kind == "push" && push?.title == "feature-x" && push?.detail == "修复导入" && push?.commitCount == 2)
        let merged = GitLabEvent(raw: try doc(#"{"action_name":"accepted","target_type":"MergeRequest","target_iid":12,"project_id":7}"#))
        #expect(merged?.kind == "mr_merge" && merged?.iid == 12)
        let note = GitLabEvent(raw: try doc(#"{"action_name":"commented on","project_id":7,"note":{"body":"看起来\n没问题","noteable_type":"MergeRequest","noteable_iid":12}}"#))
        #expect(note?.kind == "comment" && note?.detail == "看起来 没问题" && note?.iid == 12)
        #expect(GitLabEvent(raw: try doc(#"{"action_name":"joined","project_id":7}"#)) == nil)
        #expect(GitLabEvent(raw: try doc(#"{"action_name":"pushed to","project_id":7,"push_data":{"commit_count":0}}"#)) == nil)
    }
    @Test func parsesListAndDetailShapes() throws {
        let list = MergeRequest(raw: try doc(#"{"id":1,"iid":42,"project_id":7,"title":"t","description":null,"state":"merged","author":{"id":1,"username":"u","name":"张三"},"source_branch":"a","target_branch":"dev","references":{"full":"group/app!42"},"merge_status":"can_be_merged"}"#))
        #expect(list.reference == "group/app!42" && list.description.isEmpty && !list.canMerge && list.blockingDiscussionsResolved)
        let detail = MergeRequest(raw: try doc(#"{"user":{"can_merge":true},"head_pipeline":{"id":3,"status":"failed","web_url":"https://example.com/p"},"diff_refs":{"base_sha":"b","head_sha":"h","start_sha":"s"}}"#))
        #expect(detail.canMerge && detail.headPipeline?.status == "failed" && detail.diffRefs?.headSha == "h")
    }
    @Test func parsesTextPositionsOnly() throws {
        let note = MrNote(raw: try doc(#"{"position":{"position_type":"text","base_sha":"b","start_sha":"s","head_sha":"h","old_path":"a.swift","new_path":"a.swift","old_line":null,"new_line":12}}"#))
        #expect(note.position?.newLine == 12 && note.position?.oldLine == nil)
        #expect(try JSONDocument(data: JSONEncoder().encode(note.position))["newPath"].text == "a.swift")
        let image = MrNote(raw: try doc(#"{"position":{"position_type":"image","base_sha":"b"}}"#))
        #expect(image.position == nil)
    }
}
