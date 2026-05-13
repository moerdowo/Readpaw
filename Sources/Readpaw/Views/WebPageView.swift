import SwiftUI
import AppKit
import WebKit

/// Renders ebook content (.htmlFile from EPUB / .htmlString from MOBI / TXT /
/// FB2) inside a WKWebView, paginated by viewport-height. Scrolling is
/// disabled; advancing is done by translating a wrapper `<div>` up by 100vh
/// per "page". When the user pages past the end (or start) of the current
/// chapter, the WebView messages Swift, which advances `model.currentPage` —
/// loading the next chapter.
struct WebPageView: NSViewRepresentable {
    let content: PageContent
    let darkMode: Bool
    let zoom: CGFloat
    /// Read so the coordinator can hand chapter-boundary "next/prev" messages
    /// back to the model, and so the model's `textNextPageAction` /
    /// `textPrevPageAction` can be wired to evaluate the WebView's paging JS.
    let model: ReaderModel?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(Self.bootScript)
        config.userContentController.add(
            ScriptMessageProxy(target: context.coordinator),
            name: "readpaw"
        )

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.pageZoom = zoom
        // Disable two-finger swipe back/forward — paging via JS replaces it.
        web.allowsBackForwardNavigationGestures = false

        context.coordinator.darkMode = darkMode
        context.coordinator.model = model
        context.coordinator.webView = web
        context.coordinator.lastContent = nil
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        web.pageZoom = zoom
        context.coordinator.darkMode = darkMode
        context.coordinator.model = model
        context.coordinator.webView = web

