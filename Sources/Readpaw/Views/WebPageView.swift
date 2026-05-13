import SwiftUI
import AppKit
import WebKit

struct WebPageView: NSViewRepresentable {
    let content: PageContent
    let darkMode: Bool
    let zoom: CGFloat
    let onScrollToTop: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(Self.darkCSSScript)

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground") // best-effort transparent background
        web.underPageBackgroundColor = .clear
        web.pageZoom = zoom
        context.coordinator.lastContent = nil
        context.coordinator.darkMode = darkMode
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        web.pageZoom = zoom
        context.coordinator.darkMode = darkMode
        let key = contentKey()
        if context.coordinator.lastContent != key {
            context.coordinator.lastContent = key
            load(into: web)
        }
        applyDark(web)
    }

    private func contentKey() -> String {
        switch content {
        case .htmlFile(let u, _): return "f:" + u.path
        case .htmlString(let s, _): return "s:\(s.hashValue):\(darkMode)"
        case .image: return "image"
        }
    }

    private func load(into web: WKWebView) {
        switch content {
        case .htmlFile(let url, let baseAccess):
            web.loadFileURL(url, allowingReadAccessTo: baseAccess)
        case .htmlString(let html, let baseURL):
            web.loadHTMLString(html, baseURL: baseURL)
        case .image:
            break
        }
    }

    private func applyDark(_ web: WKWebView) {
        let css = darkMode ? Self.darkCSS : Self.lightCSS
        let scheme = darkMode ? "dark" : "light"
        let js = """
        (function() {
            // 1. Tell the document which color scheme we're rendering in so
            //    `prefers-color-scheme` media queries inside the book's own
            //    stylesheet resolve to the right branch.
            document.documentElement.style.colorScheme = '\(scheme)';
            // 2. Replace our injected override stylesheet.
            let id = 'readpaw-style';
            let existing = document.getElementById(id);
            if (existing) existing.remove();
            let s = document.createElement('style');
            s.id = id;
            s.textContent = `\(css.replacingOccurrences(of: "`", with: "\\`"))`;
            document.head ? document.head.appendChild(s) : document.documentElement.appendChild(s);
        })();
        """
        web.evaluateJavaScript(js, completionHandler: nil)
    }

    private static var darkCSSScript: WKUserScript {
        // Declare both schemes are supported so a flash of unstyled content
        // adopts the OS appearance until applyDark() runs with the reader's
        // current darkMode value.
        let js = """
        (function() {
            let attach = function() {
                let s = document.createElement('style');
                s.id = 'readpaw-style-boot';
                s.textContent = `:root { color-scheme: dark light; }`;
                document.head ? document.head.appendChild(s) : document.documentElement.appendChild(s);
            };
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', attach);
            } else { attach(); }
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    // The `body *` selector with !important nukes any color the EPUB/MOBI
    // author set on individual elements (p, h1, span, etc.) — they often
    // bake in white text expecting a dark theme, which becomes invisible in
    // light mode. Links re-override after the sweep so we don't nuke the
    // link colour we want.
    private static let darkCSS = """
    html, body { background: transparent !important; color: #e6ecf2 !important; }
    body, body * { color: #e6ecf2 !important; }
    a, a * { color: #6fa8ff !important; }
    img { opacity: 0.95; }
    """

    private static let lightCSS = """
    html, body { background: transparent !important; color: #1c1c1f !important; }
    body, body * { color: #1c1c1f !important; }
    a, a * { color: #1b66c9 !important; }
    """

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastContent: String?
        var darkMode: Bool = true

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Open external links in the user's default browser; allow file:// and about: navigation.
            if let url = navigationAction.request.url {
                if url.scheme == "http" || url.scheme == "https" {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
    }
}
