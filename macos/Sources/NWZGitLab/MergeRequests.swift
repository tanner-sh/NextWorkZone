import Foundation
import NWZCore

extension GitLabClient {
    static func mrPath(_ project: String, _ iid: Int, _ tail: [String] = []) -> [String] { ["projects", project, "merge_requests", String(iid)] + tail }
    static func mrQuery(_ query: MrQuery) -> [(String, String)] {
        var q = [("state", query.state ?? "opened"), ("order_by", "updated_at"), ("per_page", "30"), ("page", String(query.page ?? 1))]
        if let text = query.search?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { q.append(("search", text)) }
        if let branch = query.sourceBranch, !branch.isEmpty { q.append(("source_branch", branch)) }
        return q
    }
    public func mergeRequests(scope: MrScope, query: MrQuery) async throws -> [MergeRequest] {
        var q = Self.mrQuery(query)
        if scope == .reviewer { q += [("scope", "all"), ("reviewer_id", String(try await currentUser().id))] }
        else { q.append(("scope", scope.rawValue)) }
        return try await get(["merge_requests"], query: q).list.map(MergeRequest.init(raw:))
    }
    public func searchMergeRequests(_ text: String, limit: Int) async throws -> [MergeRequest] {
        try await all(["merge_requests"], query: [("scope", "all"), ("state", "all"), ("search", text), ("order_by", "updated_at")], limit: limit).map(MergeRequest.init(raw:))
    }
    public func projectMergeRequests(_ project: String, query: MrQuery) async throws -> [MergeRequest] {
        try await get(["projects", project, "merge_requests"], query: Self.mrQuery(query)).list.map(MergeRequest.init(raw:))
    }
    public func mergeRequest(_ project: String, iid: Int) async throws -> MergeRequest { try await MergeRequest(raw: get(Self.mrPath(project, iid))) }
    public func mrChanges(_ project: String, iid: Int) async throws -> MrChanges {
        let r = try await get(Self.mrPath(project, iid, ["changes"]), query: [("access_raw_diffs", "true")])
        return MrChanges(diffs: r["changes"].list.map(FileDiff.init(raw:)), overflow: r["overflow"].bool ?? false)
    }
    public func mrCommits(_ project: String, iid: Int) async throws -> [Commit] { try await all(Self.mrPath(project, iid, ["commits"]), limit: 500).map(Commit.init(raw:)) }
    public func mrDiscussions(_ project: String, iid: Int) async throws -> [Discussion] { try await all(Self.mrPath(project, iid, ["discussions"]), limit: 2000).map(Discussion.init(raw:)) }
    public func mrApprovals(_ project: String, iid: Int) async throws -> Approvals { try await Approvals(raw: get(Self.mrPath(project, iid, ["approvals"]))) }

    public func mrAddNote(_ project: String, iid: Int, body: String, position: NotePosition? = nil) async throws -> Discussion {
        var fields: [String: JSONValue] = ["body": .string(body)]
        if let p = position {
            var pos: [String: JSONValue] = ["position_type": "text", "base_sha": .string(p.baseSha), "start_sha": .string(p.startSha), "head_sha": .string(p.headSha), "old_path": .string(p.oldPath), "new_path": .string(p.newPath)]
            if let line = p.oldLine { pos["old_line"] = .number(Double(line)) }
            if let line = p.newLine { pos["new_line"] = .number(Double(line)) }
            fields["position"] = .object(pos)
        }
        return try await Discussion(raw: rest.json("POST", Self.path(Self.mrPath(project, iid, ["discussions"])), body: .object(fields)))
    }
    public func mrReply(_ project: String, iid: Int, discussion: String, body: String) async throws -> MrNote {
        try await MrNote(raw: rest.json("POST", Self.path(Self.mrPath(project, iid, ["discussions", discussion, "notes"])), body: ["body": .string(body)]))
    }
    public func mrEditNote(_ project: String, iid: Int, note: Int, body: String) async throws -> MrNote {
        try await MrNote(raw: rest.json("PUT", Self.path(Self.mrPath(project, iid, ["notes", String(note)])), body: ["body": .string(body)]))
    }
    public func mrDeleteNote(_ project: String, iid: Int, note: Int) async throws { _ = try await rest.response("DELETE", Self.path(Self.mrPath(project, iid, ["notes", String(note)]))) }
    public func mrResolve(_ project: String, iid: Int, discussion: String, resolved: Bool) async throws -> Discussion {
        try await Discussion(raw: rest.json("PUT", Self.path(Self.mrPath(project, iid, ["discussions", discussion])), query: [("resolved", String(resolved))]))
    }
    public func mrApprove(_ project: String, iid: Int, approve: Bool) async throws -> Approvals {
        _ = try await rest.response("POST", Self.path(Self.mrPath(project, iid, [approve ? "approve" : "unapprove"])))
        return try await mrApprovals(project, iid: iid)
    }
    public func mrMerge(_ project: String, iid: Int, options: MergeOptions) async throws -> MergeRequest {
        var fields: [String: JSONValue] = ["squash": .bool(options.squash), "should_remove_source_branch": .bool(options.removeSourceBranch)]
        if let sha = options.sha { fields["sha"] = .string(sha) }
        return try await MergeRequest(raw: rest.json("PUT", Self.path(Self.mrPath(project, iid, ["merge"])), body: .object(fields)))
    }
    public func mrUpdate(_ project: String, iid: Int, update: MrUpdate) async throws -> MergeRequest {
        var body: [String: JSONValue] = [:]
        for (key, value) in [("title", update.title), ("description", update.description), ("target_branch", update.targetBranch), ("state_event", update.stateEvent)] { if let value { body[key] = .string(value) } }
        if let value = update.removeSourceBranch { body["remove_source_branch"] = .bool(value) }
        if let value = update.squash { body["squash"] = .bool(value) }
        return try await MergeRequest(raw: rest.json("PUT", Self.path(Self.mrPath(project, iid)), body: .object(body)))
    }
    public func mrCreate(_ project: String, input: NewMergeRequest) async throws -> MergeRequest {
        try await MergeRequest(raw: rest.json("POST", Self.path(["projects", project, "merge_requests"]), body: ["source_branch": .string(input.sourceBranch), "target_branch": .string(input.targetBranch), "title": .string(input.title), "description": .string(input.description), "remove_source_branch": .bool(input.removeSourceBranch), "squash": .bool(input.squash)]))
    }
}
