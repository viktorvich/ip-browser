import XCTest

@testable import IPBrowser

/// On an IPv6-only network every IPv4 literal the core dials becomes the synthesized IPv6 address, while the
/// TLS name stays; on any other network nothing changes.
final class NAT64Tests: XCTestCase {
    private let hop: [String: Any] = [
        "protocol": "hysteria",
        "settings": ["address": "203.0.113.10", "port": 443],
        "streamSettings": [
            "security": "tls", "tlsSettings": ["serverName": "example.net"],
            "finalmask": [
                "udp": [["type": "udphop", "settings": ["remoteIPs": ["203.0.113.10"], "remotePorts": "20000-29999"]]]
            ],
        ],
    ]
    private let xhttp: [String: Any] = [
        "protocol": "vless",
        "settings": ["address": "203.0.113.10", "port": 443],
        "streamSettings": ["security": "tls", "tlsSettings": [String: Any]()],
    ]
    private let synthesize: (String) -> String? = { "64:ff9b::" + $0 }

    func testIPv6OnlyNetworkDialsTheSynthesizedAddress() throws {
        let out = NAT64.rewrite(hop, resolve: synthesize)
        let settings = try XCTUnwrap(out["settings"] as? [String: Any])
        XCTAssertEqual(settings["address"] as? String, "64:ff9b::203.0.113.10")
        let stream = try XCTUnwrap(out["streamSettings"] as? [String: Any])
        XCTAssertEqual((stream["tlsSettings"] as? [String: Any])?["serverName"] as? String, "example.net")
        let hopList =
            ((stream["finalmask"] as? [String: Any])?["udp"] as? [[String: Any]])?.first?["settings"] as? [String: Any]
        XCTAssertEqual(hopList?["remoteIPs"] as? [String], ["64:ff9b::203.0.113.10"])
        XCTAssertEqual(hopList?["remotePorts"] as? String, "20000-29999")
    }

    func testTlsNameStaysTheIPv4Address() throws {
        let out = NAT64.rewrite(xhttp, resolve: synthesize)
        let stream = try XCTUnwrap(out["streamSettings"] as? [String: Any])
        XCTAssertEqual(
            (stream["tlsSettings"] as? [String: Any])?["serverName"] as? String, "203.0.113.10",
            "the certificate is checked for the server's own address")
    }

    func testOtherNetworksChangeNothing() throws {
        let out = NAT64.rewrite(hop, resolve: { _ in nil })
        XCTAssertEqual((out["settings"] as? [String: Any])?["address"] as? String, "203.0.113.10")
        // and on this (IPv4) network the system says so itself
        XCTAssertNil(NAT64.address(for: "8.8.8.8"))
        XCTAssertNil(NAT64.address(for: "example.com"), "names are left to the system resolver")
    }
}
