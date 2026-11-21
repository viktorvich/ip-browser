# Testing

Three layers, each proving something the others cannot.

## 1. Unit tests (every change, CI)
`tools/ci.sh` — shell lint of the server scripts, then the app's build and `Tests/IPBrowserTests` on an iOS simulator:

| Test | What it proves |
|---|---|
| `LocalGateTests` | the gate against stand-in doors that, like Xray's HTTP inbound, say «200» before reaching anything: a silent door hands a TLS ClientHello to the next verified door within its patience; a closing door hands a GET over at once but never a POST it already took; TLS early data and pipelined requests are not replayed; a wrong credential gets 407, another profile 503; a page waits while its exit is verified |
| `NAT64Tests` | on an IPv6-only network every IPv4 literal the core dials (`address`, the HOP list `remoteIPs`) becomes the synthesized IPv6 address and the TLS name stays the server's; on other networks nothing changes |
| `ExitVerdictTests` | websites open only when every kind that answered left from one address and it is the profile's; a raw key's first exit is pinned |
| `AccessKeyTests` | keys round-trip; plain Hysteria 2 (no Salamander) and VLESS without XHTTP/TLS or without VLESS Encryption are refused, also inside a key |
| `UploadTests` | an image picked from Files reaches the page without GPS, camera or date metadata; other files go unchanged |

## 2. The server's whole life (before a release that touches `Server/`)
`tools/vm-test.sh <debian-or-ubuntu-cloud-image.qcow2> fresh|upgrade <older install.sh>` runs `Server/test/lifecycle.sh` in a throwaway KVM guest: install (root, or an ordinary sudo user with a password), management through the app's restricted key, revocation rules (another device, this phone, the last device), the HOP-only web front, and `uninstall` — the firewall must be identical to before and no app key may remain.

An IPv6-only network (App Review's) is not something a simulator can join. What the app sends there was run in a throwaway
Linux guest: a network namespace with no IPv4 at all and NAT64 (tayga, 64:ff9b::/96) as its only way out, the same Xray
core with a real server's key, once with the IPv4 address and once rewritten as `NAT64.rewrite` does. On a phone, Apple's
way is a Mac's Internet Sharing with «Create NAT64 Network».

## 3. Real runs on a simulator or a phone (Debug builds)
`App/Sources/Debug/LabHooks.swift` — launch with one argument, read the `IPB_*` lines:
`xcrun simctl launch --console-pty <device> app.ipbrowser.pos2 -labfailover`

| Argument | Run |
|---|---|
| `-labfailover` | a page opens; then the first kind's packets stop (a relay on the Mac carries both kinds and drops UDP on a signal); a new page on the same host and one on a new host must open by themselves |
| `-labreturn` | profile A → B → A: A's tab shows its page again by itself |
| `-labnetchange` | a fresh core after a network change starts closed; a page asked meanwhile waits and leaves only after every answering kind was verified |
| `-labpending` | on a phone without servers, an address typed first opens in the first server added |
| `-labprofiles` | a cookie and storage set in one profile are invisible in another and back in the first |
| `-selftest` | the leak test page's result as JSON (exit, WebRTC candidates, clock in every context, location) |
| `-probekinds`, `-labmanage`, `-labinstall host:port user @file` | each kind's exit; add and revoke a device; the install screen's code path |
| `-wtprobe <url>`, `-clock`, `-strict`, `-phoneclock`, `-shieldoff` | WebTransport, the clock battery, strict mode, the unprotected baselines |

A key is given to a simulator by writing it to the app's `Documents/import-key.txt` (it is imported and the file deleted at start). Measurements behind `docs/LEAKS.md` were made this way and on an iPhone with iOS 26.3.1.
