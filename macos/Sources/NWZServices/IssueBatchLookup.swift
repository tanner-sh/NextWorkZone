import Foundation
import NWZCore
import NWZJira

/// 批量读取问题；仅在查询本身无效时拆分，认证或网络失败不逐个放大请求。
public enum IssueBatchLookup {
    public static func fetch(
        _ keys: [String],
        search: @Sendable ([String]) async throws -> [IssueSummary]
    ) async -> [String: IssueSummary] {
        var found: [String: IssueSummary] = [:]
        var offset = 0
        while offset < keys.count && !Task.isCancelled {
            let end = min(offset + 100, keys.count)
            var pending = [Array(keys[offset..<end])]
            var attempts = 0
            offset = end
            // 最多 20 次：错误数据很多时保留已得到的结果，不再无界拆分。
            while let batch = pending.popLast(), attempts < 20, !Task.isCancelled {
                attempts += 1
                do {
                    let issues = try await search(batch)
                    guard !Task.isCancelled else { return found }
                    for issue in issues { found[issue.key] = issue }
                } catch let error as NWZError {
                    guard !Task.isCancelled else { return found }
                    if case .http(400, _) = error {
                        guard batch.count > 1 else { continue }
                        let middle = batch.count / 2
                        pending.append(Array(batch[middle...]))
                        pending.append(Array(batch[..<middle]))
                    } else {
                        return found
                    }
                } catch {
                    return found
                }
            }
        }
        return found
    }
}
