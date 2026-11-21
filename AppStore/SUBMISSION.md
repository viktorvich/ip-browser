# Submitting IP Browser to the App Store

Everything App Store Connect asks for, in the order it asks. The texts are in `metadata/<locale>/`, the review notes
in `review_notes.txt`, the screenshots are made by `tools/screenshots.sh`.

## 1. The app record (App Store Connect → Apps → +, by the account holder)
| Field | Value |
|---|---|
| Platforms | iOS, iPhone (1.0 is an iPhone app; on an iPad it runs as one) |
| Name | IP Browser (`metadata/*/name.txt`) |
| Primary language | English (U.S.); Russian as a second localization |
| Bundle ID | `app.ipbrowser.pos2` — the identifier the app already has; it cannot change later |
| SKU | `ip-browser` |
| Category | Utilities (secondary: Productivity) |

## 2. App information
- **Subtitle, description, keywords, promotional text, release notes**: `metadata/en-US/`, `metadata/ru/` (keywords ≤ 100 bytes).
- **Support URL / Privacy Policy URL**: `metadata/*/support_url.txt`, `privacy_url.txt` — they point at this repository on
  GitHub and work once it is public.
- **Age rating**: no objectionable content of its own; **Unrestricted Web Access: Yes** (it is a web browser). App Store
  Connect computes the rating from these answers.
- **Content rights**: no third-party content of its own.

## 3. App Privacy («nutrition label»)
**Data Not Collected.** The app has no accounts, analytics, advertising or server of its own; history, favorites and
website data stay on the phone; the exit checks and time-zone lookups go through the person's own server to public
services and carry nothing about the person. `App/PrivacyInfo.xcprivacy` declares no collected data and no tracking.

## 4. Encryption (export compliance)
The tunnel to the person's server uses standard algorithms only (TLS 1.3, QUIC, X25519/ML-KEM-768 in VLESS Encryption,
the Salamander obfuscation over them), implemented in the app (Xray-core) in addition to Apple's. `Info.plist` therefore
says `ITSAppUsesNonExemptEncryption = YES`, and App Store Connect asks:
- *Which encryption algorithms?* → **Standard encryption algorithms instead of, or in addition to, using or accessing the
  encryption within Apple's operating system.**
- *Available in France?* → follows the choice of countries; France asks for its own declaration for such apps.

Apple: [Overview of export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/).

## 5. Review information
- **Notes**: `review_notes.txt`, with an access key of a test server in place of `<REVIEW KEY>` — pasted **only** in App
  Store Connect, never committed. The test server is a separate VPS whose address may be seen by reviewers; its key is
  revoked after review (`ip-browser-manage revoke-device`).
- **IPv6-only networks** (App Review's): the app dials an IPv4 server through the address iOS synthesizes on a NAT64
  network (`App/Sources/Core/NAT64.swift`); see `docs/TESTING.md`.

## 6. Screenshots
`tools/screenshots.sh <Debug IPBrowser.app> <the review server's key> <dir>` makes iPhone 6.9" (1320×2868)
screenshots in Russian and English: home, a website, the leak test, servers, «install on my
server», settings. Use the review server's key (name it in the key, e.g. «My server»): the screenshots show its name and
the address websites see.

## 7. The build
An App Store build is the same commit as the Ad Hoc build, signed for App Store distribution and uploaded to App Store
Connect (Transporter or `xcrun altool --upload-app`); then it is chosen for the version and submitted for review.