        let key = contentKey()
        if context.coordinator.lastContent != key {
            context.coordinator.lastContent = key
            load(into: web)
        }
        applyDark(web)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "readpaw")
        // Drop the per-WebView paging actions so the model doesn't hold a
        // closure capturing a destroyed WKWebView.
        if let m = coordinator.model, coordinator.installedPagingActions {
            m.textNextPageAction = nil
            m.textPrevPageAction = nil
        }
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
        web.evaluateJavaScript(Self.overrideScript(darkMode: darkMode),
                               completionHandler: nil)
    }

    // MARK: - Static CSS / JS

    /// Pagination layout: kill native scroll, lock html/body to the viewport,
    /// and put the chapter's content inside `#readpaw-pages`, which is what
    /// the JS slides up by 100vh on every page turn.
    static let paginationCSS = """
    html, body {
        margin: 0 !important;
        padding: 0 !important;
        height: 100vh !important;
        width: 100vw !important;
        overflow: hidden !important;
    }
    body { -webkit-user-select: text; user-select: text; }
    #readpaw-pages {
        box-sizing: border-box;
        padding: 48px max(28px, calc(50% - 380px));
        width: 100vw;
        min-height: 100vh;
        transition: transform 0.20s cubic-bezier(0.22, 0.61, 0.36, 1);
        will-change: transform;
        -webkit-transform: translateZ(0);
    }
    #readpaw-pages img,
    #readpaw-pages figure,
    #readpaw-pages table,
    #readpaw-pages video {
        max-width: 100% !important;
        height: auto !important;
        box-sizing: border-box !important;
    }
    /* Hide any scrollbars publishers force on. */
    ::-webkit-scrollbar { width: 0 !important; height: 0 !important; }
    """

    static let darkCSS = """
    \(paginationCSS)
    html, body { background: transparent !important; color: #e6ecf2 !important; }
    body, body * { color: #e6ecf2 !important; }
    body a, body a *, body a:visited, body a:visited * { color: #6fa8ff !important; }
    img { opacity: 0.95; }
    """

    static let lightCSS = """
    \(paginationCSS)
    html, body { background: transparent !important; color: #1c1c1f !important; }
    body, body * { color: #1c1c1f !important; }
    body a, body a *, body a:visited, body a:visited * { color: #1b66c9 !important; }
    """

    static func overrideScript(darkMode: Bool) -> String {
        let css = darkMode ? darkCSS : lightCSS
        let scheme = darkMode ? "dark" : "light"
        return """
        (function() {
            document.documentElement.style.colorScheme = '\(scheme)';
            let id = 'readpaw-style';
            let existing = document.getElementById(id);
            if (existing) existing.remove();
            let s = document.createElement('style');
            s.id = id;
            s.textContent = `\(css.replacingOccurrences(of: "`", with: "\\`"))`;
            document.head ? document.head.appendChild(s) : document.documentElement.appendChild(s);
        })();
        """
    }

    /// Runs at document end on every load: wrap the body's content in a
    /// pagination container, install paging helpers on `window`, and bind a
    /// click handler that pages on the left/right third of the screen. The
    /// boundary case (clicking next on the last page, prev on the first)
    /// posts a message back to Swift so the chapter advances.
    static let paginationScript = """
    (function() {
        function setup() {
            if (window.readpawInstalled) {
                window.readpawGoToPage(0);
                return;
            }
            window.readpawInstalled = true;

            var pages = document.getElementById('readpaw-pages');
            if (!pages) {
                pages = document.createElement('div');
                pages.id = 'readpaw-pages';
                var frag = document.createDocumentFragment();
                while (document.body.firstChild) {
                    frag.appendChild(document.body.firstChild);
                }
                pages.appendChild(frag);
                document.body.appendChild(pages);
            }

            window.readpawCurrentPage = 0;

            window.readpawTotalPages = function () {
                var ph = window.innerHeight;
                if (ph <= 0) return 1;
                return Math.max(1, Math.ceil(pages.scrollHeight / ph));
            };

            window.readpawGoToPage = function (idx) {
                var total = window.readpawTotalPages();
                if (idx < 0) idx = 0;
                if (idx > total - 1) idx = total - 1;
                window.readpawCurrentPage = idx;
                pages.style.transform = 'translateY(' + (-idx * window.innerHeight) + 'px)';
            };

            window.readpawNextPage = function () {
                var total = window.readpawTotalPages();
                if (window.readpawCurrentPage + 1 < total) {
                    window.readpawGoToPage(window.readpawCurrentPage + 1);
                } else {
                    try {
                        window.webkit.messageHandlers.readpaw.postMessage('next-chapter');
                    } catch (e) {}
                }
            };

            window.readpawPrevPage = function () {
                if (window.readpawCurrentPage > 0) {
                    window.readpawGoToPage(window.readpawCurrentPage - 1);
                } else {
                    try {
                        window.webkit.messageHandlers.readpaw.postMessage('prev-chapter');
                    } catch (e) {}
                }
            };

            document.addEventListener('click', function (e) {
                // Let links work normally.
                if (e.target.closest && e.target.closest('a')) return;
                var third = window.innerWidth / 3;
                if (e.clientX < third) window.readpawPrevPage();
                else if (e.clientX > window.innerWidth - third) window.readpawNextPage();
            }, true);

            window.addEventListener('resize', function () {
                window.readpawGoToPage(window.readpawCurrentPage);
            });

            // Disable scroll-by-wheel since the reader is paginated.
            window.addEventListener('wheel', function (e) {
                e.preventDefault();
            }, { passive: false });
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', setup);
        } else {
            setup();
        }
    })();
    """

    private static var bootScript: WKUserScript {
        // Declared early so the chapter's own CSS sees both schemes are
        // legal until applyDark commits to one.
        let js = """
        (function() {
            var attach = function() {
                var s = document.createElement('style');
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

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastContent: String?
        var darkMode: Bool = true
        weak var model: ReaderModel?
        weak var webView: WKWebView?
        var installedPagingActions: Bool = false

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                if url.scheme == "http" || url.scheme == "https" {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 1. Re-apply color override against the *real* fresh document.
            webView.evaluateJavaScript(
                WebPageView.overrideScript(darkMode: darkMode),
                completionHandler: nil
            )
            // 2. Install pagination — wrap body, expose paging API on window.
            webView.evaluateJavaScript(WebPageView.paginationScript, completionHandler: nil)
            // 3. Route the toolbar/keyboard paging through the WebView.
            installPagingActions(into: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            webView.evaluateJavaScript(
                WebPageView.overrideScript(darkMode: darkMode),
                completionHandler: nil
            )
        }

        // MARK: paging action wiring

        private func installPagingActions(into web: WKWebView) {
            guard let m = model else { return }
            installedPagingActions = true
            weak var weakWeb: WKWebView? = web
            m.textNextPageAction = {
                weakWeb?.evaluateJavaScript(
                    "window.readpawNextPage && window.readpawNextPage();",
                    completionHandler: nil
                )
            }
            m.textPrevPageAction = {
                weakWeb?.evaluateJavaScript(
                    "window.readpawPrevPage && window.readpawPrevPage();",
                    completionHandler: nil
                )
            }
        }

        // MARK: messages from JS

        func handleScriptMessage(_ body: Any) {
            guard let s = body as? String else { return }
            switch s {
            case "next-chapter":
                guard let m = model else { return }
                m.setPage(m.currentPage + 1)
            case "prev-chapter":
                guard let m = model else { return }
                m.setPage(m.currentPage - 1)
            default:
                break
            }
        }
    }
}

/// WKUserContentController retains its message handlers strongly. If the
/// Coordinator subscribed directly, the WebView -> controller -> coordinator
/// chain would keep both alive after SwiftUI tears the view down. Proxying
/// via a weak reference breaks the cycle; `dismantleNSView` also explicitly
/// removes the handler.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WebPageView.Coordinator?

    init(target: WebPageView.Coordinator) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard message.name == "readpaw" else { return }
        target?.handleScriptMessage(message.body)
    }
}
