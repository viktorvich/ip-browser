import XCTest

@testable import IPBrowser

/// Websites open only when every kind that answered left from one address, and it is the profile's.
final class ExitVerdictTests: XCTestCase {
    private func seen(_ kind: String, _ port: Int, _ ip: String?, _ seconds: TimeInterval = 1) -> KindWitness {
        KindWitness(kind: kind, port: port, ip: ip, seconds: seconds)
    }

    func testFastestVerifiedKindFirst() {
        let verdict = ExitVerdict.decide(
            [seen("HOP", 1, "203.0.113.10", 2.1), seen("XHTTP", 2, "203.0.113.10", 0.8)],
            expected: "203.0.113.10")
        guard case .open(let exit, let doors) = verdict else { return XCTFail("\(verdict)") }
        XCTAssertEqual(exit, "203.0.113.10")
        XCTAssertEqual(doors.map(\.port), [2, 1])
    }

    func testSilentKindDoesNotCarryPages() {
        let verdict = ExitVerdict.decide(
            [seen("HOP", 1, nil), seen("XHTTP", 2, "203.0.113.10")], expected: "203.0.113.10")
        guard case .open(_, let doors) = verdict else { return XCTFail("\(verdict)") }
        XCTAssertEqual(doors.map(\.port), [2])
    }

    func testNoAnswer() {
        XCTAssertEqual(ExitVerdict.decide([seen("HOP", 1, nil)], expected: "203.0.113.10"), .silent)
        XCTAssertEqual(ExitVerdict.decide([], expected: nil), .silent)
    }

    func testKindsOfOneKeyDisagree() {
        let verdict = ExitVerdict.decide(
            [seen("HOP", 1, "203.0.113.10"), seen("XHTTP", 2, "198.51.100.7")], expected: nil)
        guard case .kindsDiffer = verdict else { return XCTFail("\(verdict)") }
    }

    func testAnotherExitThanTheProfiles() {
        XCTAssertEqual(
            ExitVerdict.decide([seen("HOP", 1, "198.51.100.7")], expected: "203.0.113.10"),
            .mismatch(kind: "HOP", expected: "203.0.113.10", seen: "198.51.100.7"))
    }

    /// A raw key names no exit: the first one seen is accepted, and once pinned a later round
    /// showing another address is a mismatch (the controller reads the pinned, stored profile).
    func testRawKeyPinsTheFirstExit() {
        guard case .open(let first, _) = ExitVerdict.decide([seen("HOP", 1, "203.0.113.10")], expected: nil) else {
            return XCTFail("first round")
        }
        XCTAssertEqual(
            ExitVerdict.decide([seen("HOP", 1, "198.51.100.7"), seen("XHTTP", 2, "198.51.100.7")], expected: first),
            .mismatch(kind: "HOP", expected: "203.0.113.10", seen: "198.51.100.7"))
    }
}
