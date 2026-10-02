import Foundation

/// A finished export packed into one `.zip` (`ExportRequest.zipped`).
public struct ExportArchive: Sendable, Equatable {
    /// The archive. It is also the only element of `ExportResult.files`.
    public var url: URL
    /// The files inside it, by name, in the order `ExportResult.files` would
    /// have listed them: the data files, then the manifest. They sit in one
    /// folder named after the export (`puls-export-<yyyyMMdd-HHmmss>/`), which
    /// is what unzipping produces.
    public var entries: [String]
    /// Their total size before compression.
    public var contentBytes: Int64

    public init(url: URL, entries: [String], contentBytes: Int64) {
        self.url = url
        self.entries = entries
        self.contentBytes = contentBytes
    }
}

/// Zips a folder with `NSFileCoordinator`'s `.forUploading` read, the one zip
/// writer iOS ships: deflated entries, and no dependency, which the privacy
/// documents promise the app has none of.
///
/// The coordinator builds the archive in a scratch directory of its own under
/// the temporary directory and deletes it once the accessor returns, so the
/// archive is cloned out of it into the export's directory inside the
/// accessor. A crash while it is zipping would leave that scratch directory
/// behind, outside `HealthExporter.stagingRoot`, which is why
/// `removeAllExports()` sweeps it too (`scratchPrefix`).
enum ExportZipper {
    /// How the coordinator's scratch directories are named in the temporary
    /// directory (`CoordinatedZipFileXXXXXX`, a `mkdtemp` template). Not API —
    /// observed on iOS 26 and macOS 26 — and `ExportZipTests` fails if it
    /// changes, because a crash mid-zip would then leave a partial archive of
    /// health data that the next launch does not remove.
    static let scratchPrefix = "CoordinatedZipFile"

    struct Zipped {
        var bytes: Int64
        /// Where the coordinator built it; gone by the time this is returned.
        var scratchDirectory: URL
    }

    /// Zip `folder`, which becomes the archive's single top-level folder, to
    /// `destination`. Synchronous, CPU-bound and, for an all-time export, not
    /// quick, so call it off the cooperative pool (`zip`).
    static func zipSynchronously(folder: URL, to destination: URL) throws -> Zipped {
        var coordinationError: NSError?
        var result: Result<Zipped, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(
            readingItemAt: folder, options: .forUploading, error: &coordinationError
        ) { archive in
            result = Result {
                // A clone on APFS, so no second copy of the data is written.
                try FileManager.default.copyItem(at: archive, to: destination)
                // Explicit, as for every export file (`ExportFile`): a copy
                // keeps whatever class the coordinator's scratch file had.
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: destination.path)
                let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                return Zipped(bytes: Int64(size), scratchDirectory: archive.deletingLastPathComponent())
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// `zipSynchronously` on a global queue, so a minute of deflate does not
    /// hold a thread of the cooperative pool the rest of the app runs on.
    static func zip(folder: URL, to destination: URL) async throws -> Zipped {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try zipSynchronously(folder: folder, to: destination) })
            }
        }
    }

    /// Remove every coordinator scratch directory in `directory`. Only call it
    /// when no export is running (`HealthExporter.removeAllExports()`).
    /// Returns false if one could not be removed.
    static func removeScratch(in directory: URL = FileManager.default.temporaryDirectory) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return true
        }
        var removedAll = true
        for name in names where name.hasPrefix(scratchPrefix) {
            do {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            } catch {
                removedAll = false
            }
        }
        return removedAll
    }
}
