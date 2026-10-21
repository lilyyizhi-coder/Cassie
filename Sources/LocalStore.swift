import Foundation
import Combine

enum LocalStore {
    static func file(_ name: String) throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("Cassie", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excludedFolder = folder
        try excludedFolder.setResourceValues(values)
        return folder.appendingPathComponent(name)
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: file(name)))
    }

    static func save<T: Encodable>(_ value: T, to name: String) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: file(name), options: [.atomic, .completeFileProtection])
    }

    static func remove(_ name: String) throws {
        let url = try file(name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

struct VoiceNote: Codable, Identifiable {
    var id = UUID()
    var text: String
    var createdAt = Date()
}

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [VoiceNote] = []
    @Published var error: String?

    init() {
        do { notes = try LocalStore.load([VoiceNote].self, from: "notes.json") }
        catch let problem as CocoaError where problem.code == .fileReadNoSuchFile { }
        catch { self.error = "����¼��ʱ�޷���ȡ��\(error.localizedDescription)" }
    }

    @discardableResult
    func add(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let updated = [VoiceNote(text: trimmed)] + notes
        do {
            try LocalStore.save(updated, to: "notes.json")
            notes = updated
            error = nil
            return true
        } catch {
            self.error = "δ���棺\(error.localizedDescription)"
            return false
        }
    }

    func delete(at offsets: IndexSet) {
        let updated = notes.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        do {
            try LocalStore.save(updated, to: "notes.json")
            notes = updated
        } catch { self.error = error.localizedDescription }
    }
}
