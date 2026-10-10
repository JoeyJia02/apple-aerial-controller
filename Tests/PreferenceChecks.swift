import Foundation

@main
struct PreferenceChecks {
    static func main() throws {
        guard let directoryArgument = CommandLine.arguments.dropFirst().first else {
            fatalError("Pass a writable test directory; this check never touches real app preferences")
        }
        let directory = URL(fileURLWithPath: directoryArgument).appendingPathComponent(UUID().uuidString)
        let store = PreferenceStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fresh = try store.load()
        precondition(fresh == ControllerPreferences() && !fresh.rotationRequested,
                     "First launch must not request automatic rotation")
        precondition(!FileManager.default.fileExists(atPath: store.fileURL.path), "Loading defaults must not write preferences")
        let requested = ControllerPreferences(selectedCategoryKeys: ["underwater", "landscape"], intervalMinutes: 37)
        try store.save(requested)
        let persisted = try store.load()
        precondition(Set(persisted.selectedCategoryKeys) == ["landscape", "underwater"]
                     && persisted.intervalMinutes == 37 && !persisted.rotationRequested)
        print("PASS fresh opt-out defaults and existing memberwise initializer compatibility")

        let legacyBytes = Data(#"{"version":1,"selectedCategoryKeys":["underwater"],"intervalMinutes":37}"#.utf8)
        try legacyBytes.write(to: store.fileURL)
        let migrated = try store.load()
        precondition(migrated.version == 1 && migrated.selectedCategoryKeys == ["underwater"]
                     && migrated.intervalMinutes == 37 && !migrated.rotationRequested,
                     "Old preferences must preserve settings and default only the new intent to false")
        let legacyAfterRead = try Data(contentsOf: store.fileURL)
        precondition(legacyAfterRead == legacyBytes, "Migration on read must not rewrite the old file")
        print("PASS legacy v1 missing rotation intent loads false without rewriting settings")

        for flag in [true, false, true] {
            let intent = ControllerPreferences(selectedCategoryKeys: ["earth", "landscape"],
                                               intervalMinutes: 120, rotationRequested: flag)
            try store.save(intent)
            let loaded = try store.load()
            precondition(loaded == intent.validated(), "Saving must preserve true/false rotation intent and UI settings")
        }
        print("PASS true/false rotation intent persists with category and interval settings")

        let invalid = ControllerPreferences(selectedCategoryKeys: ["unknown", "earth", "earth"],
                                            intervalMinutes: 0, rotationRequested: true)
        try store.save(invalid)
        let repaired = try store.load()
        precondition(repaired.selectedCategoryKeys == ["earth"] && repaired.intervalMinutes == 15
                     && repaired.rotationRequested, "Settings normalization must not change the saved intent")
        let invalidBytes = Data(#"{"version":1,"selectedCategoryKeys":["earth","unknown","earth"],"intervalMinutes":0,"rotationRequested":true}"#.utf8)
        try invalidBytes.write(to: store.fileURL)
        let sanitized = try store.load()
        precondition(sanitized.selectedCategoryKeys == ["earth"] && sanitized.intervalMinutes == 15 && sanitized.rotationRequested)
        let invalidAfterRead = try Data(contentsOf: store.fileURL)
        precondition(invalidAfterRead == invalidBytes, "Read-time normalization must not modify the file")
        print("PASS invalid category/interval normalization preserves intent and never rewrites on load")

        for flag in [true, false] {
            try store.save(ControllerPreferences(selectedCategoryKeys: [],
                                                intervalMinutes: ControllerPreferences.maximumMinutes,
                                                rotationRequested: flag))
            let empty = try store.load()
            precondition(empty.selectedCategoryKeys.isEmpty && empty.rotationRequested == flag,
                         "Preferences must preserve an empty pool; readiness, not preference decoding, decides whether rotation can run")
            precondition(empty.intervalMinutes == ControllerPreferences.maximumMinutes)
        }
        print("PASS empty category selection and maximum interval preserve either intent value")

        for invalidValue in [#""true""#, "1", "null", "[]", "{}"] {
            let bytes = Data("{\"version\":1,\"selectedCategoryKeys\":[\"landscape\"],\"intervalMinutes\":15,\"rotationRequested\":\(invalidValue)}".utf8)
            try bytes.write(to: store.fileURL)
            do { _ = try store.load(); fatalError("Present non-Boolean intent must report a decoding error") }
            catch is DecodingError { }
            let afterRead = try Data(contentsOf: store.fileURL)
            precondition(afterRead == bytes, "Invalid intent must not be repaired or overwritten silently")
        }
        print("PASS string, numeric, null, array and object rotation intents fail without changing disk")

        try Data("broken-json".utf8).write(to: store.fileURL)
        do { _ = try store.load(); fatalError("Corrupt preferences must report a load error") }
        catch is DecodingError { }
        let preserved = try Data(contentsOf: store.fileURL)
        precondition(preserved == Data("broken-json".utf8), "A read must not replace corrupted data")
        print("PASS corrupt-read preservation")
        print("All preference checks passed. Only an isolated test directory was used; no app or login items were started.")
    }
}
