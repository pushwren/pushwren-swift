import Foundation
import os

protocol StateStore: Sendable {
    func load() -> PersistedState?
    func save(_ state: PersistedState)
}

/// A JSON file of the SDK's own in Application Support, written atomically. Not UserDefaults, so
/// the privacy manifest needs no required-reason declaration.
struct FileStateStore: StateStore {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("state.json") }

    static func standard() -> FileStateStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FileStateStore(directory: base.appendingPathComponent("Pushwren", isDirectory: true))
    }

    func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    func save(_ state: PersistedState) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
        } catch {
            Log.error("Could not save Pushwren state: \(error.localizedDescription)")
        }
    }
}

/// State kept in memory only, for tests.
final class MemoryStateStore: StateStore {
    private let state = OSAllocatedUnfairLock<PersistedState?>(initialState: nil)
    func load() -> PersistedState? { state.withLock { $0 } }
    func save(_ s: PersistedState) { state.withLock { $0 = s } }
}
