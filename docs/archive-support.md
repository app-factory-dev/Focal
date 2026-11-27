# Focal — archive support plan (branch `ZIP`)

**Scope (decided 2026-11-27):** view only · all archive formats `bsdtar` reads · flat list · Focal appears under Open With only (never takes the double-click from Archive Utility).

## What the user sees

Open `photos.zip` with Focal: one window opens, titled with the archive name, the first viewable file showing, the rest in the thumbnail sidebar. ⌘[ ⌘], ← →, lightbox sizing and every viewer behave exactly as they do for a folder. Files can be marked up, but **Save becomes Save As…**, so nothing is ever written back into the archive. Closing the window deletes the unpacked copy.

## Design

| Piece | Where | What |
|---|---|---|
| `ArchiveBrowser` (new) | `Window/ArchiveBrowser.swift` | Detects an archive and unpacks it into a flat folder. Returns `[URL]`, the same thing `folderToBrowse` returns. |
| Hook | `FocalDocumentController.openGathered()` | Next to the folder branch: `ArchiveBrowser.filesToBrowse(url)` → `openSet(files, …)`. Same "has no files Focal can show" error when it's empty. |
| Info.plist | `Resources/Info.plist` | New Viewer document type with **`LSHandlerRank` = `Alternate`** (listed in Open With, never the default). Placed next to the folder entry, with rank `None` handling like folders: intercepted before an NSDocument is made. |
| Cleanup | `$TMPDIR/FocalArchives/<uuid>/` | Deleted on window close and at quit. Same pattern as `FocalModels` / `FocalMarkdown`. |
| Read-only | the document classes (`ImageDocument`, `PDFFileDocument`, `TextDocument`, …) | A file under `FocalArchives` saves through Save As, with the panel starting in the archive's own folder. One shared check (`ArchiveBrowser.isUnpacked(url)`). |

### Unpacking with `/usr/bin/tar` (bsdtar/libarchive, part of macOS)
Reads ZIP, 7z, RAR/RAR5, tar (+gz/bz2/xz/zst), cpio, ISO 9660, XAR, LHA, CAB. No new dependency, same approach as `usdcat` for glTF.

1. **List** with `tar -tvf archive`: entry count and total uncompressed size. Over **4 GB or 10 000 entries**, refuse with a clear message (guards against ZIP bombs).
2. **Extract** into `<uuid>/staging/` with `tar -xf archive -C staging --no-same-owner --no-same-permissions`. By default bsdtar refuses absolute paths and `..` entries; we also check every resolved path stays inside `staging`.
3. **Flatten** by walking staging and moving viewable regular files (via `FolderNavigator.isViewable`) into `<uuid>/`. Symlinks, `__MACOSX/`, `.DS_Store`, `._*` and hidden files are dropped, and so are nested archives (not opened recursively in v1). If two files have the same name, the second gets its folder name added: `IMG_001 (holiday).jpg`. Finally remove staging.
4. **Sort** in Finder's name order (`localizedStandardCompare`), which is what `siblings(of:)` and ⌘[ ⌘] already use. Because the folder is flat, neighbour stepping needs no changes.

Runs off the main thread, with a progress indicator if it takes longer than about 300 ms. Errors are turned into plain English: password-protected ("Focal can't open password-protected archives"), damaged, unsupported format.

### Type matching: exact types, not conformance
`.docx`, `.xlsx`, `.epub`, `.pages`, `.jar` and `.ipa` conform to `public.zip-archive`. Matching by conformance would put Focal in Open With for Word files and "browse" their XML innards. So we claim and check an **explicit list**: `public.zip-archive`, `org.7-zip.7-zip-archive`, `com.rarlab.rar-archive`, `public.tar-archive`, `org.gnu.gnu-zip-tar-archive`, `public.tar-bzip2-archive`, `org.tukaani.tar-xz-archive`, `public.cpio-archive`, `public.iso-image`, `com.apple.xar-archive`, `public.lha-archive`, `com.microsoft.cab`. These identifiers get checked on the Mac (`mdls -name kMDItemContentTypeTree`). A plain `.gz` of one file is out of scope.

## Tests

- **Unit (Swift Testing), `ArchiveBrowserTests`**: fixtures built at test time with `tar -a -cf` / `ditto -c -k` in a temp directory.
  - flattening and name dedupe
  - junk filtered out
  - `../evil` entry rejected
  - symlink dropped
  - size cap refuses
  - password ZIP gives the right error
  - `.docx` not treated as an archive
- **UI (`scripts/uitest.sh`)**: open a ZIP of mixed image/PDF/text/video and `dump` the sidebar count and title; step with ⌘]; mark up an image and check ⌘S shows Save As. Also check that the temp folder is gone after close.
- **Through macOS** (per CLAUDE.md): `open -n -a "build.noindex/Focal Dev.app" x.zip y.7z` and count windows. Check Get Info ▸ Open With lists Focal while Archive Utility stays the default.

## Order of work
1. `ArchiveBrowser`, list, extract, flatten, plus unit tests
2. Controller hook and Info.plist type
3. Cleanup on close and at quit
4. Save-as-only for unpacked files
5. Progress and error messages
6. UI run, then update CLAUDE.md (Layout table, a Decisions entry for the exact-type rule) and the README table

## Open points / risks
- **Unpacks everything up front.** The sidebar's Quick Look thumbnails need real files, so v1 extracts every file it can show when the archive opens. A large archive takes a few seconds; unpacking each file only when viewed is a later step if that proves slow.
- **Filenames from Windows ZIPs** that aren't UTF-8 can come out garbled. bsdtar's `--options hdrcharset=CP437` is a possible fallback, so test it with a real Windows ZIP.
- **ISO images** may already open via DiskImageMounter for Open With. Drop ISO from the list if it feels wrong.
