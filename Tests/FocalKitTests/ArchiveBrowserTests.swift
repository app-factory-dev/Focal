import Foundation
import Testing
@testable import FocalKit

/// Fixtures are built at test time with the system's tar and zip, in a fresh temporary folder.
private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveTests-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    func write(_ path: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func run(_ tool: String, _ arguments: [String], in folder: String = "") throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = root.appendingPathComponent(folder)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private func names(_ files: [URL]) -> [String] { files.map(\.lastPathComponent) }

@Test func archiveFlattensItsViewableFilesInFinderOrder() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try f.write("src/photos/IMG_10.png")
    try f.write("src/photos/IMG_2.png")
    try f.write("src/notes.txt")
    try f.write("src/holiday/notes.txt", "second")
    try f.write("src/other/notes.txt", "third")
    try f.write("src/report.docx")                  // not something Focal shows
    try f.write("src/.DS_Store")
    try f.write("src/._notes.txt")
    try f.write("src/__MACOSX/src/._IMG_2.png")
    try f.write("src/inner.zip")                   // nested archives aren't opened
    try FileManager.default.createSymbolicLink(atPath: f.url("src/link.txt").path, withDestinationPath: "notes.txt")
    try f.run("/usr/bin/tar", ["-a", "-cf", "../photos.zip", "."], in: "src")

    #expect(ArchiveBrowser.isArchive(f.url("photos.zip")))
    let files = try ArchiveBrowser.unpack(f.url("photos.zip"))
    defer { ArchiveBrowser.remove(files[0].deletingLastPathComponent()) }
    // One flat folder; Finder's numeric order (2 before 10); the clashing names get their folder's name.
    #expect(Set(names(files)) == ["IMG_2.png", "IMG_10.png", "notes.txt", "notes (holiday).txt", "notes (other).txt"])
    #expect(names(files).firstIndex(of: "IMG_2.png")! < names(files).firstIndex(of: "IMG_10.png")!)
    #expect(Set(files.map { $0.deletingLastPathComponent() }).count == 1)
    #expect(files.allSatisfy(ArchiveBrowser.isUnpacked))
    #expect(ArchiveBrowser.archive(of: files[0])?.lastPathComponent == "photos.zip")
    #expect(ArchiveBrowser.saveFolder(for: files[0]).standardizedFileURL == f.root.standardizedFileURL)
}

@Test func tarFormatsUnpackToo() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try f.write("src/a.txt")
    for name in ["a.tar", "a.tar.gz", "a.tgz", "a.tar.bz2", "a.tar.xz", "a.7z", "a.cpio", "a.xar"] {
        #expect(try f.run("/usr/bin/tar", ["-a", "-cf", "../\(name)", "a.txt"], in: "src") == 0, "\(name)")
        #expect(ArchiveBrowser.isArchive(f.url(name)), "\(name)")
        let files = try ArchiveBrowser.unpack(f.url(name))
        #expect(names(files) == ["a.txt"], "\(name)")
        ArchiveBrowser.remove(files[0].deletingLastPathComponent())
    }
}

@Test func onlyExactArchiveTypesBrowse() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    // Word, EPUB and Java files are ZIPs inside, but they're documents: Focal leaves them alone.
    for name in ["a.docx", "a.xlsx", "a.epub", "a.jar", "a.gz", "a.bz2", "a.png"] {
        try f.write(name)
        #expect(!ArchiveBrowser.isArchive(f.url(name)), "\(name)")
    }
    for name in ["a.zip", "a.rar", "a.7z", "a.iso", "a.cab", "a.tar.gz"] {
        try f.write(name)
        #expect(ArchiveBrowser.isArchive(f.url(name)), "\(name)")
    }
    try FileManager.default.createDirectory(at: f.url("folder.zip"), withIntermediateDirectories: true)
    #expect(!ArchiveBrowser.isArchive(f.url("folder.zip")))
}

@Test func entriesEscapingTheFolderAreRefused() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try f.write("work/inside.txt")
    try f.write("escaped.txt")
    // -P keeps the "../escaped.txt" name in the archive.
    try f.run("/usr/bin/tar", ["-cf", "../evil.tar", "-P", "../escaped.txt", "inside.txt"], in: "work")
    try FileManager.default.removeItem(at: f.url("escaped.txt"))

    let files = try ArchiveBrowser.unpack(f.url("evil.tar"))
    defer { ArchiveBrowser.remove(files[0].deletingLastPathComponent()) }
    #expect(names(files) == ["inside.txt"])
    #expect(!FileManager.default.fileExists(atPath: ArchiveBrowser.temporaryFolder.appendingPathComponent("escaped.txt").path))
    let parent = files[0].deletingLastPathComponent().deletingLastPathComponent()
    #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("escaped.txt").path))
}

@Test func archivesOverTheLimitsAreRefusedBeforeUnpacking() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try f.write("src/a.txt", String(repeating: "x", count: 2000))
    try f.write("src/b.txt")
    try f.run("/usr/bin/tar", ["-a", "-cf", "../big.zip", "a.txt", "b.txt"], in: "src")
    var entries = ArchiveBrowser.Limits()
    entries.entries = 1
    #expect(throws: ArchiveBrowser.Failure.tooLarge) { try ArchiveBrowser.unpack(f.url("big.zip"), limits: entries) }
    var bytes = ArchiveBrowser.Limits()
    bytes.bytes = 1000
    #expect(throws: ArchiveBrowser.Failure.tooLarge) { try ArchiveBrowser.unpack(f.url("big.zip"), limits: bytes) }
}

@Test func passwordDamagedAndEmptyArchivesSayWhy() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try f.write("src/a.txt")
    try f.write("src/a.docx")
    try f.run("/usr/bin/zip", ["-q", "-P", "secret", "../locked.zip", "a.txt"], in: "src")
    #expect(throws: ArchiveBrowser.Failure.passwordProtected) { try ArchiveBrowser.unpack(f.url("locked.zip")) }

    try f.write("broken.zip", "not a zip at all")
    #expect(throws: ArchiveBrowser.Failure.unreadable) { try ArchiveBrowser.unpack(f.url("broken.zip")) }

    try f.run("/usr/bin/tar", ["-a", "-cf", "../docs.zip", "a.docx"], in: "src")
    #expect(throws: ArchiveBrowser.Failure.nothingToShow) { try ArchiveBrowser.unpack(f.url("docs.zip")) }

    // Failed unpacks leave nothing behind.
    let left = (try? FileManager.default.contentsOfDirectory(atPath: ArchiveBrowser.temporaryFolder.path)) ?? []
    for folder in left {
        let source = ArchiveBrowser.temporaryFolder.appendingPathComponent(folder).appendingPathComponent(".focal-archive")
        let path = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
        #expect(!path.hasPrefix(f.root.path), "\(path)")
    }
}

@Test func closingRemovesTheUnpackedCopy() throws {
    let f = try Fixture()
    defer { f.cleanUp() }
    try f.write("src/a.txt")
    try f.run("/usr/bin/tar", ["-a", "-cf", "../a.zip", "a.txt"], in: "src")
    let folder = try ArchiveBrowser.unpack(f.url("a.zip"))[0].deletingLastPathComponent()
    ArchiveBrowser.remove(folder)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    // Only ever inside FocalArchives.
    ArchiveBrowser.remove(f.root)
    #expect(FileManager.default.fileExists(atPath: f.root.path))
}
