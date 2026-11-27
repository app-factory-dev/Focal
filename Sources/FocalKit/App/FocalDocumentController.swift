import AppKit
import UniformTypeIdentifiers

final class FocalDocumentController: NSDocumentController {
    func open(_ url: URL) {
        let started = Date()
        openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                let ns = error as NSError
                if !(ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError) {
                    Task { @MainActor in NSApp.presentError(error) }
                }
            }
            Log.event(String(format: "open %@ completed in %.1f ms", url.lastPathComponent, Date().timeIntervalSince(started) * 1000))
        }
    }

    typealias OpenCompletion = (NSDocument?, Bool, (any Error)?) -> Void

    /// Opens that arrive together, gathered for one run-loop turn. Finder's multi-select (and `open a b c`, a
    /// drop on the Dock icon) sends one "open documents" event, which AppKit hands straight to the document
    /// controller as one call per file: the app delegate's application(_:open:) never sees them (measured: three
    /// files opened three windows).
    private var gathered: [(url: URL, completion: OpenCompletion)] = []
    private var passThrough = false
    /// An open request has arrived (so the launch-time Open panel stays away while gathered files load).
    private(set) var receivedOpenRequest = false

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping OpenCompletion) {
        receivedOpenRequest = true
        guard displayDocument, !passThrough else {
            super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
            return
        }
        gathered.append((url, completionHandler))
        if gathered.count == 1 {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.openGathered() } }
        }
    }

    /// One file opens as usual; several Focal can show share one window, listed in its sidebar in Finder's name
    /// order with the first one showing. Types Focal can't show go through one by one so the usual error appears.
    /// A folder always opens as one window browsing its files, whatever the "several in one window" setting.
    private func openGathered() {
        var batch = gathered
        gathered = []
        batch.removeAll { item in
            guard ArchiveBrowser.isArchive(item.url) else { return false }
            openArchive(item.url, completion: item.completion)
            return true
        }
        batch.removeAll { item in
            guard let files = FolderNavigator.folderToBrowse(item.url) else { return false }
            if files.isEmpty {
                let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                    NSLocalizedDescriptionKey: "“\(item.url.lastPathComponent)” has no files Focal can show.",
                    NSLocalizedRecoverySuggestionErrorKey: "Focal shows pictures, PDFs, 3D models, movies and text files.",
                ])
                item.completion(nil, false, error)
            } else {
                openSet(files, completions: [item.completion])
            }
            return true
        }
        let together = Prefs.openSeveralInOneWindow ? FolderNavigator.browsable(batch.map(\.url)) : []
        let alone = together.count > 1 ? batch.filter { item in !together.contains(item.url) } : batch
        passThrough = true
        for item in alone { super.openDocument(withContentsOf: item.url, display: true, completionHandler: item.completion) }
        passThrough = false
        guard together.count > 1 else { return }
        openSet(together, completions: batch.filter { together.contains($0.url) }.map(\.completion))
    }

    /// An archive browses like a folder once its viewable files are unpacked (off the main thread; a small
    /// "Opening…" panel shows if that takes more than a moment).
    private func openArchive(_ url: URL, completion: @escaping OpenCompletion) {
        let started = Date()
        let progress = ArchiveProgressPanel(name: url.lastPathComponent)
        Task { @MainActor in
            let result = await Self.unpack(url)
            progress.close()
            Log.event(String(format: "unpacked %@ in %.1f ms", url.lastPathComponent, Date().timeIntervalSince(started) * 1000))
            switch result {
            case .success(let files):
                openSet(files, completions: [completion])
                noteNewRecentDocumentURL(url)
            case .failure(let error):
                completion(nil, false, error)
            }
        }
    }

    @concurrent private nonisolated static func unpack(_ url: URL) async -> Result<[URL], any Error> {
        Result { try ArchiveBrowser.unpack(url) }
    }

    /// One window showing the first file, the rest in its sidebar.
    private func openSet(_ files: [URL], completions: [OpenCompletion]) {
        let started = Date()
        super.openDocument(withContentsOf: files[0], display: false) { doc, wasOpen, error in
            MainActor.assumeIsolated {
                if let doc {
                    if doc.windowControllers.isEmpty { doc.makeWindowControllers() }
                    (doc.windowControllers.first as? ViewerWindowController)?.browse(files)
                    doc.showWindows()
                    Log.event(String(format: "open set of %d completed in %.1f ms", files.count, Date().timeIntervalSince(started) * 1000))
                }
                // Everyone who asked gets an answer (AppKit replies to the open event); the error goes to the first.
                for (index, completion) in completions.enumerated() {
                    completion(index == 0 ? doc : nil, wasOpen, index == 0 ? error : nil)
                }
            }
        }
    }

    /// A file from an archive has no home to save back to: as a draft, Save asks where (starting next to the archive).
    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        let doc = try super.makeDocument(withContentsOf: url, ofType: typeName)
        if ArchiveBrowser.isUnpacked(url) { doc.isDraft = true }
        return doc
    }

    /// Several URLs at once (the Open panel, the app delegate): through the same gathering as Finder's opens.
    func open(_ urls: [URL]) {
        urls.forEach(open)
    }

    /// ⌘O: several files picked in the panel open together, like a Finder selection.
    /// The Open panel also takes a folder (select it and click Open; double-clicking still goes into it).
    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        openPanel.canChooseDirectories = true
        super.beginOpenPanel(openPanel, forTypes: inTypes, completionHandler: completionHandler)
    }

    override func openDocument(_ sender: Any?) {
        beginOpenPanel { [weak self] urls in
            guard let urls, !urls.isEmpty else { return }
            self?.open(urls)
        }
    }

    /// File ▸ New Text File: an empty, untitled text window. Saving asks for a name; the extension typed
    /// decides what it is ("notes.md" is Markdown, "todo.txt" plain text).
    func newTextFile() {
        do {
            let doc = try makeUntitledDocument(ofType: UTType.plainText.identifier)
            addDocument(doc)
            doc.makeWindowControllers()
            doc.showWindows()
        } catch {
            NSApp.presentError(error)
        }
    }

    /// File ▸ New from Clipboard: a copied file opens that file; copied image data opens as a new image.
    func newFromClipboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            urls.forEach(open)
            return
        }
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) else {
            let alert = NSAlert()
            alert.messageText = "There's no image on the clipboard."
            alert.informativeText = "Copy an image or take a screenshot to the clipboard (⌃⇧⌘4), then try again."
            alert.runModal()
            return
        }
        do {
            let doc = try ImageDocument(pastedData: data)
            addDocument(doc)
            doc.makeWindowControllers()
            doc.showWindows()
        } catch {
            NSApp.presentError(error)
        }
    }
}

/// "Opening photos.zip…" with a spinner, centered on the main display; only for unpacks that take a while.
@MainActor
private final class ArchiveProgressPanel {
    private var panel: NSPanel?
    private var closed = false

    init(name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.show(name) }
        }
    }

    private func show(_ name: String) {
        guard !closed, let screen = NSScreen.screens.first else { return }
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Opening “\(name)”…")
        let stack = NSStackView(views: [spinner, label])
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        panel.contentView = stack
        panel.isReleasedWhenClosed = false
        panel.setContentSize(stack.fittingSize)
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2))
        panel.orderFront(nil)
        self.panel = panel
    }

    func close() {
        closed = true
        panel?.close()
        panel = nil
    }
}
