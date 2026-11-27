import AppKit
import UniformTypeIdentifiers

/// An archive opened in Focal (ZIP, 7z, RAR, tar, cpio, ISO, XAR, CAB) browses like a folder: the files Focal can
/// show are unpacked by the system's bsdtar into one flat temporary folder, listed in Finder's name order.
/// View only: nothing is written back into the archive (files from it save through Save As).
public enum ArchiveBrowser {
    /// Exact types, not conformance: .docx, .xlsx, .epub, .pages, .jar and .ipa conform to public.zip-archive,
    /// and Focal must not "browse" a Word file's XML or appear in its Open With menu.
    public static let archiveTypes: Set<String> = [
        "public.zip-archive", "org.7-zip.7-zip-archive", "com.rarlab.rar-archive", "public.tar-archive",
        "org.gnu.gnu-zip-tar-archive", "public.tar-bzip2-archive", "org.tukaani.tar-xz-archive",
        "public.cpio-archive", "public.iso-image", "com.apple.xar-archive", "com.microsoft.cab",
    ]
    /// A compressed single file is only an archive when it holds a tar (photos.tar.gz).
    static let compressedTarTypes: Set<String> = ["org.gnu.gnu-zip-archive", "public.bzip2-archive", "org.tukaani.xz-archive"]

    /// Guards against ZIP bombs: refused before anything is unpacked.
    public struct Limits: Sendable {
        public var bytes: Int64 = 4 << 30
        public var entries = 10_000
        public init() {}
    }

    public enum Failure: LocalizedError, Equatable {
        case passwordProtected, tooLarge, unreadable, nothingToShow

        public var errorDescription: String? {
            switch self {
            case .passwordProtected: "Focal can't open password-protected archives."
            case .tooLarge: "This archive is too large to browse."
            case .unreadable: "This archive is damaged or in a format Focal can't read."
            case .nothingToShow: "This archive has no files Focal can show."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .passwordProtected: "Open it with Archive Utility, then open the unpacked files in Focal."
            case .tooLarge: "Focal unpacks archives of up to 4 GB and 10,000 files. Unpack it with Archive Utility instead."
            case .unreadable: "Try opening it with Archive Utility."
            case .nothingToShow: "Focal shows pictures, PDFs, 3D models, movies and text files."
            }
        }
    }

