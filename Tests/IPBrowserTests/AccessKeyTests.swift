import XCTest

@testable import IPBrowser

/// Only masked kinds become profiles, and a key carries its name, exit and links unchanged.
final class AccessKeyTests: XCTestCase {
    private let hop =
        "hy2://phone:secret@203.0.113.10:443,20000-29999/?sni=example.net&obfs=salamander"
        + "&obfs-password=mask&pcs=abc#HOP"
    private let xhttp =
        "vless://00000000-0000-4000-8000-000000000000@203.0.113.10:443?encryption=mlkem768x25519plus.native.0rtt.key"
        + "&security=tls&type=xhttp&path=%2Fp&mode=auto&alpn=h2&fp=chrome#XHTTP"

    func testKeyRoundTrip() throws {
        let key = AccessKey.encode(name: "My server", exit: "203.0.113.10", links: [hop, xhttp])
        let parsed = try AccessKey.parse(key)
        XCTAssertEqual(parsed.name, "My server")
        XCTAssertEqual(parsed.exit, "203.0.113.10")
        XCTAssertEqual(parsed.links, [hop, xhttp])
    }

    func testRawLinksAreAccepted() throws {
        let parsed = try AccessKey.parse(hop + "\n" + xhttp + "\n")
        XCTAssertEqual(parsed.links.count, 2)
        XCTAssertNil(parsed.exit, "a raw link names no exit: the first verified one is pinned later")
        XCTAssertEqual(parsed.name, "HOP")
    }

    func testHysteriaWithoutSalamanderIsRefused() {
        let plain = "hy2://phone:secret@203.0.113.10:443/?sni=example.net#plain"
        XCTAssertThrowsError(try AccessKey.parse(plain)) { error in
            XCTAssertEqual(error as? AccessKey.Problem, .unmasked("hop"))
        }
        let emptyPassword = plain.replacingOccurrences(of: "#plain", with: "&obfs=salamander&obfs-password=#x")
        XCTAssertThrowsError(try AccessKey.parse(emptyPassword))
    }

    func testVlessWithoutEncryptionOrXhttpIsRefused() {
        let none = xhttp.replacingOccurrences(
            of: "encryption=mlkem768x25519plus.native.0rtt.key", with: "encryption=none")
        XCTAssertThrowsError(try AccessKey.parse(none)) { error in
            XCTAssertEqual(error as? AccessKey.Problem, .unmasked("encryption"))
        }
        let reality = xhttp.replacingOccurrences(of: "security=tls", with: "security=reality")
        XCTAssertThrowsError(try AccessKey.parse(reality)) { error in
            XCTAssertEqual(error as? AccessKey.Problem, .unmasked("xhttp"))
        }
        let tcp = xhttp.replacingOccurrences(of: "type=xhttp", with: "type=tcp")
        XCTAssertThrowsError(try AccessKey.parse(tcp))
    }

    func testOneUnmaskedLinkRefusesTheWholeKey() {
        let key = AccessKey.encode(name: "x", exit: nil, links: [hop, "hy2://a:b@203.0.113.10:443/#plain"])
        XCTAssertThrowsError(try AccessKey.parse(key))
    }

    func testNotAKey() {
        XCTAssertThrowsError(try AccessKey.parse("hello")) { error in
            XCTAssertEqual(error as? AccessKey.Problem, .invalid)
        }
        XCTAssertThrowsError(try AccessKey.parse("ipbrowser://add?n=x&l=%%%"))
    }
}
