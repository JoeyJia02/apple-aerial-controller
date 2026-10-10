import Foundation

struct ControllerPreferences: Codable, Equatable, Sendable {
    var version = 1
    var selectedCategoryKeys = ["landscape", "underwater"]
    var intervalMinutes = 15
    var rotationRequested = false

    private enum CodingKeys: String, CodingKey {
        case version, selectedCategoryKeys, intervalMinutes, rotationRequested
    }

    static let maximumMinutes = 525_600

    func validated() -> ControllerPreferences {
        var result = self
        result.version = 1
        let known = Set(["landscape", "underwater", "cityscape", "earth"])
        result.selectedCategoryKeys = Array(Set(selectedCategoryKeys.filter { known.contains($0) })).sorted()
        if !(1...Self.maximumMinutes).contains(intervalMinutes) { result.intervalMinutes = 15 }
        return result
    }
}

extension ControllerPreferences {
    // Keep the synthesized memberwise initializer by implementing decoding in
    // an extension. Old v1 files omit only the new rotation-intent field.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        selectedCategoryKeys = try values.decode([String].self, forKey: .selectedCategoryKeys)
        intervalMinutes = try values.decode(Int.self, forKey: .intervalMinutes)
        if values.contains(.rotationRequested) {
            rotationRequested = try values.decode(Bool.self, forKey: .rotationRequested)
        } else {
            rotationRequested = false
        }
    }
}

struct PreferenceStore: Sendable {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("preferences.json") }

    func load() throws -> ControllerPreferences {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ControllerPreferences() }
        return try JSONDecoder().decode(ControllerPreferences.self, from: Data(contentsOf: fileURL)).validated()
    }

    func save(_ preferences: ControllerPreferences) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences.validated()).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

enum ControllerPaths {
    static var supportDirectory: URL {
        if let index = CommandLine.arguments.firstIndex(of: "--support-directory"),
           CommandLine.arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        }
        if let developmentPath = Bundle.main.object(forInfoDictionaryKey: "AerialDevelopmentSupportDirectory") as? String {
            return URL(fileURLWithPath: developmentPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppleAerialController", isDirectory: true)
    }
}
