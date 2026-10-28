import Foundation

enum NoteFileError: LocalizedError, Equatable {
    case conflict
    case rolloverCopyChanged(URL)

    var errorDescription: String? {
        switch self {
        case .conflict:
            "This file was changed, created, or deleted outside Portal. Save a copy to keep your version, or reload from disk."
        case .rolloverCopyChanged(let url):
            "The saved daily note \(url.lastPathComponent) is missing, unreadable, or changed. The previous note’s todos were left untouched. Restore the saved daily note before retrying, or keep both versions."
        }
    }
}

/// Compares bytes, not dates, inside the same coordinated access as the write.
enum NotePersistence {
    static func read(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func text(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    /// A nil baseline means a new file: even an empty existing file is a conflict.
    static func write(_ data: Data, to url: URL, baseline: Data?) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            result = Result {
                if let baseline {
                    guard try contentsIfPresent(coordinatedURL) == baseline else { throw NoteFileError.conflict }
                } else {
                    guard try !isOccupied(coordinatedURL) else { throw NoteFileError.conflict }
                }
                try FileManager.default.createDirectory(at: coordinatedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Exclusive creation also protects new paths from uncoordinated writers.
                try data.write(to: coordinatedURL, options: baseline == nil ? .withoutOverwriting : .atomic)
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Always creates a separate file, including when a chosen path already exists.
    static func saveCopy(_ data: Data, to requestedURL: URL) throws -> URL {
        let folder = requestedURL.deletingLastPathComponent()
        let name = requestedURL.deletingPathExtension().lastPathComponent
        let ext = requestedURL.pathExtension
        var candidate = requestedURL
        var suffix = 1
        while true {
            do {
                try write(data, to: candidate, baseline: nil)
                return candidate
            } catch NoteFileError.conflict {
                // Try another name; never replace an existing copy.
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // A non-coordinating writer won the exclusive-create race.
            }
            suffix += 1
            candidate = folder.appending(path: "\(name) \(suffix)" + (ext.isEmpty ? "" : ".\(ext)"))
        }
    }

    /// Returns false for an occupied destination, leaving both files unchanged.
    static func rename(_ source: URL, to destination: URL, baseline: Data) throws -> Bool {
        var coordinationError: NSError?
        var result: Result<Bool, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(writingItemAt: source, options: .forMoving,
                                      writingItemAt: destination, options: [], error: &coordinationError) { from, to in
            result = Result {
                guard try contentsIfPresent(from) == baseline else { throw NoteFileError.conflict }
                guard try !isOccupied(to) else { return false }
                do {
                    try FileManager.default.moveItem(at: from, to: to)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    return false
                }
                return true
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Keep the durable destination locked while checking and updating the source.
    static func removeRolledTodos(_ data: Data, from source: URL, baseline: Data,
                                 copiedTo destination: URL, savedCopy: Data) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(readingItemAt: destination, options: [],
                                      writingItemAt: source, options: .forReplacing, error: &coordinationError) { copy, original in
            result = Result {
                guard (try? Data(contentsOf: copy)) == savedCopy else { throw NoteFileError.rolloverCopyChanged(destination) }
                guard try contentsIfPresent(original) == baseline else { throw NoteFileError.conflict }
                try data.write(to: original, options: .atomic)
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Metadata includes directories and dangling symlinks without reading their contents.
    private static func isOccupied(_ url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return false
        }
    }

    private static func contentsIfPresent(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }
}

struct NoteIssue {
    enum Kind { case read, save, conflict }

    let kind: Kind
    let url: URL
    let message: String

    var title: String {
        switch kind {
        case .read: "Couldn’t read \(url.lastPathComponent)"
        case .save: "Couldn’t save \(url.lastPathComponent)"
        case .conflict: "\(url.lastPathComponent) changed outside Portal"
        }
    }
}
