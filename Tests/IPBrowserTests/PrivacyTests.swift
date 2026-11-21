import Crypto
import XCTest

@testable import IPBrowser

/// What stays on the phone, what a shared log shows, what the console runs.
final class PrivacyTests: XCTestCase {
    func testBrowsingDataIsKeptOutOfBackups() throws {
        LocalData.keepOutOfBackups()
        for directory in LocalData.keptOutOfBackups {
            let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true, directory.lastPathComponent)
        }
    }

    func testSharedLogHidesAddresses() {
        let shared = ConnectionLog.hidingAddresses(
            "exit check: 203.0.113.10 — HOP (UDP) 0.5 s\nserver «198.51.100.7»: start\nIP Browser 1.0.0 (22) · Xray 26.11.9"
        )
        XCTAssertFalse(shared.contains("203.0.113.10"))
        XCTAssertFalse(shared.contains("198.51.100.7"))
        XCTAssertTrue(shared.contains("HOP (UDP) 0.5 s"))
        XCTAssertTrue(shared.contains("1.0.0 (22) · Xray 26.11.9"), "version numbers are not addresses")
    }

    func testConsoleRunsExactlyTheBundledInstaller() {
        let script = Data("#!/bin/bash\necho hello\n".utf8)
        let sum = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        let command = Settings.consoleCommand(for: script)
        XCTAssertTrue(command.contains("/installer-\(sum.prefix(12))/Server/install.sh"))
        XCTAssertTrue(command.contains("echo \"\(sum)  ipb.sh\" | sha256sum -c -"))
        XCTAssertFalse(command.contains("/main/"), "never a moving branch")
        XCTAssertFalse(Settings.consoleCommand.isEmpty)
    }
}
