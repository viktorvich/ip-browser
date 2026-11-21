import UIKit
import WebKit

/// What WebKit asks the browser: navigation policy, proxy credentials, windows, panels, files.
extension BrowserController: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        if strict { preferences.isLockdownModeEnabled = true }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        // Only web schemes; never hand a link to another app (it would leave this route).
        guard ["http", "https", "about", "blob", "data"].contains(scheme) else {
            decisionHandler(.cancel, preferences)
            return
        }
        // A data: document is a fresh origin the shield cannot be relied on to reach first.
        if scheme == "data", navigationAction.targetFrame?.isMainFrame != true {
            decisionHandler(.cancel, preferences)
            return
        }
        // While the route is being (re)verified (a network change, a switch) LocalGate holds the
        // request until a verified kind carries it (up to 12 s): a tapped link is not lost. With no
        // route at all (another exit seen, a failure, no server) nothing starts.
        if ["http", "https"].contains(scheme), !ready {
            switch TunnelController.shared.state {
            case .starting, .reconnecting: break
            default:
                decisionHandler(.cancel, preferences)
                return
            }
        }
        decisionHandler(.allow, preferences)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        #if DEBUG
        print("IPB_NAV start \(webView.url?.absoluteString ?? "")")
        #endif
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        #if DEBUG
        print("IPB_NAV commit \(webView.url?.absoluteString ?? "")")
        #endif
        if webView.url?.scheme != "about" { restoring[ObjectIdentifier(webView)] = nil }
        if webView === self.webView, webView.url?.scheme != "about" {
            showWeb()
            if !address.isFirstResponder { address.text = shownAddress(webView.url) }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView {
            if !address.isFirstResponder { address.text = shownAddress(webView.url) }
            progress.isHidden = true
        }
        // Only this profile's own pages write into its history.
        if let url = webView.url, let s = session, s.tabs.contains(webView) {
            s.library.recordVisit(title: webView.title ?? "", url: url)
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }

    func failed(_ webView: WKWebView, _ error: Error) {
        let e = error as NSError
        guard !(e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled), e.code != 102 else { return }
        Self.log.notice("IPB_NAV_FAIL domain=\(e.domain, privacy: .public) code=\(e.code, privacy: .public)")
        #if DEBUG
        print("IPB_NAV_FAIL \(e.domain) \(e.code) \(webView.url?.absoluteString ?? "")")
        #endif
        guard webView === self.webView else { return }
        let reason: String
        switch e.code {
        case NSURLErrorTimedOut: reason = L("error.timeout")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: reason = L("error.dns")
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, 310, -1200...(-1000):
            reason = L("error.connect")
        default: reason = String(format: L("error.other"), e.code)
        }
        let html =
            "<!doctype html><meta name=viewport content='width=device-width'><body style='font:16px -apple-system;padding:40px 24px;color:#555'><h2>"
            + L("error.title") + "</h2><p>" + reason + "</p><p style='opacity:.6'>"
            + ((e.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? "") + "</p></body>"
        // The tab keeps the address it could not open: «reload» and the route opening again retry it.
        if let failing = e.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
            ["http", "https"].contains(failing.scheme ?? "")
        {
            restoring[ObjectIdentifier(webView)] = failing
        }
        webView.loadHTMLString(html, baseURL: nil)
        TunnelController.shared.recheckSoon()
    }

    /// iOS reclaims a background tab's web process routinely: reload it, keep the route.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if webView.url != nil { webView.reload() } }

    func webView(
        _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.isProxy() {
            // The credential of the profile this page belongs to; a page of no live profile gets none.
            guard challenge.previousFailureCount < 2, let s = session, s.tabs.contains(webView),
                let credential = TunnelController.shared.gate.credential(
                    for: challenge.protectionSpace, profile: s.profile)
            else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: WKUIDelegate

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard tabs.count < 12, let s = session, s.tabs.contains(webView) else { return nil }
        // WebKit hands us a configuration derived from the opener's: same store, same proxy, same shield.
        let popup = makeWebView(configuration)
        tabs.append(popup)
        switchTo(popup)
        showWeb()
        return popup
    }
    func webViewDidClose(_ webView: WKWebView) {
        guard tabs.count > 1, let i = tabs.firstIndex(of: webView) else { return }
        tabs.remove(at: i)
        switchTo(tabs[max(0, i - 1)])
    }
    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) { decisionHandler(.deny) }
    func webView(
        _ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) { decisionHandler(.deny) }
    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let a = UIAlertController(title: frame.securityOrigin.host, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }
    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let a = UIAlertController(title: frame.securityOrigin.host, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("cancel"), style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    // MARK: uploads (photo metadata is stripped on both ways in)

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void
    ) {
        uploads.present(
            from: self, sourceView: toolbar, multiple: parameters.allowsMultipleSelection,
            completion: completionHandler)
    }

    // MARK: downloads (through the same store and proxy)

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(suggestedFilename.isEmpty ? "download" : suggestedFilename)
        try? FileManager.default.removeItem(at: url)
        downloads[download] = url
        completionHandler(url)
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloads.removeValue(forKey: download) else { return }
        let a = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        a.popoverPresentationController?.sourceView = toolbar
        present(a, animated: true)
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: download)
    }
}
