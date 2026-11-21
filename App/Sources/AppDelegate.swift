import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        setbuf(stdout, nil)
        LocalData.keepOutOfBackups()
        return true
    }
    func application(
        _ application: UIApplication, configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Browser", sessionRole: session.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var browser: BrowserController?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let browser = BrowserController()
        window.rootViewController = browser
        window.makeKeyAndVisible()
        self.window = window
        self.browser = browser
        if let url = options.urlContexts.first?.url { open(url) }
    }
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if let url = contexts.first?.url { open(url) }
    }
    /// ipbrowser://add?... (a key from another device or from the server owner).
    private func open(_ url: URL) {
        guard url.scheme == "ipbrowser" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.browser?.offerKey(url.absoluteString) }
    }
}
