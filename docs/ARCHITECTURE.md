# Architecture

## One route
```
WKWebView ──(WKWebsiteDataStore.proxyConfigurations: HTTP CONNECT, allowFailover = false)──▶ LocalGate 127.0.0.1:<port>
   LocalGate: one credential per profile's website store, open only for the active profile after its exit was verified,
              and the exit witness's (IP-echo and time-zone hosts only)
──▶ Xray core inside the app (libXray): HTTP inbound with a session credential; outbounds = only the profile's server;
    NO freedom/direct outbound; private, reserved and local destinations and UDP are blackholed
──▶ HOP (Hysteria 2 + Salamander, UDP 443 + hopping, pinned certificate)  and/or  XHTTP (VLESS Encryption over XHTTP, TLS)
──▶ the server: IPv4 only, local destinations refused, website DNS resolved there ──▶ the internet from one address
```

- **Kill switch by construction.** There is no direct path in the core and no failover in WebKit's proxy setting. If the server is unreachable, requests fail.
- **Exit witness, per connection.** The core has one loopback door per connection kind of the server, each routed only to that kind; there is no shared door and no balancer in the core. Before the first page, after every network change (Wi-Fi/mobile, another network app switched on or off; a fresh core) and every 10 minutes, the app fetches `checkip.amazonaws.com` (or `api.ipify.org`) through *each* door and compares every answer with the server's address. Pages pass LocalGate only through a door whose own exit was seen, the fastest first. A kind that did not answer is asked again (30 s, doubling to 5 min) and joins once its exit is seen. While a new core is being verified, page requests wait up to 12 s in LocalGate instead of failing. A transient outage shows *Reconnecting*; pages and forms are kept. Any kind leaving from a different address closes the browser until the person decides.
- **A kind that stops answering.** The core says «200» to a CONNECT before it has reached anything, so LocalGate trusts a door with a connection only once the site's first bytes came back through it. Until then it keeps what the browser sent (a TLS ClientHello) and gives it to the next verified door if this one closes without an answer; for TLS it also runs the next door alongside a door that stays silent longer than its patience (twice its witness time, 1.5–6 s). A plain request is never sent twice. A connection WebKit keeps open (HTTP/2) cannot be handed over: when a request through it hears nothing for longer than the door's patience while nothing else comes through that door, the door is probed once; a dead door stops carrying pages and its silent connections are closed, so WebKit opens new ones through the kind that answers. Measured with UDP stopped on the way while TCP worked: a new page on the same host 8.3 s, on a new host 2.3 s, no retry (`docs/TESTING.md`, lab `-labfailover`).
- **IPv6-only networks** (NAT64/DNS64 — some carriers, and App Review's network). The core dials the server's address itself; on such a network an IPv4 literal has no route, so the app gives the core the IPv6 address iOS synthesizes for it (`getaddrinfo`, Apple's documented way), keeping the TLS name and the expected exit; on other networks nothing changes (`NAT64.swift`). The same for the SSH installer.
- **Diagnosis without restarts.** When no kind answers for 20 seconds, the witness results say which kind does not get through from this network, in plain words. The core is never restarted on a dead path.
- **The server's clock.** The time zone of the exit address is asked once per address through the server (ipapi.co, then ipwho.is, then api.ip.sb) before the first page and kept on the phone. The page script (`App/Resources/zone.js`) then gives every window, frame and Blob worker that zone: `Date` (fields, setters, parsing, text), `Intl.DateTimeFormat`, `toLocale*String`, `document.lastModified`, `Temporal.Now`. Our functions print the native source text, so a page sees the same `[native code]` as before. Measured in WebKit: patched to the simulator's own zone, a 33-line battery of every Date/Intl entry prints byte-for-byte what the unpatched engine prints. Not covered: service workers and workers loaded from a script URL (WebKit runs no page script there).
- **Safari to websites.** The user agent is Safari's own (`Version/<iOS> Mobile/15E148 Safari/604.1`): Google sign-in and bot checks see Safari, not an unknown embedded browser. Location requests are answered «denied» at once, as Safari does when location is not allowed.
- **One server = one exit.** Every kind of a profile is verified to leave from the same address before it carries a page; the core contacts nothing but the profile's server (no observatory pings).
- **Why LocalGate.** WebKit applies a proxy only to a data store configured before its first load. LocalGate's port and each profile's credential stay the same for the whole app session; the core behind it can switch servers.

## Profiles
One server = one profile = a separate browser, like Safari's profiles. Each profile has its own persistent `WKWebsiteDataStore(forIdentifier:)` (cookies, local storage, IndexedDB, caches, service workers, HSTS), its own `WKWebViewConfiguration` (the shield carrying that exit's clock), its own tabs, favorites and history (`Application Support/Library/<profile>`). Switching closes the old profile's pages (their addresses are kept and reopen when you come back), closes the gate, starts the new server's core, verifies its exit and opens the gate **for that profile's credential only**: a leftover connection or a worker of another profile gets 503 from LocalGate and can never ride another profile's server. The profile bar names each profile by its exit country (asked once with the time zone) unless the person named it. Removing a profile deletes its website store and library. Builds ≤ 16 had one shared store: on update it stays with the profile that was active, the others start clean. The device's own traits (model, screen, iOS version, fonts) are the same in every profile — as with Safari's profiles.

## The shield
A user script injected at document start into every frame removes `RTCPeerConnection` and the rest of WebRTC, `WebTransport`, and `PublicKeyCredential`, and hardens every way a page can reach a fresh child frame (iframe getters, all DOM insertion methods in every realm, `window.open`, `document.write`). `data:` subframe navigations are refused. On iOS 26.4–26.x — where WebKit sends WebTransport past the proxy even from workers — Lockdown Mode is forced for every page. See [LEAKS.md](LEAKS.md).

## Setup over SSH
`App/Sources/Setup/SSHExec.swift` is a minimal client on Apple's swift-nio-ssh: password or ed25519, host key pinned on first contact (a changed key shows its SHA256 fingerprint and asks), one exec channel with stdin. `ServerInstaller` uploads `Server/install.sh` to a private temporary file of the login user and runs it as root from there (through `sudo -S` only when sudo wants the password), streams `@@step`/`@@warn`/`@@error`/`@@result` lines and turns every failure into words (`InstallErrors.swift`). The app keeps its own ed25519 key for later management (new devices, revocation) — tied on the server to this phone's device and limited to one command — and never stores the password. A reinstall from the same phone names its previous device and key, and the server retires them. See [SERVER.md](SERVER.md).

## Code map
| Path | What it is |
|---|---|
| `App/Sources/Core/LocalGate.swift` | the loopback proxy WebKit uses: roles, admission, per-connection door choice, stalled doors |
| `App/Sources/Core/TunnelController.swift` | the route's state: core start, the exit witness per kind (`ExitVerdict`), network changes, re-checks |
| `App/Sources/Core/XrayEngine.swift` | the core's configuration (one door per kind, no direct outbound) and libXray calls |
| `App/Sources/Core/NAT64.swift` | IPv6-only networks: the synthesized address for an IPv4 server |
| `App/Sources/Core/AccessKey.swift` | `ipbrowser://` keys and share links; only the two supported kinds are accepted |
| `App/Sources/Browser/` | the browser: `BrowserController` (interface, navigation), `+Profiles` (one browser per server), `+WebKit` (WebKit's delegates, downloads), `Uploads` (metadata-free images), `Shield` (the page script), `Library` |
| `App/Sources/Setup/` | the SSH client, the installer driver, error words |
| `App/Sources/UI/` | SwiftUI screens: start page, profile bar, servers, settings |
| `App/Sources/Debug/LabHooks.swift` | measurement hooks of Debug builds only (`docs/TESTING.md`) |
| `Server/install.sh`, `Server/test/` | the whole server side and its lifecycle test |
| `Tests/IPBrowserTests/` | unit tests |

## Choices
- **In-app core, not a Network Extension**: only the browser's traffic, no conflict with other network apps on the phone.
- **Xray-core through libXray** (MPL-2.0/MIT): one engine for both kinds. No GPL core (such as sing-box): its code would rule out the commercial license.
- **Only public APIs.** No private WebKit selectors, no swizzling.
