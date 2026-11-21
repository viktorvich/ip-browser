import Foundation

/// What the browser keeps of a person's browsing stays on this phone: history, favorites, tabs, the connection log
/// (Application Support) and websites' own data (WebKit's stores) are excluded from iCloud and computer backups. Run at
/// every launch, so files made by earlier versions are covered too. Access keys live in the Keychain, this device only.
enum LocalData {
    static var keptOutOfBackups: [URL] {
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return [
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            library.appendingPathComponent("WebKit", isDirectory: true),
        ]
    }

    static func keepOutOfBackups() {
        for directory in keptOutOfBackups {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }
}
