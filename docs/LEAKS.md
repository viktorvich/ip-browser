# Leaks past WebKit's proxy — what was measured and what IP Browser does

iOS lets a browser route WebKit through a proxy (`WKWebsiteDataStore.proxyConfigurations`, iOS 17+). Some WebKit features ignore it and connect from the device itself, which reveals the device's real address. We measured them on iOS 26.4, 27.0 and 27.2 simulators and on an iPhone Air with iOS 26.3.1 (November 2026), with the tunnel up and a real exit server.

## Method

- **WebRTC**: the built-in leak test (`App/Resources/selftest.html`) creates `RTCPeerConnection` with public STUN servers in the main page, a markup iframe, a script-created iframe, an iframe inserted through *another* frame's untouched `appendChild`, `srcdoc`, sandboxed and `blob:` frames, and records every ICE candidate. A `srflx` candidate carries the address the STUN server saw.
- **WebTransport**: a page and a dedicated worker open `new WebTransport('https://<lab-host>:4433/')`; `tcpdump` on the lab host records whether QUIC packets arrive from the device directly.
- **DNS prefetch, WebAuthn Related Origin Requests, WebTransport (window)**: the public test by Mysk, https://leaks.psylo.app (see their report of 4 August 2026).

## Results

| Channel | Without protection | IP Browser |
|---|---|---|
| WebRTC | iOS 26.4 and 27.2: `srflx` candidate with the device's real address while websites saw the server | Removed in every frame before page scripts: 0 candidates (iOS 26.3.1 device, 26.4, 27.2) |
| WebTransport | iOS 26.4: QUIC Initial packets from the device straight to the target, from a page **and from a worker**. iOS 27.0 and 27.2: rejected through a proxy, no packet | Removed in every frame; on iOS 26.4–26.x the app turns on WebKit Lockdown, which removes it from the engine, workers included: 0 packets |
| DNS prefetch | No leak observed (iOS 26.4, 27.2) | — |
| Kinds of one server | Before 21.11.2026 the core balanced the kinds by ping and only the chosen path was witnessed; after a network change pages were let through before the new core was witnessed | Every kind is witnessed through its own door; pages pass only through kinds whose exit is the server's, and a new core starts closed (pages wait up to 12 s). A kind that stops answering while browsing hands new connections to the other kind of the same server — never to another way out |
| WebAuthn ROR | iOS 27.2: request went through the proxy | Passkeys switched off (`PublicKeyCredential` removed) |
| Website DNS | Resolved by the server (the test showed the server's country resolver) | — |
| Time zone | Pages saw the phone's zone (e.g. Moscow) next to the server's address | The server's zone in every window, frame and Blob worker: 7 of 7 contexts `Asia/Tashkent`, UTC+5 (iOS 27.2, exit in Tashkent, zone learned through the tunnel) |
| Location | The request stayed unanswered (the app has no location permission) | Answered «denied» at once, like Safari |
| User agent | WebKit's default without `Safari/`: an embedded browser | Safari's own: `… Version/27.2 Mobile/15E148 Safari/604.1`; Google sign-in page and Cloudflare Turnstile pass (20.11.2026) |
| Between profiles | — (one shared store before build 17) | Each profile its own website store and gate credential. iOS 27.2: a cookie and a `localStorage` value set by a site in profile «Finland» are absent in «Tashkent» (`{"cookies": {}}`, `null`) and present again back in «Finland»; each profile sees its own exit and zone (21.11.2026) |

Not covered by any app: iOS system services (software updates, certificate status, Apple's content lists) use the normal network. They are not website traffic.

## Check it yourself

In the app: **Settings → Leak test**. It shows the exit address, the number of WebRTC candidates, every frame where a leaking feature would be reachable, the clock pages see in every context and the location answer.

Not covered: a site's service worker, or a worker loaded from a script file, sees the phone's own time zone (WebKit runs no page script there). Accept-Language and `navigator.language` stay the phone's language: they say which language you read, not where you are.
