# Contributing to IP Browser

Thank you for helping. IP Browser has one promise — **websites see only your server's address, and nothing leaves another
way** — and every change is judged by it first.

## Ground rules
- **No way around the tunnel.** No direct outbound in the core, no proxy failover, nothing that lets WebKit reach the network
  around LocalGate. A feature that needs one is not taken.
- **Masked kinds only.** HOP (Hysteria 2 + Salamander) and XHTTP (VLESS Encryption over XHTTP/TLS). Plain Hysteria, plain
  VLESS, REALITY or anything recognisable on the wire is refused by design (`AccessKey.requireMasked`).
- **No telemetry, no accounts, no servers of ours.** The app talks to the person's server and the sites they open.
- **Public APIs only.** No private WebKit selectors, no swizzling — the app must pass App Review.
- **The server script stays small and reversible.** Whatever `install` adds, `uninstall` removes; administrator's own rules and
  keys are never touched.

## Build and test
```sh
tools/build-libxray.sh && xcodegen generate && tools/pin-packages.sh
tools/ci.sh                      # shellcheck, build, unit tests (what CI runs)
```
- A change to `Server/install.sh`: run `tools/vm-test.sh` on a Debian or Ubuntu cloud image, `fresh` and `upgrade`
  (see [docs/TESTING.md](docs/TESTING.md)).
- A change to the route (LocalGate, TunnelController, XrayEngine): add a unit test for the rule and run the matching lab hook
  (`-labfailover`, `-labnetchange`, `-labreturn`, `-selftest`) on a simulator against a real server.
- Formatting: `swift format --in-place --recursive App/Sources Tests` (`.swift-format`, 120 columns); `shellcheck -x` for
  shell scripts.

## Pull requests
- One subject per pull request; say **what a person will notice** and how you proved it (the command and its output, or a
  screenshot of the leak test).
- Comments explain *why*, in plain words. User-facing text goes to both `en.lproj` and `ru.lproj`.
- New dependencies need a reason, a pinned version and their license in `App/Resources/licenses.txt` (`tools/licenses.sh`).

## Reporting
- Bugs and ideas: [issues](../../issues/new/choose) — please include the iOS version, the build (Settings → About) and, for
  connection problems, *Settings → Connection log*.
- **Security issues** (a leak, one profile seeing another, a key outliving its revocation): privately, see [SECURITY.md](SECURITY.md).

By contributing you agree to follow our [Code of Conduct](CODE_OF_CONDUCT.md). You license your contribution to everyone
under the [GNU AGPL v3.0 or later](LICENSE). You also grant the project's author a perpetual, worldwide, royalty-free
license to use, change and distribute it under other terms as well: in the App Store and under the commercial license (see
the README). This keeps the project able to publish the app and to offer both licenses.
