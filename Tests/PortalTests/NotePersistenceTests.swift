import Foundation
import Testing
@testable import Portal

private enum OccupiedDestination: CaseIterable {
    case directory, unreadableFile, symlink, danglingSymlink
}

/// Every test opts out of discovery and uses its own vault and defaults suite.
@MainActor
private struct TestVault {
    let root: URL
    let defaults: UserDefaults
    let suite: String
    let store: NoteStore

    init() throws {
        suite = "PortalTests.safer-saving.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory
            .appending(path: "opencode/portal-safer-saving-\(UUID().uuidString)", directoryHint: .isDirectory)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(defaults: defaults, restoreVault: false)
        store.isObsidianRunning = { false }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    @discardableResult
    func write(_ text: String, to path: String) throws -> URL {
        let url = root.appending(path: path).standardizedFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func open() { store.open(vault: root) }

    func blockNewNote() throws -> URL {
        try write(#"{"newFileLocation":"folder","newFileFolderPath":"Blocked"}"#, to: ".obsidian/app.json")
        try write("not a directory", to: "Blocked")
        store.create(named: "Draft")
        store.text = "Keep these unsaved words"
        return try #require(store.selectedID)
    }

    func occupy(_ path: String, with kind: OccupiedDestination) throws -> URL {
        let url = root.appending(path: path)
        switch kind {
        case .directory:
            try write("Occupied", to: path + "/marker")
        case .unreadableFile:
            try write("Occupied", to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            #expect(throws: CocoaError.self) { try Data(contentsOf: url) }
        case .symlink, .danglingSymlink:
            let target = root.appending(path: path + ".target")
            if kind == .symlink { try write("Occupied", to: path + ".target") }
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        }
        return url
    }

    func checkOccupant(_ url: URL, kind: OccupiedDestination) throws {
        switch kind {
        case .directory:
            #expect(try String(contentsOf: url.appending(path: "marker"), encoding: .utf8) == "Occupied")
        case .unreadableFile:
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #expect(try String(contentsOf: url, encoding: .utf8) == "Occupied")
        case .symlink, .danglingSymlink:
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeSymbolicLink)
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            #expect(target == url.path + ".target")
            if kind == .symlink {
                #expect(try String(contentsOfFile: target, encoding: .utf8) == "Occupied")
            } else {
                #expect(!FileManager.default.fileExists(atPath: target))
            }
        }
    }

    func pendingRollover() throws -> (source: URL, destination: URL, savedCopy: Data) {
        let source = try write("- [ ] Todo\nDone", to: "Daily/2026/10/31.md")
        try write(#"{"folder":"Daily","format":"YYYY/MM/DD"}"#, to: ".obsidian/daily-notes.json")
        try write(#"["obsidian-rollover-daily-todos"]"#, to: ".obsidian/community-plugins.json")
        try write(#"{"deleteOnComplete":true}"#, to: ".obsidian/plugins/obsidian-rollover-daily-todos/data.json")
        open()
        let folder = source.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        store.openDailyNote(on: try #require(Obsidian.date(from: "2026-11-01", format: "YYYY-MM-DD")))
        let destination = root.appending(path: "Daily/2026/11/01.md")
        #expect(store.selectedID == destination)
        #expect(!store.isDirty)
        try #require(store.issue?.kind == .save)
        #expect(store.canRetry)
        #expect(try String(contentsOf: source, encoding: .utf8) == "- [ ] Todo\nDone")
        return (source, destination, try Data(contentsOf: destination))
    }
}

@MainActor
private func withVault(_ body: (TestVault) throws -> Void) throws {
    let vault = try TestVault()
    defer { vault.cleanup() }
    try body(vault)
}

@MainActor
@Test func normalSaveAdvancesBaselineOnlyAfterWriting() throws {
    try withVault { vault in
        let file = try vault.write("Original", to: "Note.md")
        vault.open()
        vault.store.text = "First save"
        #expect(vault.store.isDirty)
        #expect(vault.store.flush())
        #expect(!vault.store.isDirty)
        #expect(vault.store.issue == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "First save")
        vault.store.text = "Second save"
        #expect(vault.store.flush())
        #expect(try String(contentsOf: file, encoding: .utf8) == "Second save")
    }
}

@MainActor
@Test func failedSaveKeepsDirtyTextAndCanBeRetried() throws {
    try withVault { vault in
        vault.open()
        let file = try vault.blockNewNote()
        #expect(!vault.store.flush())
        #expect(vault.store.isDirty)
        #expect(vault.store.text == "Keep these unsaved words")
        #expect(vault.store.issue?.kind == .save)
        #expect(vault.store.canRetry)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        try FileManager.default.removeItem(at: vault.root.appending(path: "Blocked"))
        vault.store.retry()
        #expect(!vault.store.isDirty)
        #expect(vault.store.issue == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Keep these unsaved words")
    }
}

@MainActor
@Test(arguments: [false, true])
func externalChangesConflictEvenWithTheSameModificationDate(restoreDate: Bool) throws {
    try withVault { vault in
        let file = try vault.write("Baseline", to: "Note.md")
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        vault.open()
        vault.store.text = "My local edits"
        try vault.write("External edits", to: "Note.md")
        if restoreDate {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == modified)
        }
        #expect(!vault.store.flush())
        #expect(vault.store.issue?.kind == .conflict)
        #expect(vault.store.isDirty)
        #expect(vault.store.text == "My local edits")
        #expect(try String(contentsOf: file, encoding: .utf8) == "External edits")
        #expect(!vault.store.flush())
    }
}

@MainActor
@Test func deletedFileConflictsInsteadOfBeingRecreated() throws {
    try withVault { vault in
        let file = try vault.write("Baseline", to: "Note.md")
        vault.open()
        vault.store.text = "My local edits"
        try FileManager.default.removeItem(at: file)
        vault.store.refresh()
        #expect(vault.store.selectedID == file)
        #expect(!vault.store.flush())
        #expect(vault.store.issue?.kind == .conflict)
        #expect(vault.store.isDirty)
        #expect(vault.store.text == "My local edits")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@MainActor
@Test func newNotePathCollisionDoesNotOverwriteEvenAnEmptyFile() throws {
    try withVault { vault in
        vault.open()
        vault.store.create(named: "New")
        let file = try #require(vault.store.selectedID)
        try vault.write("", to: "New.md")
        vault.store.text = "My new note"
        #expect(!vault.store.flush())
        #expect(vault.store.issue?.kind == .conflict)
        #expect(vault.store.isDirty)
        #expect(try Data(contentsOf: file).isEmpty)
    }
}

@MainActor
@Test func saveCopyPreservesExternalVersionAndAllExistingCopies() throws {
    try withVault { vault in
        let original = try vault.write("Baseline", to: "Note.md")
        vault.open()
        vault.store.text = "My local edits"
        try vault.write("External edits", to: "Note.md")
        #expect(!vault.store.flush())
        let requested = try vault.write("Existing copy", to: "Copy.md")
        let second = try vault.write("Another copy", to: "Copy 2.md")
        #expect(vault.store.saveCopy(to: requested))
        let copy = try #require(vault.store.selectedID)
        #expect(copy.lastPathComponent == "Copy 3.md")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "My local edits")
        #expect(try String(contentsOf: original, encoding: .utf8) == "External edits")
        #expect(try String(contentsOf: requested, encoding: .utf8) == "Existing copy")
        #expect(try String(contentsOf: second, encoding: .utf8) == "Another copy")
        #expect(!vault.store.isDirty)
        #expect(vault.store.issue == nil)
        vault.store.text = "Edit the copy"
        #expect(vault.store.flush())
        #expect(try String(contentsOf: original, encoding: .utf8) == "External edits")
    }
}

@MainActor
@Test(arguments: OccupiedDestination.allCases)
private func saveCopySkipsEveryOccupiedCandidate(kind: OccupiedDestination) throws {
    try withVault { vault in
        let requested = try vault.write("Existing copy", to: "Copy.md")
        let occupied = try vault.occupy("Copy 2.md", with: kind)
        let data = Data("Recovered edits".utf8)
        let copy = try NotePersistence.saveCopy(data, to: requested)
        #expect(copy.lastPathComponent == "Copy 3.md")
        #expect(try Data(contentsOf: copy) == data)
        #expect(try String(contentsOf: requested, encoding: .utf8) == "Existing copy")
        try vault.checkOccupant(occupied, kind: kind)
    }
}

@MainActor
@Test func concurrentCopiesNeverClobberEachOther() async throws {
    let vault = try TestVault()
    defer { vault.cleanup() }
    let requested = vault.root.appending(path: "Copy.md")
    let copies = try await withThrowingTaskGroup(of: (URL, Data).self) { group in
        for index in 0..<8 {
            let data = Data("Copy \(index)".utf8)
            group.addTask { (try NotePersistence.saveCopy(data, to: requested), data) }
        }
        var results: [(URL, Data)] = []
        for try await result in group { results.append(result) }
        return results
    }
    #expect(Set(copies.map(\.0)).count == 8)
    for (url, expected) in copies { #expect(try Data(contentsOf: url) == expected) }
}

@MainActor
@Test func failedCopyKeepsTheOriginalDirtyBuffer() throws {
    try withVault { vault in
        let original = try vault.write("Baseline", to: "Note.md")
        vault.open()
        vault.store.text = "My local edits"
        let blocker = try vault.write("not a directory", to: "Blocked")
        #expect(!vault.store.saveCopy(to: blocker.appending(path: "Copy.md")))
        #expect(vault.store.selectedID == original)
        #expect(vault.store.text == "My local edits")
        #expect(vault.store.isDirty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "Baseline")
    }
}

@MainActor
@Test func failedSaveBlocksNavigationCreationDailyRolloverAndTheQuitGate() throws {
    try withVault { vault in
        let other = try vault.write("Other note", to: "Other.md")
        let previous = try vault.write("- [ ] Keep this todo", to: "2026-10-27.md")
        try vault.write(#"["obsidian-rollover-daily-todos"]"#, to: ".obsidian/community-plugins.json")
        try vault.write(#"{"deleteOnComplete":true}"#, to: ".obsidian/plugins/obsidian-rollover-daily-todos/data.json")
        vault.open()
        let draft = try vault.blockNewNote()
        let noteCount = vault.store.notes.count
        let otherVault = vault.root.appending(path: "OtherVault", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: otherVault, withIntermediateDirectories: true)

        vault.store.select(other)
        vault.store.create()
        vault.store.open(link: "Missing")
        vault.store.open(vault: otherVault)
        vault.store.openDailyNote(on: try #require(Obsidian.date(from: "2026-10-28", format: "YYYY-MM-DD")))
        // AppDelegate.applicationShouldTerminate uses this exact Boolean gate.
        #expect(!vault.store.leaveCurrentNote())
        #expect(vault.store.selectedID == draft)
        #expect(vault.store.vault == vault.root)
        #expect(vault.store.notes.count == noteCount)
        #expect(vault.store.isDirty)
        #expect(vault.store.text == "Keep these unsaved words")
        #expect(vault.defaults.string(forKey: "vaultPath") == vault.root.path)
        #expect(vault.defaults.string(forKey: "lastNotePath") == draft.path)
        #expect(try String(contentsOf: previous, encoding: .utf8) == "- [ ] Keep this todo")
        #expect(!FileManager.default.fileExists(atPath: vault.root.appending(path: "2026-10-28.md").path))
    }
}

@MainActor
@Test func initialReadFailureIsVisibleAndNotEditableAndRetryRecovers() throws {
    try withVault { vault in
        let file = vault.root.appending(path: "Invalid.md")
        try Data([0xff, 0xfe, 0xff]).write(to: file)
        vault.open()
        #expect(vault.store.issue?.kind == .read)
        #expect(vault.store.selectedID == nil)
        #expect(!vault.store.canEdit)
        vault.store.text = "Must not replace unreadable data"
        #expect(!vault.store.isDirty)
        #expect(try Data(contentsOf: file) == Data([0xff, 0xfe, 0xff]))

        try vault.write("Readable again", to: "Invalid.md")
        vault.store.retry()
        #expect(vault.store.selectedID == file)
        #expect(vault.store.canEdit)
        #expect(vault.store.text == "Readable again")
        #expect(vault.store.issue == nil)
    }
}

@MainActor
@Test func failedReadKeepsThePreviouslyLoadedNote() throws {
    try withVault { vault in
        let good = try vault.write("Keep the current note", to: "Good.md")
        let bad = vault.root.appending(path: "Bad.md")
        try Data([0xff]).write(to: bad)
        vault.open()
        vault.store.select(good)
        vault.store.select(bad)
        #expect(vault.store.selectedID == good)
        #expect(vault.store.text == "Keep the current note")
        #expect(vault.store.issue?.kind == .read)
    }
}

@MainActor
@Test func failedVaultReadKeepsTheCurrentVaultAndBuffer() throws {
    try withVault { vault in
        let current = try vault.write("Current note", to: "Current.md")
        let notDirectory = try vault.write("not a directory", to: "Not a vault")
        vault.open()
        vault.store.open(vault: notDirectory)
        #expect(vault.store.vault == vault.root)
        #expect(vault.store.selectedID == current)
        #expect(vault.store.text == "Current note")
        #expect(vault.store.issue?.kind == .read)
        #expect(vault.defaults.string(forKey: "vaultPath") == vault.root.path)
    }
}

@MainActor
@Test func reloadNeedsExplicitDiscardAndFailedReloadKeepsDirtyText() throws {
    try withVault { vault in
        let file = try vault.write("Baseline", to: "Note.md")
        vault.open()
        vault.store.text = "My local edits"
        try vault.write("External edits", to: "Note.md")
        #expect(!vault.store.flush())
        vault.store.reloadCurrentNote()
        #expect(vault.store.text == "My local edits")
        #expect(vault.store.isDirty)
        try Data([0xff]).write(to: file)
        vault.store.reloadCurrentNote(discardChanges: true)
        #expect(vault.store.text == "My local edits")
        #expect(vault.store.isDirty)
        #expect(vault.store.issue?.kind == .read)
        // Retry must also respect the dirty-buffer gate after a failed discard/read.
        vault.store.retry()
        #expect(vault.store.text == "My local edits")
        #expect(vault.store.isDirty)
        try vault.write("External edits", to: "Note.md")
        vault.store.reloadCurrentNote(discardChanges: true)
        #expect(vault.store.text == "External edits")
        #expect(!vault.store.isDirty)
        #expect(vault.store.issue == nil)
    }
}

@MainActor
@Test func refreshFindsChangedBytesWithoutRelyingOnModificationDate() throws {
    try withVault { vault in
        let file = try vault.write("Baseline", to: "Note.md")
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        vault.open()
        try vault.write("External edits", to: "Note.md")
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        #expect(vault.store.refresh())
        #expect(vault.store.text == "External edits")
        vault.store.text = "After refresh"
        #expect(vault.store.flush())
    }
}

@MainActor
@Test func failedDailyWriteKeepsRolledTodosAndDoesNotDeleteTheirSource() throws {
    try withVault { vault in
        let previous = try vault.write("- [ ] Keep this todo\nDone", to: "Daily/2026/10/31.md")
        try vault.write("not a directory", to: "Daily/2026/11")
        try vault.write(#"{"folder":"Daily","format":"YYYY/MM/DD"}"#, to: ".obsidian/daily-notes.json")
        try vault.write(#"["obsidian-rollover-daily-todos"]"#, to: ".obsidian/community-plugins.json")
        try vault.write(#"{"deleteOnComplete":true}"#, to: ".obsidian/plugins/obsidian-rollover-daily-todos/data.json")
        vault.open()
        vault.store.openDailyNote(on: try #require(Obsidian.date(from: "2026-11-01", format: "YYYY-MM-DD")))
        #expect(vault.store.isDirty)
        #expect(vault.store.text.contains("- [ ] Keep this todo"))
        #expect(vault.store.issue?.kind == .save)
        #expect(try String(contentsOf: previous, encoding: .utf8) == "- [ ] Keep this todo\nDone")
        #expect(vault.store.saveCopy(to: vault.root.appending(path: "Recovered.md")))
        #expect(try String(contentsOf: previous, encoding: .utf8) == "- [ ] Keep this todo\nDone")
    }
}

@MainActor
@Test(arguments: [false, true])
func rolloverRetryPreservesSourceWhenItsDurableCopyDisappearedOrChanged(changed: Bool) throws {
    try withVault { vault in
        let pending = try vault.pendingRollover()
        let buffer = vault.store.text
        if changed {
            try "External replacement".write(to: pending.destination, atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.removeItem(at: pending.destination)
        }
        vault.store.retry()
        #expect(try String(contentsOf: pending.source, encoding: .utf8) == "- [ ] Todo\nDone")
        #expect(vault.store.issue?.message.contains("todos were left untouched") == true)
        #expect(vault.store.canRetry)
        #expect(vault.store.text == buffer)
        #expect(!vault.store.isDirty)

        vault.store.text = buffer + "\nUnsaved edits"
        vault.store.retry()
        #expect(vault.store.text == buffer + "\nUnsaved edits")
        #expect(vault.store.isDirty)
        #expect(try String(contentsOf: pending.source, encoding: .utf8) == "- [ ] Todo\nDone")
        #expect(vault.store.saveCopy(to: vault.root.appending(path: "Recovered.md")))
        #expect(try String(contentsOf: vault.root.appending(path: "Recovered.md"), encoding: .utf8) == buffer + "\nUnsaved edits")
    }
}

@MainActor
@Test(arguments: [false, true])
func firstRolloverCleanupRequiresTheExactDurableCopy(changed: Bool) throws {
    try withVault { vault in
        let original = Data("- [ ] Todo\nDone".utf8)
        let source = try vault.write("- [ ] Todo\nDone", to: "Yesterday.md")
        let destination = try vault.write("- [ ] Todo", to: "Today.md")
        let savedCopy = try Data(contentsOf: destination)
        if changed {
            try "External replacement".write(to: destination, atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.removeItem(at: destination)
        }
        #expect(throws: NoteFileError.rolloverCopyChanged(destination)) {
            try NotePersistence.removeRolledTodos(Data("Done".utf8), from: source, baseline: original,
                                                 copiedTo: destination, savedCopy: savedCopy)
        }
        #expect(try Data(contentsOf: source) == original)
    }
}

@MainActor
@Test func rolloverCleanupAlsoChecksTheSourceBaseline() throws {
    try withVault { vault in
        let original = Data("- [ ] Todo\nDone".utf8)
        let source = try vault.write("External source edits", to: "Yesterday.md")
        let destination = try vault.write("- [ ] Todo", to: "Today.md")
        let savedCopy = try Data(contentsOf: destination)
        #expect(throws: NoteFileError.conflict) {
            try NotePersistence.removeRolledTodos(Data("Done".utf8), from: source, baseline: original,
                                                 copiedTo: destination, savedCopy: savedCopy)
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "External source edits")
        #expect(try Data(contentsOf: destination) == savedCopy)
    }
}

@MainActor
@Test func rolloverRetrySucceedsWithTheUnchangedDurableCopy() throws {
    try withVault { vault in
        let pending = try vault.pendingRollover()
        vault.store.retry()
        #expect(try String(contentsOf: pending.source, encoding: .utf8) == "Done")
        #expect(try Data(contentsOf: pending.destination) == pending.savedCopy)
        #expect(vault.store.issue == nil)
        #expect(!vault.store.isDirty)
    }
}

@MainActor
@Test func dailyRolloverDeletesSourceTodosOnlyAfterSavingTheirCopy() throws {
    try withVault { vault in
        let previous = try vault.write("- [ ] Todo\nDone", to: "2026-10-27.md")
        try vault.write(#"["obsidian-rollover-daily-todos"]"#, to: ".obsidian/community-plugins.json")
        try vault.write(#"{"deleteOnComplete":true}"#, to: ".obsidian/plugins/obsidian-rollover-daily-todos/data.json")
        vault.open()
        vault.store.openDailyNote(on: try #require(Obsidian.date(from: "2026-10-28", format: "YYYY-MM-DD")))
        #expect(!vault.store.isDirty)
        #expect(vault.store.issue == nil)
        #expect(try String(contentsOf: previous, encoding: .utf8) == "Done")
        #expect(try String(contentsOf: vault.root.appending(path: "2026-10-28.md"), encoding: .utf8).contains("- [ ] Todo"))
    }
}

@MainActor
@Test func untitledRenameChecksTheBaselineAndKeepsExternalEditsInPlace() throws {
    try withVault { vault in
        vault.open()
        let untitled = try #require(vault.store.selectedID)
        vault.store.text = "# Local title"
        #expect(vault.store.flush())
        try "External title".write(to: untitled, atomically: true, encoding: .utf8)
        #expect(!vault.store.leaveCurrentNote())
        #expect(vault.store.isDirty)
        #expect(vault.store.issue?.kind == .conflict)
        #expect(vault.store.text == "# Local title")
        #expect(try String(contentsOf: untitled, encoding: .utf8) == "External title")
        #expect(!FileManager.default.fileExists(atPath: vault.root.appending(path: "Local title.md").path))
    }
}

@MainActor
@Test func untitledRenameNeverReplacesAnExistingNote() throws {
    try withVault { vault in
        vault.open()
        let untitled = try #require(vault.store.selectedID)
        vault.store.text = "# Local title"
        let existing = try vault.write("Existing note", to: "Local title.md")
        #expect(vault.store.leaveCurrentNote())
        #expect(vault.store.selectedID == untitled)
        #expect(try String(contentsOf: untitled, encoding: .utf8) == "# Local title")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "Existing note")
    }
}

@MainActor
@Test(arguments: OccupiedDestination.allCases)
private func untitledRenameSkipsOccupiedDestinationsWithoutBlockingNavigation(kind: OccupiedDestination) throws {
    try withVault { vault in
        vault.open()
        let untitled = try #require(vault.store.selectedID)
        let occupied = try vault.occupy("Folder.md", with: kind)
        vault.store.text = "# Folder"
        #expect(vault.store.leaveCurrentNote())
        #expect(vault.store.leaveCurrentNote())
        #expect(vault.store.selectedID == untitled)
        #expect(!vault.store.isDirty)
        #expect(vault.store.issue == nil)
        #expect(try String(contentsOf: untitled, encoding: .utf8) == "# Folder")
        try vault.checkOccupant(occupied, kind: kind)
        vault.store.create(named: "Next")
        #expect(vault.store.selectedID != untitled)
    }
}

@MainActor
@Test func successfulUntitledRenameKeepsTheBaselineForLaterSaves() throws {
    try withVault { vault in
        vault.open()
        let untitled = try #require(vault.store.selectedID)
        vault.store.text = "# Local title"
        #expect(vault.store.leaveCurrentNote())
        let renamed = try #require(vault.store.selectedID)
        #expect(renamed.lastPathComponent == "Local title.md")
        #expect(!FileManager.default.fileExists(atPath: untitled.path))
        vault.store.text = "# Local title\nMore text"
        #expect(vault.store.flush())
        #expect(try String(contentsOf: renamed, encoding: .utf8) == "# Local title\nMore text")
    }
}

@MainActor
@Test func missingDailyTemplateReportsReadFailureWithoutCreatingAnEmptyNote() throws {
    try withVault { vault in
        let current = try vault.write("Current", to: "Current.md")
        try vault.write(#"{"template":"Missing template"}"#, to: ".obsidian/daily-notes.json")
        vault.open()
        vault.store.openDailyNote(on: try #require(Obsidian.date(from: "2026-10-28", format: "YYYY-MM-DD")))
        #expect(vault.store.selectedID == current)
        #expect(vault.store.text == "Current")
        #expect(vault.store.issue?.kind == .read)
        #expect(!FileManager.default.fileExists(atPath: vault.root.appending(path: "2026-10-28.md").path))
    }
}
