import Foundation
import Testing
@testable import NWZCore

struct PreferencesTests {
    @Test func isolatedPreferencesPersistSupportedValues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first/preferences.plist")
        let store = PreferencesStore(path: first)
        store.set("notes", forKey: "page")
        store.set(["a", "b"], forKey: "tags")
        store.set([1, 2], forKey: "projects")
        store.set(["project": "PROJ"], forKey: "form")
        store.set(Data([1, 0, 2]), forKey: "draft")
        store.set(42, forKey: "number")
        let reopened = PreferencesStore(path: first)
        #expect(reopened.string(forKey: "page") == "notes")
        #expect(reopened.stringArray(forKey: "tags") == ["a", "b"])
        #expect(reopened.array(forKey: "projects") as? [Int] == [1, 2])
        #expect(reopened.dictionary(forKey: "form")?["project"] as? String == "PROJ")
        #expect(reopened.data(forKey: "draft") == Data([1, 0, 2]))
        #expect(reopened.integer(forKey: "number") == 42)
        #expect(PreferencesStore(path: root.appendingPathComponent("second/preferences.plist")).string(forKey: "page") == nil)
        reopened.removeObject(forKey: "draft")
        #expect(PreferencesStore(path: first).data(forKey: "draft") == nil)
    }
}
