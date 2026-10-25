import NWZCore

enum AppPreferences {
    static let shared = PreferencesStore(path: AppPaths.current().data.appendingPathComponent("preferences.plist"))
}
