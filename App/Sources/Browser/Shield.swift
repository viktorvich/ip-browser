import WebKit

/// Web features whose network traffic WebKit does NOT send through the data store's
/// proxy, so they would reveal the phone's own address:
///  - WebRTC (STUN/TURN/ICE over UDP straight from the device),
///  - WebTransport (iOS 26.4+: its own HTTP/3 connection, Mysk 2026-08-04),
///  - WebAuthn Related Origin Requests (the system credential service fetches
///    https://<rp>/.well-known/webauthn itself, iOS 18+).
/// They are removed from every frame before any page script runs. Strict mode adds
/// WebKit's own Lockdown restrictions for the page (no JIT, no WebRTC/WebTransport
/// in the engine itself), the strongest public switch Apple offers.
enum Shield {
    static let version = "shield-3"

    /// iOS 26.4 introduced WebTransport, and its WebKit opens WebTransport's QUIC
    /// connection straight from the device, ignoring the data store's proxy - from page
    /// windows AND from workers (a page script can always start a worker the shield
    /// cannot reach). Proven in the lab 20.11.2026: UDP from the device reached the target
    /// on iOS 26.4; iOS 27.0 and 27.2 refuse WebTransport through a proxy without sending
    /// a packet. On 26.4 - 26.x the only public switch that removes WebTransport from the
    /// engine is Lockdown, so strict mode is forced there.
    static var webTransportLeaks: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion == 26 && v.minorVersion >= 4
    }
    static var iosVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    /// The page script: the shield, and the server's clock when `zone` is set (Region).
    static func script(zone: String?) -> String {
        let literal =
            zone.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return template.replacingOccurrences(of: "/*ZONE*/null", with: literal).replacingOccurrences(
            of: "/*ZONEFN*/", with: zoneSource)
    }
    /// zone.js: the clock in another time zone, for windows and for Blob workers.
    static let zoneSource: String =
        Bundle.main.url(forResource: "zone", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "function zone() {}"

    private static let template = #"""
        (() => {
          'use strict';
          const ZONE = /*ZONE*/null;
          /*ZONEFN*/
          // Our functions show the native source text they stand for (Function.prototype.toString).
          const FTS = Function.prototype.toString, NATIVE = new WeakMap(), apply = Reflect.apply;
          const ZSRC = ZONE ? apply(FTS, zone, []) : null;
          const like = (f, orig) => { try { NATIVE.set(f, apply(FTS, orig, [])); } catch (e) {} return f; };
          function maskRealm(w) {
            try {
              const P = w.Function.prototype, orig = P.toString;
              if (NATIVE.has(orig)) return;
              const ts = {toString() { const n = NATIVE.get(this); return n !== undefined ? n : apply(orig, this, []); }}.toString;
              like(ts, orig);
              Object.defineProperty(P, 'toString', {value: ts, writable: true, configurable: true, enumerable: false});
            } catch (e) {}
          }
          const NAMES = ['RTCPeerConnection','webkitRTCPeerConnection','RTCDataChannel','RTCRtpSender','RTCRtpReceiver',
            'RTCRtpTransceiver','RTCIceCandidate','RTCSessionDescription','RTCIceTransport','RTCDtlsTransport','RTCSctpTransport',
            'RTCDTMFSender','RTCCertificate','RTCRtpScriptTransform','RTCEncodedAudioFrame','RTCEncodedVideoFrame','RTCStatsReport',
            'RTCTrackEvent','RTCPeerConnectionIceEvent','RTCPeerConnectionIceErrorEvent','RTCDataChannelEvent','RTCError','RTCErrorEvent',
            'RTCDTMFToneChangeEvent','WebTransport','WebTransportError','WebTransportBidirectionalStream',
            'WebTransportDatagramDuplexStream','PublicKeyCredential','AuthenticatorResponse','AuthenticatorAttestationResponse',
            'AuthenticatorAssertionResponse'];
          const seen = new WeakSet();
          const lock = (o, k, v) => { try { Object.defineProperty(o, k, {value: v, writable: false, configurable: false, enumerable: false}); } catch (e) { try { delete o[k]; } catch (_) {} } };
          const swap = (o, k, v) => { try { Object.defineProperty(o, k, {value: v, writable: true, configurable: true, enumerable: false}); } catch (e) {} };
          // One realm (a window): remove the features, then make every way of creating
          // or reaching a child window in THIS realm harden that child first.
          function harden(w) {
            try {
              if (!w || seen.has(w)) return;
              seen.add(w);
              maskRealm(w);
              if (ZONE) zone(w, ZONE, NATIVE, FTS, ZSRC);
              for (const n of NAMES) lock(w, n, undefined);
              const c = w.navigator && w.navigator.credentials;
              if (c) {
                const deny = () => Promise.reject(new w.DOMException('Passkeys are off in IP Browser', 'NotAllowedError'));
                for (const m of ['create', 'get']) {
                  const orig = c[m] && c[m].bind(c);
                  const f = {[m](options) { return (options && (options.publicKey || options.mediation === 'conditional')) ? deny() : (orig ? orig(options) : deny()); }}[m];
                  lock(c, m, c[m] ? like(f, c[m]) : f);
                }
              }
              // Location: IP Browser never asks iOS for it, and WebKit then leaves the page waiting
              // forever. Answer as Safari does when location is not allowed: PERMISSION_DENIED at once.
              const G = w.Geolocation && w.Geolocation.prototype, GE = w.GeolocationPositionError;
              if (G && GE) {
                let watch = 0;
                const denied = () => Object.create(GE.prototype, {code: {value: 1, enumerable: true}, message: {value: 'User denied Geolocation', enumerable: true}});
                for (const k of ['getCurrentPosition', 'watchPosition']) {
                  const orig = G[k];
                  if (typeof orig !== 'function') continue;
                  swap(G, k, like({[k](success, error) {
                    if (typeof error === 'function') w.setTimeout(() => { try { error(denied()); } catch (e) {} }, 0);
                    return k === 'watchPosition' ? ++watch : undefined;
                  }}[k], orig));
                }
              }
              const sweep = () => { try { for (let i = 0; i < w.length; i++) { try { const f = w[i]; void f.document; harden(f); } catch (e) {} } } catch (e) {} };
              const getter = (P, key) => {
                const d = P && Object.getOwnPropertyDescriptor(P.prototype, key);
                if (!d || !d.get) return;
                const get = Object.getOwnPropertyDescriptor({get [key]() {
                  const v = d.get.call(this);
                  try { harden(key === 'contentDocument' ? (v && v.defaultView) : v); } catch (e) {}
                  return v;
                }}, key).get;
                Object.defineProperty(P.prototype, key, {configurable: true, enumerable: d.enumerable, get: like(get, d.get)});
              };
              for (const P of [w.HTMLIFrameElement, w.HTMLFrameElement, w.HTMLObjectElement, w.HTMLEmbedElement]) { getter(P, 'contentWindow'); getter(P, 'contentDocument'); }
              const after = (proto, key) => {
                const f = proto && proto[key];
                if (typeof f !== 'function') return;
                swap(proto, key, like({[key](...args) { const r = f.apply(this, args); sweep(); return r; }}[key], f));
              };
              for (const k of ['appendChild', 'insertBefore', 'replaceChild']) after(w.Node && w.Node.prototype, k);
              for (const k of ['append', 'prepend', 'after', 'before', 'replaceWith', 'insertAdjacentElement', 'insertAdjacentHTML', 'replaceChildren', 'setHTMLUnsafe']) after(w.Element && w.Element.prototype, k);
              for (const k of ['append', 'prepend', 'replaceChildren']) after(w.DocumentFragment && w.DocumentFragment.prototype, k);
              for (const k of ['write', 'writeln']) after(w.Document && w.Document.prototype, k);
              for (const P of [w.Element, w.ShadowRoot]) {
                for (const k of ['innerHTML', 'outerHTML']) {
                  const d = P && Object.getOwnPropertyDescriptor(P.prototype, k);
                  if (d && d.set) Object.defineProperty(P.prototype, k, {configurable: true, enumerable: d.enumerable, get: d.get,
                    set: like(Object.getOwnPropertyDescriptor({set [k](v) { d.set.call(this, v); sweep(); }}, k).set, d.set)});
                }
              }
              const open = w.open;
              if (typeof open === 'function') swap(w, 'open', like({open(...args) { const r = open.apply(this, args); try { harden(r); } catch (e) {} return r; }}.open, open));
              try { new w.MutationObserver(sweep).observe(w.document, {childList: true, subtree: true}); } catch (e) {}
            } catch (e) {}
          }
          harden(window);
        })();
        """#

    static func install(into controller: WKUserContentController, zone: String?) {
        controller.removeAllUserScripts()
        controller.addUserScript(
            WKUserScript(source: script(zone: zone), injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    /// Safari's own application name: sites (Google sign-in among them) see Safari on this
    /// iOS, not an unknown embedded browser, and the phone looks like millions of others.
    static var safariName: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(v.majorVersion).\(v.minorVersion) Mobile/15E148 Safari/604.1"
    }

    static func harden(_ c: WKWebViewConfiguration, strict: Bool) {
        c.preferences.isFraudulentWebsiteWarningEnabled = false  // its lookups do not use the proxy
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.preferences.isElementFullscreenEnabled = true
        // Only ever switch Lockdown ON: setting it to false needs the restricted
        // com.apple.developer.web-browser entitlement (WebKit throws otherwise).
        if strict { c.defaultWebpagePreferences.isLockdownModeEnabled = true }
        c.defaultWebpagePreferences.preferredHTTPSNavigationPolicy = .userMediatedFallbackToHTTP
        c.allowsInlineMediaPlayback = true
        c.allowsAirPlayForMediaPlayback = false
        c.allowsPictureInPictureMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = .all
        c.upgradeKnownHostsToHTTPS = true
        c.dataDetectorTypes = []
        c.applicationNameForUserAgent = safariName
    }

    /// Local names and private addresses are blocked before any request is formed.
    static let contentRules: String = {
        let hosts = ["localhost", ".*\\.localhost", ".*\\.local", ".*\\.lan", ".*\\.internal", ".*\\.home\\.arpa"]
        let prefixes = [
            "0\\.", "10\\.", "127\\.", "169\\.254\\.", "192\\.168\\.", "172\\.1[6-9]\\.", "172\\.2[0-9]\\.",
            "172\\.3[01]\\.", "100\\.6[4-9]\\.", "100\\.[7-9][0-9]\\.", "100\\.1[01][0-9]\\.", "100\\.12[0-7]\\.",
            "\\[",
        ]
        var filters = hosts.flatMap { h in [":", "/", "$"].map { "^[a-z]+://" + h + $0 } }
        filters += prefixes.map { "^[a-z]+://" + $0 }
        let rules = filters.map { ["trigger": ["url-filter": $0], "action": ["type": "block"]] }
        return String(data: try! JSONSerialization.data(withJSONObject: rules), encoding: .utf8)!
    }()
}
