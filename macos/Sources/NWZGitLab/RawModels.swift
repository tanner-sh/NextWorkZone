import Foundation
import NWZCore

extension Project {
    public init(raw r: JSONDocument) {
        id = r["id"].int
        name = r["name"].text
        pathWithNamespace = r["path_with_namespace"].text
        description = r["description"].string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        defaultBranch = r["default_branch"].string
        webUrl = r["web_url"].text
        lastActivityAt = r["last_activity_at"].text
        removeSourceBranchAfterMerge = r["remove_source_branch_after_merge"].bool
        squashOption = r["squash_option"].string
    }
}

extension Commit {
    public init(raw r: JSONDocument) {
        id = r["id"].text
        shortId = r["short_id"].text
        title = r["title"].text
        message = r["message"].text
        authorName = r["author_name"].text
        authoredDate = r["authored_date"].text
        webUrl = r["web_url"].string
    }
}

extension Branch {
    public init(raw r: JSONDocument) {
        name = r["name"].text
        `default` = r["default"].bool ?? false
        protected = r["protected"].bool ?? false
        merged = r["merged"].bool ?? false
        commit = Commit(raw: r["commit"])
    }
}

extension TreeEntry {
    public init(raw r: JSONDocument) {
        name = r["name"].text
        path = r["path"].text
        kind = r["type"].text
    }
}

extension FileDiff {
    public init(raw r: JSONDocument) {
        oldPath = r["old_path"].text
        newPath = r["new_path"].text
        diff = r["diff"].text
        newFile = r["new_file"].bool ?? false
        deletedFile = r["deleted_file"].bool ?? false
        renamedFile = r["renamed_file"].bool ?? false
    }
}

extension GlUser {
    public init(raw r: JSONDocument) {
        id = r["id"].int
        username = r["username"].text
        name = r["name"].text
    }
}

extension DiffRefs {
    public init(raw r: JSONDocument) {
        baseSha = r["base_sha"].text
        headSha = r["head_sha"].text
        startSha = r["start_sha"].text
    }
}

extension Pipeline {
    public init(raw r: JSONDocument) {
        id = r["id"].int
        status = r["status"].text
        webUrl = r["web_url"].string
    }
}

extension MergeRequest {
    public init(raw r: JSONDocument) {
        id = r["id"].int
        iid = r["iid"].int
        projectId = r["project_id"].int
        title = r["title"].text
        description = r["description"].text
        state = r["state"].text
        draft = r["draft"].bool ?? false
        author = GlUser(raw: r["author"])
        assignees = r["assignees"].list.map(GlUser.init(raw:))
        reviewers = r["reviewers"].list.map(GlUser.init(raw:))
        sourceBranch = r["source_branch"].text
        targetBranch = r["target_branch"].text
        sourceProjectId = r["source_project_id"].number.map(Int.init)
        createdAt = r["created_at"].text
        updatedAt = r["updated_at"].text
        mergedAt = r["merged_at"].string
        mergedBy = r["merged_by"].isNull ? nil : GlUser(raw: r["merged_by"])
        closedAt = r["closed_at"].string
        closedBy = r["closed_by"].isNull ? nil : GlUser(raw: r["closed_by"])
        mergeStatus = r["merge_status"].text
        hasConflicts = r["has_conflicts"].bool ?? false
        userNotesCount = r["user_notes_count"].int
        upvotes = r["upvotes"].int
        labels = r["labels"].list.map(\.text)
        webUrl = r["web_url"].text
        reference = r["references"]["full"].text
        changesCount = r["changes_count"].string
        sha = r["sha"].string
        diffRefs = r["diff_refs"].isNull ? nil : DiffRefs(raw: r["diff_refs"])
        headPipeline = r["head_pipeline"].isNull ? nil : Pipeline(raw: r["head_pipeline"])
        squash = r["squash"].bool ?? false
        forceRemoveSourceBranch = r["force_remove_source_branch"].bool
        blockingDiscussionsResolved = r["blocking_discussions_resolved"].bool ?? true
        mergeError = r["merge_error"].string
        mergeWhenPipelineSucceeds = r["merge_when_pipeline_succeeds"].bool ?? false
        canMerge = r["user"]["can_merge"].bool ?? false
    }
}

extension NotePosition {
    public init(raw r: JSONDocument) {
        baseSha = r["base_sha"].text
        startSha = r["start_sha"].text
        headSha = r["head_sha"].text
        oldPath = r["old_path"].text
        newPath = r["new_path"].text
        oldLine = r["old_line"].number.map(Int.init)
        newLine = r["new_line"].number.map(Int.init)
    }
}

extension MrNote {
    public init(raw r: JSONDocument) {
        id = r["id"].int
        body = r["body"].text
        author = GlUser(raw: r["author"])
        createdAt = r["created_at"].text
        updatedAt = r["updated_at"].string
        system = r["system"].bool ?? false
        resolvable = r["resolvable"].bool ?? false
        resolved = r["resolved"].bool ?? false
        resolvedBy = r["resolved_by"].isNull ? nil : GlUser(raw: r["resolved_by"])
        position = Self.textPosition(r["position"])
    }
}

extension Discussion {
    public init(raw r: JSONDocument) {
        id = r["id"].text
        individualNote = r["individual_note"].bool ?? false
        notes = r["notes"].list.map(MrNote.init(raw:))
    }
}

extension Approvals {
    public init(raw r: JSONDocument) {
        approved = r["approved"].bool ?? false
        userHasApproved = r["user_has_approved"].bool ?? false
        userCanApprove = r["user_can_approve"].bool ?? false
        approvedBy = r["approved_by"].list.map { GlUser(raw: $0["user"]) }
    }
}

extension MrNote {
    static func textPosition(_ r: JSONDocument) -> NotePosition? {
        guard r["position_type"].text == "text", ["base_sha", "start_sha", "head_sha", "old_path", "new_path"].allSatisfy({ r[$0].string != nil }) else { return nil }
        return NotePosition(raw: r)
    }
}
