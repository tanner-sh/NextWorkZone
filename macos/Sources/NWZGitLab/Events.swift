import Foundation
import NWZCore

public struct GitLabEvent: Codable, Hashable, Sendable {
    public var at: String
    public var kind: String
    public var projectId: Int
    public var title: String
    public var detail: String
    public var iid: Int?
    public var commitCount: Int
    public init?(raw r: JSONDocument) {
        guard let id = r["project_id"].number.map(Int.init) else { return nil }
        projectId = id; at = r["created_at"].text; title = r["target_title"].text; detail = ""; iid = r["target_iid"].number.map(Int.init); commitCount = 0
        let action = r["action_name"].text, type = r["target_type"].text
        switch (action, type) {
        case ("pushed to", _), ("pushed new", _):
            let push = r["push_data"]; kind = "push"; title = push["ref"].text; detail = push["commit_title"].text; commitCount = push["commit_count"].int
            if commitCount <= 0 { return nil }
        case ("opened", "MergeRequest"): kind = "mr_open"
        case ("accepted", "MergeRequest"): kind = "mr_merge"
        case ("approved", "MergeRequest"): kind = "mr_approve"
        case ("closed", "MergeRequest"): kind = "mr_close"
        case ("commented on", _):
            let note = r["note"]; kind = "comment"
            detail = String(String.UnicodeScalarView(note["body"].text.split(whereSeparator: \.isWhitespace).joined(separator: " ").unicodeScalars.prefix(120)))
            if note["noteable_type"].text == "MergeRequest" { iid = note["noteable_iid"].number.map(Int.init) }
        default: return nil
        }
    }
}