    public static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if url.pathExtension.lowercased() == "rar" { return true }   // undeclared by macOS; Focal's Info.plist imports it
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
              !type.conforms(to: .directory) else { return false }
        if archiveTypes.contains(type.identifier) { return true }
        return compressedTarTypes.contains(type.identifier) && name.contains(".tar.")
    }

    // MARK: Unpacking

    public static var temporaryFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FocalArchives", isDirectory: true)
    }

    /// Unpacks the viewable files into `FocalArchives/<uuid>/` and returns them in Finder's name order.
    /// Blocking (runs bsdtar twice); call it off the main thread.
    public static func unpack(_ archive: URL, limits: Limits = Limits()) throws -> [URL] {
        let listing = try list(archive)
        if listing.entries > limits.entries || listing.bytes > limits.bytes { throw Failure.tooLarge }

        let fm = FileManager.default
        let folder = temporaryFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = folder.appendingPathComponent(".staging", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try archive.path.write(to: folder.appendingPathComponent(sourceFileName), atomically: true, encoding: .utf8)
        var keep = false
        defer {
            try? fm.removeItem(at: staging)
            if !keep { try? fm.removeItem(at: folder) }
        }

        // bsdtar refuses absolute paths and ".." entries by itself (and says so on stderr, exit 1); what it did
        // unpack is still shown. Owners and permissions come from us, not the archive.
        let result = try tar(["-xf", archive.path, "-C", staging.path, "--no-same-owner", "--no-same-permissions"])
        if result.error.localizedCaseInsensitiveContains("passphrase") { throw Failure.passwordProtected }

        flatten(staging, into: folder)
        let files = FolderNavigator.contents(ofFolder: folder)
        if files.isEmpty { throw result.status == 0 ? Failure.nothingToShow : Failure.unreadable }
        keep = true
        return files
    }

    struct Listing { var entries = 0, bytes: Int64 = 0 }

    /// `tar -tvf`: one ls-style line per entry, the size in the fifth column.
    static func list(_ archive: URL) throws -> Listing {
        let result = try tar(["-tvf", archive.path])
        if result.error.localizedCaseInsensitiveContains("passphrase") { throw Failure.passwordProtected }
        guard result.status == 0 else { throw Failure.unreadable }
        var listing = Listing()
        for line in result.output.split(separator: "\n") {
            listing.entries += 1
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            if fields.count > 4, let size = Int64(fields[4]) { listing.bytes += size }
        }
        return listing
    }

    /// Viewable regular files (and document packages such as RTFD) move up into `folder`. Symlinks, hidden
    /// files, macOS's `__MACOSX` resource forks and anything resolving outside `staging` are left behind.
    static func flatten(_ staging: URL, into folder: URL) {
        let fm = FileManager.default
        let root = staging.resolvingSymlinksInPath().path + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .isPackageKey, .contentTypeKey]
        guard let walker = fm.enumerator(at: staging, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var found: [URL] = []
        for case let item as URL in walker {
            guard let v = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true, item.lastPathComponent == "__MACOSX" { walker.skipDescendants(); continue }
            guard v.isSymbolicLink != true, v.isRegularFile == true || v.isPackage == true,
                  let type = v.contentType, FolderNavigator.isViewable(type),
                  item.resolvingSymlinksInPath().path.hasPrefix(root) else { continue }
            found.append(item)
        }
        // Shallowest first, so a top-level file keeps its own name when a subfolder has one like it.
        found.sort { ($0.pathComponents.count, $0.path) < ($1.pathComponents.count, $1.path) }
        var taken = Set<String>()
        for item in found {
            try? fm.moveItem(at: item, to: folder.appendingPathComponent(uniqueName(for: item, taken: &taken)))
        }
    }

    /// The first file keeps its name; a later one with the same name gets its folder's name added
    /// ("IMG_001 (holiday).jpg"), then a number if that's taken too.
    static func uniqueName(for item: URL, taken: inout Set<String>) -> String {
        let name = item.lastPathComponent
        let base = item.deletingPathExtension().lastPathComponent
        let ext = item.pathExtension.isEmpty ? "" : "." + item.pathExtension
        let parent = item.deletingLastPathComponent().lastPathComponent
        var candidates = [name]
        if !parent.isEmpty, parent != ".staging" { candidates.append("\(base) (\(parent))\(ext)") }
        for candidate in candidates where !taken.contains(candidate.lowercased()) {
            taken.insert(candidate.lowercased())
            return candidate
        }
        var n = 2
        while taken.contains("\(base) \(n)\(ext)".lowercased()) { n += 1 }
        taken.insert("\(base) \(n)\(ext)".lowercased())
        return "\(base) \(n)\(ext)"
    }

    // MARK: Unpacked files

    private static let sourceFileName = ".focal-archive"

    /// The unpacked folder a file sits in, when it came out of an archive.
    public static func unpackedFolder(of url: URL) -> URL? {
        let root = temporaryFolder.resolvingSymlinksInPath().path + "/"
        let folder = url.deletingLastPathComponent()
        guard folder.resolvingSymlinksInPath().path.hasPrefix(root) else { return nil }
        return folder
    }

    public static func isUnpacked(_ url: URL) -> Bool { unpackedFolder(of: url) != nil }

    /// The archive an unpacked file came from.
    public static func archive(of url: URL) -> URL? {
        guard let folder = unpackedFolder(of: url),
              let path = try? String(contentsOf: folder.appendingPathComponent(sourceFileName), encoding: .utf8)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Where a Save As or Export of this file starts: next to the archive for a file from one.
    public static func saveFolder(for url: URL) -> URL {
        (archive(of: url) ?? url).deletingLastPathComponent()
    }

    /// On window close.
    public static func remove(_ folder: URL) {
        guard unpackedFolder(of: folder.appendingPathComponent("x")) != nil else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// At quit: archives of windows still open.
    public static func removeAll() { try? FileManager.default.removeItem(at: temporaryFolder) }

    // MARK: bsdtar

    static let tarTool = URL(fileURLWithPath: "/usr/bin/tar")

    struct Result { var status: Int32, output: String, error: String }

    /// Output goes to temporary files, so a long listing can't fill a pipe and stall bsdtar. A dummy passphrase
    /// stops bsdtar asking for one on the terminal (an encrypted entry then fails with "Incorrect passphrase").
    static func tar(_ arguments: [String]) throws -> Result {
        let fm = FileManager.default
        let out = fm.temporaryDirectory.appendingPathComponent("focal-tar-\(UUID().uuidString).out")
        let err = fm.temporaryDirectory.appendingPathComponent("focal-tar-\(UUID().uuidString).err")
        fm.createFile(atPath: out.path, contents: nil)
        fm.createFile(atPath: err.path, contents: nil)
        defer { try? fm.removeItem(at: out); try? fm.removeItem(at: err) }
        let process = Process()
        process.executableURL = tarTool
        process.arguments = arguments + ["--passphrase", "focal-has-no-passphrase"]
        process.standardInput = FileHandle.nullDevice
        let outHandle = try FileHandle(forWritingTo: out), errHandle = try FileHandle(forWritingTo: err)
        process.standardOutput = outHandle
        process.standardError = errHandle
        try process.run()
        process.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()
        return Result(status: process.terminationStatus,
                      output: String(decoding: (try? Data(contentsOf: out)) ?? Data(), as: UTF8.self),
                      error: String(decoding: (try? Data(contentsOf: err)) ?? Data(), as: UTF8.self))
    }
}

extension NSDocument {
    /// Save As / Export of a file from an archive starts in the archive's folder, not the unpacked copy's.
    func startNextToArchive(_ panel: NSSavePanel) {
        if let url = fileURL, ArchiveBrowser.isUnpacked(url) { panel.directoryURL = ArchiveBrowser.saveFolder(for: url) }
    }
}
