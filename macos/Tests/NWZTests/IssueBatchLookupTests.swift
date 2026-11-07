import NWZCore
import NWZJira
import NWZServices
import Testing

private actor IssueBatchProbe {
    enum Behavior { case unauthorized, invalidKey, alwaysInvalid }
    let behavior: Behavior
    private(set) var calls: [[String]] = []

    init(_ behavior: Behavior) { self.behavior = behavior }

    func search(_ keys: [String]) throws -> [IssueSummary] {
        calls.append(keys)
        switch behavior {
        case .unauthorized: throw NWZError.unauthorized(401)
        case .alwaysInvalid: throw NWZError.http(400, "invalid")
        case .invalidKey:
            if keys.contains("BAD-1") { throw NWZError.http(400, "invalid") }
            return keys.map { IssueSummary(key: $0, summary: $0, status: JiraStatus(name: "Open", category: "new"), issueType: Named(name: "Task"), project: Named(name: "Test"), created: "", updated: "") }
        }
    }
}

struct IssueBatchLookupTests {
    @Test func authenticationFailureDoesNotFanOut() async {
        let probe = IssueBatchProbe(.unauthorized)
        let keys = (1...100).map { "TEST-\($0)" }
        let result = await IssueBatchLookup.fetch(keys) { try await probe.search($0) }
        #expect(result.isEmpty)
        #expect(await probe.calls.count == 1)
    }

    @Test func invalidKeyIsIsolatedAndOtherResultsSurvive() async {
        let probe = IssueBatchProbe(.invalidKey)
        let result = await IssueBatchLookup.fetch(["TEST-1", "BAD-1", "TEST-2", "TEST-3"]) { try await probe.search($0) }
        #expect(Set(result.keys) == Set(["TEST-1", "TEST-2", "TEST-3"]))
        #expect(await probe.calls.count <= 7)
    }

    @Test func invalidBatchHasABoundedRetryBudget() async {
        let probe = IssueBatchProbe(.alwaysInvalid)
        let result = await IssueBatchLookup.fetch((1...100).map { "TEST-\($0)" }) { try await probe.search($0) }
        #expect(result.isEmpty)
        #expect(await probe.calls.count == 20)
    }
}
