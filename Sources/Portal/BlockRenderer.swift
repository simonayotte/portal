import AppKit
import WebKit

/// Renders Mermaid diagrams and math to images in an offscreen web view, one block at a time.
@MainActor
final class BlockRenderer: NSObject, WKNavigationDelegate {
    static let shared = BlockRenderer()

    private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 2000, height: 2000))
    private var isLoaded = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var last: Task<NSImage?, Never>?
    /// Images by kind, appearance and source (`nil` while rendering, or when the source does not render).
    private var images: [String: NSImage?] = [:]

    private override init() {
        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        if let page = Bundle.main.url(forResource: "render", withExtension: "html") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            isLoaded = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    /// The block's image, or `nil` when it does not render or until it is rendered, which calls `rendered`.
    func image(for block: RenderedBlock, dark: Bool, rendered: @escaping () -> Void) -> NSImage? {
        let key = "\(block.kind)|\(dark)|\(block.source)"
        if let image = images[key] { return image }
        // Every edit to a block renders a new source.
        if images.count > 100 { images.removeAll() }
        images[key] = .some(nil)
        Task {
            images[key] = await render(block, dark: dark)
            if images[key] != nil { rendered() }
        }
        return nil
    }

    /// Renders one block at a time, since they share the page.
    private func render(_ block: RenderedBlock, dark: Bool) async -> NSImage? {
        let previous = last
        let task = Task {
            _ = await previous?.value
            return await draw(block, dark: dark)
        }
        last = task
        return await task.value
    }

    private func draw(_ block: RenderedBlock, dark: Bool) async -> NSImage? {
        if !isLoaded { await withCheckedContinuation { waiting.append($0) } }
        guard let size = try? await webView.callAsyncJavaScript(
            "return await render(kind, source, dark)",
            arguments: ["kind": block.kind.rawValue, "source": block.source, "dark": dark],
            contentWorld: .page
        ) as? [String: Double], let width = size["width"], let height = size["height"], width > 0, height > 0 else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        return try? await webView.takeSnapshot(configuration: configuration)
    }
}
