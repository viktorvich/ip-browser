# Changelog

## 1.0.1 — private test build 30 (public release held)

- Copy a profile from its context menu to create an independent browser on the same server. Cookies, website storage,
  tabs, favorites and history stay separate, including after restart. Copies do not inherit server administration keys.
- Block WebKit DNS-prefetch/preconnect through native content rules before a resolver request is sent. This also blocks
  link auditing and sendBeacon. Regular page loads, fetch and XHR remain available.
- Require the protection rules before opening a page. Describe the embedded test as a local check and link to an external
  DNS test instead of treating JavaScript checks as proof of the network path.
- Physical iPhone Air acceptance covers both regional exits over Wi-Fi and cellular, with Stash connected and disconnected.
  Packet capture confirms the DNS-prefetch bypass is absent in those tests; the old iPhone Tashkent app reproduced it.

## 1.0.0 — App Store build 29

The first public version.

- **License**: dual: open source under the GNU AGPL v3.0 or later, plus a commercial license on request. The name and icon
  are not licensed. The source published before 21.11.2026 was under MIT.

- **Browser**: start page with favorites and recent sites, tabs with previews, bookmarks and history on the phone, find on
  page, share, downloads; Russian and English.
- **One exit**: an in-app Xray core with no direct outbound behind a loopback gate WebKit cannot go around; every connection's
  exit is verified before it carries a page, again after each network change and every 10 minutes.
- **Your own server from the phone**: SSH install of Hysteria 2 (UDP) and VLESS Encryption over XHTTP next to a
  small website with a Let's Encrypt certificate (TCP) on Ubuntu 22.04/24.04 and Debian 12/13; plain-word errors for every failure; a web-console
  fallback that prints a key and a QR code.
- **Failover while browsing**: a kind that goes silent hands new connections to the other kind; only bytes that cannot have
  had an effect at the site are repeated.
- **Profiles**: one separate browser per server (cookies, storage, tabs, favorites, history, clock), switched at the top.
- **Looks local**: the server's time zone in windows, frames and Blob workers (not in a site's service worker or workers
  loaded from a script file); Safari's user agent; location denied.
- **Leak protection and test**: WebRTC, WebTransport and passkey lookups removed before page scripts; Lockdown on
  iOS 26.4–26.x; *Settings → Leak test*.
- **IPv6-only networks**: the core and the installer dial the address iOS synthesizes on NAT64 networks (proven through a lab
  NAT64, not yet on a physical iPhone).
- **Server management**: devices added and revoked from the app through a single restricted command; a management key lives
  only as long as its device; `uninstall` removes exactly what was added.
- **Privacy at rest**: history, favorites, tabs, the connection log and websites' data are excluded from iCloud and computer
  backups; the connection log a person shares hides addresses; a changed SSH key is accepted only as the exact key confirmed.
