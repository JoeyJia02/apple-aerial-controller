// macOS-native private wallpaper adapter for the explicitly requested V0.1.
// Initialization and prepare() are read-only. Only explicit switch/restore calls
// write the user's Store. No downloads, login agents, timers, or shell scripts.
import Foundation
import AppKit
import CoreGraphics
import CryptoKit
import Darwin

public enum NativeAerialSwitcherError: Error, Sendable, CustomStringConvertible {
    case busy, unsupportedScope(String), invalidAsset(String)
    case concurrentSettingsChange([String]), unsafeProcess(String)
    case commandFailed(String), rendererVerificationFailed(String)
    public var description: String {
        switch self {
        case .busy: return "A wallpaper operation is already in progress"
        case .unsupportedScope(let reason): return "Unsupported wallpaper configuration: \(reason)"
        case .invalidAsset(let id): return "Aerial is unavailable, outside the supported categories, or not downloaded: \(id)"
        case .concurrentSettingsChange(let paths): return "Wallpaper settings changed outside this app; switching is stopped: \(paths.joined(separator: ", "))"
        case .unsafeProcess(let reason): return "WallpaperAgent identity check failed: \(reason)"
        case .commandFailed(let reason): return "Native diagnostic failed: \(reason)"
        case .rendererVerificationFailed(let reason): return "Native video loading could not be verified: \(reason)"
        }
    }
}

public struct NativeAerialMovie: Codable, Sendable, Equatable {
    public let pid: String
    public let fileDescriptor: String
    public let path: String
    public let assetID: String
}
public struct NativeAerialSwitchResult: Codable, Sendable {
    public let assetID: String
    public let switchedAt: Date
    public let changedChoices: Int
    public let nativeProviderVerified: Bool
    public let movies: [NativeAerialMovie]
    public let backupPath: String
}
public struct NativeAerialRestoreResult: Codable, Sendable {
    public let restoredAt: Date
    public let status: String
    public let restorationAttempted: Bool
    public let selectionRestored: Bool
    public let nativeProviderVerified: Bool
    public let baselineMovieReopened: Bool
    public let byteExact: Bool
    public let mismatchPaths: [String]
    public let addedSettingPaths: [String]
    public let movies: [NativeAerialMovie]
}
public struct NativeAerialSwitcherDiagnostics: Codable, Sendable {
    public let isPrepared: Bool
    public let isOperating: Bool
    public let displayUUID: String?
    public let currentAssetID: String?
    public let baselineAssetID: String?
    public let hasOwnedChanges: Bool
    // A cached status. Call checkCurrentSettings() immediately before presenting
    // a restore action; restore itself repeats the live ownership check.
    public let canRestore: Bool
    public let externalChangeDetected: Bool
    public let conflictPaths: [String]
    public let backupPath: String?
    public let lastMessage: String
    public let nativeMovieIDs: [String]
}

public actor NativeAerialSwitcher {
    nonisolated private static let provider = "com.apple.wallpaper.choice.aerials"
    nonisolated private static let agentPath = "/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent"
    nonisolated private static let extensionPath = "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/MacOS/WallpaperAerialsExtension"
    private let supportDirectory: URL
    private let store: URL
    private let aerialRoot: URL
    private var displayUUID: String?
    private var currentAssetID: String?
    private var baselineSelection: String?
    private var baselineData: Data?
    private var expectedData: Data?
    private var expectedSnapshotName = "Index.expected.plist"
    private var pendingSnapshotName: String?
    private var pendingSnapshotSHA256: String?
    private var baselineMode: NSNumber?
    private var baselineMovies: [NativeAerialMovie] = []
    private var backupURL: URL?
    private var sessionDirectory: URL?
    private var mutated = false
    private var ownedWriteSerial = 0
    private var prepared = false
    private var operating = false
    private var recoveryLoaded = false
    private var conflictPaths: [String] = []
    private var lastMessage = "Not prepared; initialization did not change wallpaper"
    private var recentMovies: [NativeAerialMovie] = []

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.store = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        self.aerialRoot = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials")
    }

    public var canRestore: Bool { mutated && conflictPaths.isEmpty && !operating }
    public func diagnostics() -> NativeAerialSwitcherDiagnostics {
        NativeAerialSwitcherDiagnostics(isPrepared: prepared, isOperating: operating,
            displayUUID: displayUUID, currentAssetID: currentAssetID, baselineAssetID: baselineSelection,
            hasOwnedChanges: mutated, canRestore: canRestore, externalChangeDetected: !conflictPaths.isEmpty,
            conflictPaths: conflictPaths, backupPath: backupURL?.path, lastMessage: lastMessage,
            nativeMovieIDs: Array(Set(recentMovies.map(\.assetID))).sorted())
    }

    public func prepare() async throws -> NativeAerialSwitcherDiagnostics {
        try beginOperation(); defer { operating = false }
        do {
            try loadRecoveryIfNeeded()
            _ = try await validatedCurrentData()
            recentMovies = (try? probe(timeout: 2)) ?? []
            prepared = true
            lastMessage = "Ready; no wallpaper settings have been written"
            return diagnosticsAfterOperation()
        } catch { lastMessage = String(describing: error); throw error }
    }

    public func checkCurrentSettings() async throws -> NativeAerialSwitcherDiagnostics {
        try beginOperation(); defer { operating = false }
        do {
            try loadRecoveryIfNeeded()
            _ = try await validatedCurrentData()
            recentMovies = (try? probe(timeout: 2)) ?? []
            prepared = true
            lastMessage = mutated ? "Current settings still match this app's selection" : "Current native Aerial configuration is supported"
            return diagnosticsAfterOperation()
        } catch { lastMessage = String(describing: error); throw error }
    }

    /// Returns only the current fixed native movie, without acquiring ownership,
    /// writing wallpaper settings/journals, or reloading the wallpaper provider.
    /// The UI selection is checked against live settings rather than cached FDs,
    /// which may contain videos that the provider merely pre-opened.
    public func validatedReplaySource(expectedAssetID: String) async throws -> URL {
        try beginOperation(); defer { operating = false }
        do {
            try loadRecoveryIfNeeded()
            _ = try await validatedCurrentData()
            try Self.validateReplaySelection(expectedAssetID: expectedAssetID, currentAssetID: currentAssetID)
            let manifest = try currentManifest()
            try Self.validateLocalAsset(expectedAssetID, manifest: manifest, aerialRoot: aerialRoot)
            // Manifest/file inspection may take time. Recheck the live fixed
            // selection and existing ownership immediately before returning.
            _ = try await validatedCurrentData()
            try Self.validateReplaySelection(expectedAssetID: expectedAssetID, currentAssetID: currentAssetID)
            lastMessage = "Current native Aerial movie validated for local replay; no wallpaper settings were written"
            return aerialRoot.appendingPathComponent("videos/\(expectedAssetID).mov")
        } catch {
            if case NativeAerialSwitcherError.concurrentSettingsChange(let paths) = error {
                conflictPaths = paths
            }
            lastMessage = String(describing: error)
            throw error
        }
    }

    nonisolated static func validateReplaySelection(expectedAssetID: String, currentAssetID: String?) throws {
        guard UUID(uuidString: expectedAssetID) != nil else {
            throw NativeAerialSwitcherError.invalidAsset(expectedAssetID)
        }
        guard let currentAssetID, UUID(uuidString: currentAssetID) != nil, currentAssetID == expectedAssetID else {
            throw NativeAerialSwitcherError.concurrentSettingsChange(["current native Aerial assetID no longer matches the replay request"])
        }
    }

    // Explicit UI action only. This retains the prior backup for inspection;
    // ordinary refresh never drops ownership or its baseline automatically.
    public func adoptCurrentSettings() async throws -> NativeAerialSwitcherDiagnostics {
        try beginOperation(); defer { operating = false }
        do {
            let uuid = try await MainActor.run { try Self.singleBuiltinDisplayUUID() }
            try validateOwnedStore()
            let bytes = try Data(contentsOf: store)
            let schema = try Self.validateSchema(Self.decodedTree(bytes), displayUUID: uuid)
            if sessionDirectory != nil {
                let previousMutated = mutated
                mutated = false
                do { try saveJournal(status: "ownership-relinquished-current-settings-adopted") }
                catch { mutated = previousMutated; throw error }
            }
            let pointer = supportDirectory.appendingPathComponent("active-wallpaper-session.json")
            if FileManager.default.fileExists(atPath: pointer.path) { try FileManager.default.removeItem(at: pointer) }
            baselineData = nil; expectedData = nil; baselineSelection = nil; baselineMode = nil
            pendingSnapshotName = nil; pendingSnapshotSHA256 = nil; expectedSnapshotName = "Index.expected.plist"
            baselineMovies = []; backupURL = nil; sessionDirectory = nil; mutated = false
            conflictPaths = []; displayUUID = uuid; currentAssetID = schema.selection
            prepared = true; recoveryLoaded = true
            lastMessage = "Current settings adopted; the next switch will create a new baseline backup"
            return diagnosticsAfterOperation()
        } catch { lastMessage = String(describing: error); throw error }
    }

    public func `switch`(assetID: String) async throws -> NativeAerialSwitchResult {
        try beginOperation(); defer { operating = false }
        var previousSelection: String?
        var wroteThisOperation = false
        do {
            try loadRecoveryIfNeeded()
            let manifest = try currentManifest()
            try Self.validateLocalAsset(assetID, manifest: manifest, aerialRoot: aerialRoot)
            let current = try await validatedCurrentData()
            previousSelection = currentAssetID
            if baselineData == nil { try captureBaseline(current, manifest: manifest) }
            // Re-read after backup/probe IO and compare ownership once more.
            let candidate = try freshCandidate(assetID: assetID)
            // The target may already be pre-opened by the native provider. A
            // fresh predecessor prevents its old FD from verifying this reload.
            let before = (try? probe(timeout: 2)) ?? []
            guard !before.isEmpty else {
                throw NativeAerialSwitcherError.rendererVerificationFailed("fresh native loading predecessor unavailable")
            }
            // Any post-write error must reach safe rollback, including chmod or
            // journal IO errors. A write serial identifies the replacement even
            // if preserving freshly added Spaces changes the final bytes.
            let beforeWriteSerial = ownedWriteSerial
            do { try writeOwned(candidate.data) }
            catch { wroteThisOperation = ownedWriteSerial != beforeWriteSerial; throw error }
            wroteThisOperation = true
            currentAssetID = assetID
            try reloadAgent()
            let movies = poll(expectedAssetID: assetID, timeout: 8) {
                Self.restorationTransition(before: before, after: $0, baselineIDs: [assetID],
                    knownIDs: [assetID], fixedBaselineID: assetID)
            }
            recentMovies = movies
            _ = try await validatedCurrentData()
            let verified = Self.restorationTransition(before: before, after: movies, baselineIDs: [assetID],
                knownIDs: [assetID], fixedBaselineID: assetID)
            try saveJournal(status: verified ? "selected" : "selection-unverified")
            guard verified else { throw NativeAerialSwitcherError.rendererVerificationFailed(assetID) }
            lastMessage = "Native provider opened the selected Aerial"
            let actualCount = try Self.validateSchema(Self.decodedTree(expectedData!), displayUUID: displayUUID!).ids.count
            return NativeAerialSwitchResult(assetID: assetID, switchedAt: Date(), changedChoices: actualCount,
                nativeProviderVerified: true, movies: movies, backupPath: backupURL!.path)
        } catch {
            let originalError = error
            var rollbackMessage = ""
            if wroteThisOperation, let previousSelection {
                do {
                    _ = try await validatedCurrentData()
                    let previous = try freshCandidate(assetID: previousSelection)
                    try writeOwned(previous.data)
                    currentAssetID = previousSelection
                    try reloadAgent()
                    let known = try currentManifest().assets.compactMap { $0["id"] as? String }
                    let fixed = known.contains(previousSelection) ? previousSelection : nil
                    recentMovies = poll(expectedAssetID: fixed, timeout: 8) { rows in
                        fixed.map { id in rows.contains { $0.assetID == id } } ?? !rows.isEmpty
                    }
                    _ = try await validatedCurrentData()
                    try saveJournal(status: "switch-failed-previous-selection-restored")
                    rollbackMessage = "; previous settings restored safely; native loading remains diagnostic only"
                } catch {
                    rollbackMessage = "; rollback was skipped or could not be verified: \(error)"
                    try? saveJournal(status: "switch-failed-rollback-incomplete")
                }
            }
            lastMessage = String(describing: originalError) + rollbackMessage
            throw originalError
        }
    }

    public func restore() async throws -> NativeAerialRestoreResult {
        try beginOperation(); defer { operating = false }
        do {
            try loadRecoveryIfNeeded()
            guard mutated, let baselineData, let baselineSelection else {
                return NativeAerialRestoreResult(restoredAt: Date(), status: "unchanged-no-owned-write",
                    restorationAttempted: false, selectionRestored: true, nativeProviderVerified: false,
                    baselineMovieReopened: false, byteExact: true, mismatchPaths: [], addedSettingPaths: [], movies: [])
            }
            do { _ = try await validatedCurrentData() }
            catch {
                if !conflictPaths.isEmpty {
                    lastMessage = "Restore skipped because another selection or setting is now active"
                    try? saveJournal(status: "restore-skipped-external-change")
                    return skippedRestore()
                }
                throw error
            }
            // This must be a fresh predecessor; old samples can contain stale
            // PIDs after sleep or unlock and cannot prove a reload transition.
            let before = (try? probe(timeout: 2)) ?? []
            let manifest = try currentManifest()
            let knownIDs = Set(manifest.assets.compactMap { $0["id"] as? String })
            let fixedBaseline = knownIDs.contains(baselineSelection) ? baselineSelection : nil
            let baselineIDs = Set(baselineMovies.map(\.assetID))
            let candidate: (data: Data, count: Int)
            do { candidate = try freshCandidate(assetID: baselineSelection) }
            catch {
                if !conflictPaths.isEmpty { try? saveJournal(status: "restore-skipped-external-change"); return skippedRestore() }
                throw error
            }
            try writeOwned(candidate.data)
            currentAssetID = baselineSelection
            try reloadAgent()
            let movies = poll(expectedAssetID: fixedBaseline, timeout: 8) {
                Self.restorationTransition(before: before, after: $0, baselineIDs: baselineIDs,
                    knownIDs: knownIDs, fixedBaselineID: fixedBaseline)
            }
            recentMovies = movies
            let finalBytes = try Data(contentsOf: store)
            let original = try Self.decodedTree(baselineData), final = try Self.decodedTree(finalBytes)
            _ = try Self.validateSchema(final, displayUUID: displayUUID!)
            let ownershipConflicts = try Self.configurationConflictPaths(expected: Self.decodedTree(candidate.data), current: final)
            if !ownershipConflicts.isEmpty { conflictPaths = ownershipConflicts }
            let mismatches = try Self.originalSettingMismatchPaths(original, final) + ownershipConflicts
            let nativeVerified = Self.restorationTransition(before: before, after: movies, baselineIDs: baselineIDs,
                knownIDs: knownIDs, fixedBaselineID: fixedBaseline)
            let reopened = Self.restorationTransition(before: before, after: movies, baselineIDs: baselineIDs,
                knownIDs: baselineIDs, fixedBaselineID: nil)
            let result = NativeAerialRestoreResult(restoredAt: Date(), status: mismatches.isEmpty ?
                (nativeVerified ? "restored" : "settings-restored-native-unverified") : "restore-check-failed",
                restorationAttempted: true, selectionRestored: mismatches.isEmpty,
                nativeProviderVerified: nativeVerified, baselineMovieReopened: reopened,
                byteExact: finalBytes == baselineData, mismatchPaths: mismatches,
                addedSettingPaths: Self.addedPaths(original, final).map(Self.pathString), movies: movies)
            try save(result, name: "restore-result.json")
            guard mismatches.isEmpty else { throw NativeAerialSwitcherError.rendererVerificationFailed("restored settings mismatch") }
            // Semantic restore completes ownership even if fresh renderer proof
            // is inconclusive; do not repeatedly reload just to collect proof.
            mutated = false
            try saveJournal(status: result.status)
            try? FileManager.default.removeItem(at: supportDirectory.appendingPathComponent("active-wallpaper-session.json"))
            self.baselineSelection = nil; self.baselineData = nil; expectedData = nil; baselineMode = nil
            expectedSnapshotName = "Index.expected.plist"; pendingSnapshotName = nil; pendingSnapshotSHA256 = nil
            baselineMovies = []; backupURL = nil; sessionDirectory = nil
            lastMessage = nativeVerified ? "Original wallpaper settings restored" : "Original settings restored; native loading was not verified"
            return result
        } catch { lastMessage = String(describing: error); throw error }
    }

    private func beginOperation() throws {
        guard !operating else { throw NativeAerialSwitcherError.busy }
        operating = true
    }
    private func diagnosticsAfterOperation() -> NativeAerialSwitcherDiagnostics {
        let d = diagnostics()
        return NativeAerialSwitcherDiagnostics(isPrepared: d.isPrepared, isOperating: false, displayUUID: d.displayUUID,
            currentAssetID: d.currentAssetID, baselineAssetID: d.baselineAssetID, hasOwnedChanges: d.hasOwnedChanges,
            canRestore: mutated && conflictPaths.isEmpty, externalChangeDetected: d.externalChangeDetected,
            conflictPaths: d.conflictPaths, backupPath: d.backupPath, lastMessage: d.lastMessage, nativeMovieIDs: d.nativeMovieIDs)
    }
    private func skippedRestore() -> NativeAerialRestoreResult {
        NativeAerialRestoreResult(restoredAt: Date(), status: "skipped-external-change", restorationAttempted: false,
            selectionRestored: false, nativeProviderVerified: false, baselineMovieReopened: false,
            byteExact: false, mismatchPaths: conflictPaths, addedSettingPaths: [], movies: [])
    }

    private func validatedCurrentData() async throws -> Data {
        guard conflictPaths.isEmpty else { throw NativeAerialSwitcherError.concurrentSettingsChange(conflictPaths) }
        do {
            let uuid = try await MainActor.run { try Self.singleBuiltinDisplayUUID() }
            if let previous = displayUUID, previous != uuid { throw NativeAerialSwitcherError.unsupportedScope("display identity changed") }
            try validateOwnedStore()
            let bytes = try Data(contentsOf: store)
            let tree = try Self.decodedTree(bytes)
            let schema = try Self.validateSchema(tree, displayUUID: uuid)
            if let expectedData {
                let conflicts = try Self.configurationConflictPaths(expected: Self.decodedTree(expectedData), current: tree)
                guard conflicts.isEmpty else { throw NativeAerialSwitcherError.concurrentSettingsChange(conflicts) }
            }
            displayUUID = uuid; currentAssetID = schema.selection
            return bytes
        } catch {
            if expectedData != nil {
                if case NativeAerialSwitcherError.concurrentSettingsChange(let paths) = error { conflictPaths = paths }
                else { conflictPaths = ["configuration/display validation: \(error)"] }
                throw NativeAerialSwitcherError.concurrentSettingsChange(conflictPaths)
            }
            throw error
        }
    }
    private func freshCandidate(assetID: String) throws -> (data: Data, count: Int) {
        do {
            try validateOwnedStore()
            let bytes = try Data(contentsOf: store), tree = try Self.decodedTree(bytes)
            _ = try Self.validateSchema(tree, displayUUID: displayUUID!)
            guard let expectedData else { throw NativeAerialSwitcherError.unsupportedScope("missing session ownership") }
            let conflicts = try Self.configurationConflictPaths(expected: Self.decodedTree(expectedData), current: tree)
            if !conflicts.isEmpty { throw NativeAerialSwitcherError.concurrentSettingsChange(conflicts) }
            // Apple exposes no public CAS for this private file. The final interval
            // between this read and atomic replacement remains a TOCTOU limitation.
            return try Self.replacingAssetID(bytes, assetID: assetID)
        } catch {
            if case NativeAerialSwitcherError.concurrentSettingsChange(let paths) = error { conflictPaths = paths }
            else { conflictPaths = ["configuration validation before write: \(error)"] }
            throw NativeAerialSwitcherError.concurrentSettingsChange(conflictPaths)
        }
    }
    private func validateOwnedStore() throws {
        try Self.requireCanonicalPath(store)
        let a = try FileManager.default.attributesOfItem(atPath: store.path)
        guard a[.type] as? FileAttributeType == .typeRegular,
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = a[.size] as? NSNumber, size.uint64Value <= 4_000_000 else {
            if expectedData != nil { conflictPaths = ["store ownership/type changed"] }
            throw NativeAerialSwitcherError.unsupportedScope("wallpaper Store must be an owned regular file")
        }
    }
    struct Manifest {
        let assets: [[String: Any]]
        let categoryIDs: Set<String>
        let eligibleCategoryIDs: Set<String>
    }
    private func currentManifest() throws -> Manifest {
        try Self.requireCanonicalPath(aerialRoot)
        let bytes = try Self.readOwnedData(aerialRoot.appendingPathComponent("manifest/entries.json"), maximumBytes: 8_000_000)
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]], let categories = root["categories"] as? [[String: Any]] else {
            throw NativeAerialSwitcherError.unsupportedScope("unknown aerial manifest")
        }
        let keys: Set<String> = ["AerialCategoryLandscapes", "AerialCategoryCities", "AerialCategoryUnderwater", "AerialCategorySpace"]
        let eligible = categories.compactMap { entry -> String? in
            guard let key = entry["localizedNameKey"] as? String, keys.contains(key) else { return nil }
            return entry["id"] as? String
        }
        guard eligible.count == 4, Set(eligible).count == 4 else { throw NativeAerialSwitcherError.unsupportedScope("four main Aerial categories were not uniquely identified") }
        return Manifest(assets: assets, categoryIDs: Set(categories.compactMap { $0["id"] as? String }), eligibleCategoryIDs: Set(eligible))
    }
    // The manifest's includeInShuffle metadata is not a playback capability
    // check. A custom pool need not copy that selection preference.
    static func validateLocalAsset(_ id: String, manifest: Manifest, aerialRoot: URL) throws {
        guard UUID(uuidString: id) != nil,
              let asset = manifest.assets.first(where: { $0["id"] as? String == id }),
              let categories = asset["categories"] as? [String], !Set(categories).isDisjoint(with: manifest.eligibleCategoryIDs) else {
            throw NativeAerialSwitcherError.invalidAsset(id)
        }
        let url = aerialRoot.appendingPathComponent("videos/\(id).mov")
        try Self.requireCanonicalPath(url)
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular, let size = a[.size] as? NSNumber, size.uint64Value > 0 else {
            throw NativeAerialSwitcherError.invalidAsset(id)
        }
    }
    private func captureBaseline(_ bytes: Data, manifest: Manifest) throws {
        let schema = try Self.validateSchema(Self.decodedTree(bytes), displayUUID: displayUUID!)
        let knownSelections = Set(manifest.assets.compactMap { $0["id"] as? String }).union(manifest.categoryIDs).union(["shuffle-all-aerials"])
        guard knownSelections.contains(schema.selection) else { throw NativeAerialSwitcherError.unsupportedScope("unrecognized baseline selection") }
        let support = try validatedSupportDirectory()
        let fm = FileManager.default
        let before = (try? probe(timeout: 2)) ?? []
        let mode = try fm.attributesOfItem(atPath: store.path)[.posixPermissions] as? NSNumber
        guard let mode else { throw NativeAerialSwitcherError.unsupportedScope("Store permissions unavailable") }
        let session = support.appendingPathComponent("WallpaperBackups/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: session.path)
        let backup = session.appendingPathComponent("Index.baseline.plist")
        try Self.persistData(bytes, to: backup)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        baselineData = bytes; expectedData = bytes; baselineSelection = schema.selection; baselineMode = mode
        expectedSnapshotName = "Index.expected.plist"; pendingSnapshotName = nil; pendingSnapshotSHA256 = nil
        baselineMovies = before; backupURL = backup; sessionDirectory = session
        recoveryLoaded = true
        do {
            try Self.persistData(bytes, to: session.appendingPathComponent("Index.expected.plist"))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: session.appendingPathComponent("Index.expected.plist").path)
            try saveJournal(status: "baseline-captured-no-live-write")
            try saveActivePointer(session: session.lastPathComponent)
        } catch {
            // An incomplete baseline must never enable a later live write.
            baselineData = nil; expectedData = nil; baselineSelection = nil; baselineMode = nil
            baselineMovies = []; backupURL = nil; sessionDirectory = nil
            throw error
        }
    }
    private func writeOwned(_ bytes: Data) throws {
        try validateOwnedStore()
        guard let sessionDirectory, let expectedData else { throw NativeAerialSwitcherError.unsupportedScope("missing durable baseline session") }
        let pointer = try JSONDecoder().decode(ActivePointer.self, from: Self.readOwnedData(supportDirectory.appendingPathComponent("active-wallpaper-session.json"), maximumBytes: 16_384))
        guard pointer.version == 1, pointer.session == sessionDirectory.lastPathComponent else { throw NativeAerialSwitcherError.unsupportedScope("active backup pointer changed") }
        let target = try Self.validateSchema(Self.decodedTree(bytes), displayUUID: displayUUID!).selection
        var candidate = bytes
        var stable = false
        for _ in 0..<3 {
            let latest = try Data(contentsOf: store)
            let conflicts = try Self.configurationConflictPaths(expected: Self.decodedTree(expectedData), current: Self.decodedTree(latest))
            guard conflicts.isEmpty else { conflictPaths = conflicts; throw NativeAerialSwitcherError.concurrentSettingsChange(conflicts) }
            candidate = try Self.replacingAssetID(latest, assetID: target).data
            let name = "Index.expected.\(UUID().uuidString).plist"
            let snapshot = sessionDirectory.appendingPathComponent(name)
            try Self.persistData(candidate, to: snapshot)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
            pendingSnapshotName = name; pendingSnapshotSHA256 = Self.hash(candidate)
            // Pending metadata reaches local storage BEFORE live replacement.
            // Recovery compares current settings against both immutable files.
            try saveJournal(status: "write-pending")
            if try Data(contentsOf: store) == latest { stable = true; break }
        }
        guard stable else { throw NativeAerialSwitcherError.unsupportedScope("wallpaper Store kept changing during preparation; no write performed") }
        try validateOwnedStore()
        try candidate.write(to: store, options: .atomic)
        // Arm restore immediately after replacement, before chmod can fail.
        mutated = true; ownedWriteSerial += 1; self.expectedData = candidate
        expectedSnapshotName = pendingSnapshotName!; pendingSnapshotName = nil; pendingSnapshotSHA256 = nil
        try Self.synchronizeFile(store)
        if let baselineMode { try FileManager.default.setAttributes([.posixPermissions: baselineMode], ofItemAtPath: store.path) }
        try saveJournal(status: "owned-write")
    }
    private func reloadAgent() throws {
        let output = try Self.command("/bin/launchctl", ["print", "gui/\(getuid())/com.apple.wallpaper.agent"], timeout: 2)
        guard let line = output.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }),
              let value = line.split(separator: "=").last,
              let pid = Int32(value.trimmingCharacters(in: .whitespaces)), pid > 1 else {
            throw NativeAerialSwitcherError.unsafeProcess("PID unavailable")
        }
        guard try Self.processMatches(pid: pid, path: Self.agentPath, timeout: 2) else {
            throw NativeAerialSwitcherError.unsafeProcess("UID or exact executable mismatch")
        }
        guard Darwin.kill(pid, SIGTERM) == 0 else { throw NativeAerialSwitcherError.unsafeProcess("SIGTERM errno \(errno)") }
    }
    nonisolated static func processMatches(pid: Int32, path: String, timeout: TimeInterval) throws -> Bool {
        let ps = try command("/bin/ps", ["-ww", "-p", String(pid), "-o", "uid=,comm="], timeout: timeout)
        let fields = ps.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        return fields.count == 2 && UInt32(fields[0]) == getuid() && String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines) == path
    }
    private func probe(timeout: TimeInterval) throws -> [NativeAerialMovie] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let output = try Self.command("/usr/sbin/lsof", ["-nP", "-c", "WallpaperAerialsExtension", "-F", "pcnft"], timeout: timeout, acceptedExitCodes: [0, 1])
        let rows = Self.parseMovies(output, aerialRoot: aerialRoot)
        var trustedPIDs: Set<String> = []
        for id in Set(rows.map(\.pid)) {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0.1 else { break }
            if let pid = Int32(id), try Self.processMatches(pid: pid, path: Self.extensionPath, timeout: min(1, remaining)) { trustedPIDs.insert(id) }
        }
        return rows.filter { trustedPIDs.contains($0.pid) }
    }
    nonisolated static func parseMovies(_ output: String, aerialRoot: URL) -> [NativeAerialMovie] {
        var pid = "", commandName = "", descriptor = "", result: [NativeAerialMovie] = []
        let videos = aerialRoot.appendingPathComponent("videos").standardizedFileURL.path
        for line in output.split(separator: "\n") {
            guard let code = line.first else { continue }
            let value = String(line.dropFirst())
            switch code {
            case "p": pid = value; commandName = ""; descriptor = ""
            case "c": commandName = value
            case "f": descriptor = value
            case "n":
                let url = URL(fileURLWithPath: value).standardizedFileURL
                let id = url.deletingPathExtension().lastPathComponent
                guard commandName == "WallpaperAerialsExtension", Int32(pid) != nil, UUID(uuidString: id) != nil,
                      url.deletingLastPathComponent().path == videos, url.pathExtension.lowercased() == "mov" else { continue }
                result.append(NativeAerialMovie(pid: pid, fileDescriptor: descriptor, path: url.path, assetID: id))
            default: break
            }
        }
        return result
    }
    private func poll(expectedAssetID: String?, timeout: TimeInterval, accepts: ([NativeAerialMovie]) -> Bool) -> [NativeAerialMovie] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var latest: [NativeAerialMovie] = []
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0.45 else { break }
            if let movies = try? probe(timeout: min(2, remaining - 0.45)) {
                latest = movies
                if accepts(movies) { return movies }
            }
            Thread.sleep(forTimeInterval: min(0.4, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        }
        return latest
    }
    nonisolated static func restorationTransition(before: [NativeAerialMovie], after: [NativeAerialMovie],
        baselineIDs: Set<String>, knownIDs: Set<String>, fixedBaselineID: String?) -> Bool {
        guard !before.isEmpty else { return false }
        let pids = Set(before.map(\.pid)), ids = Set(before.map(\.assetID))
        return after.contains { movie in
            let allowed = fixedBaselineID.map { $0 == movie.assetID } ?? knownIDs.contains(movie.assetID)
            return allowed && (!pids.contains(movie.pid) || (baselineIDs.contains(movie.assetID) && !ids.contains(movie.assetID)))
        }
    }
    @MainActor private static func singleBuiltinDisplayUUID() throws -> String {
        guard NSScreen.screens.count == 1,
              let screen = NSScreen.screens.first,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              CGDisplayIsBuiltin(number.uint32Value) != 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value) else {
            throw NativeAerialSwitcherError.unsupportedScope("V0.1 requires exactly one built-in display")
        }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
    private struct Journal: Codable {
        let version: Int
        let ownerUID: UInt32
        let capturedAt: Date
        let status: String
        let baselineAssetID: String?
        let currentAssetID: String?
        let expectedSHA256: String?
        let expectedSnapshotName: String
        let pendingSnapshotName: String?
        let pendingSHA256: String?
        let baselineSHA256: String?
        let baselinePermissions: UInt16?
        let displayUUID: String?
        let baselineMovies: [NativeAerialMovie]
        let hasOwnedChanges: Bool
        let backupPath: String?
        let conflictPaths: [String]
        let limitation: String
    }
    private func saveJournal(status: String) throws {
        try save(Journal(version: 1, ownerUID: getuid(), capturedAt: Date(), status: status, baselineAssetID: baselineSelection,
            currentAssetID: currentAssetID, expectedSHA256: expectedData.map(Self.hash), expectedSnapshotName: expectedSnapshotName,
            pendingSnapshotName: pendingSnapshotName, pendingSHA256: pendingSnapshotSHA256, baselineSHA256: baselineData.map(Self.hash),
            baselinePermissions: baselineMode?.uint16Value, displayUUID: displayUUID, baselineMovies: baselineMovies, hasOwnedChanges: mutated,
            backupPath: backupURL?.path, conflictPaths: conflictPaths,
            limitation: "Private per-user Store; no public CAS. Movie-open evidence is not visual animation proof. Local recovery is read-only on prepare; restoration requires an explicit UI action and matching owned settings."), name: "session.json")
    }
    private struct ActivePointer: Codable { let version: Int; let session: String }
    private func saveActivePointer(session: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = supportDirectory.appendingPathComponent("active-wallpaper-session.json")
        try Self.persistData(encoder.encode(ActivePointer(version: 1, session: session)), to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func loadRecoveryIfNeeded() throws {
        guard !recoveryLoaded else { return }
        let pointerURL = supportDirectory.appendingPathComponent("active-wallpaper-session.json")
        guard FileManager.default.fileExists(atPath: pointerURL.path) else { recoveryLoaded = true; return }
        _ = try validatedSupportDirectory()
        let pointer = try JSONDecoder().decode(ActivePointer.self, from: Self.readOwnedData(pointerURL, maximumBytes: 16_384))
        guard pointer.version == 1, UUID(uuidString: pointer.session) != nil else {
            throw NativeAerialSwitcherError.unsupportedScope("invalid local recovery pointer")
        }
        let session = supportDirectory.appendingPathComponent("WallpaperBackups/\(pointer.session)")
        try Self.requireCanonicalPath(session)
        try Self.requireOwnedDirectory(session)
        let parent = supportDirectory.appendingPathComponent("WallpaperBackups").path
        guard session.resolvingSymlinksInPath().deletingLastPathComponent().path == parent else {
            throw NativeAerialSwitcherError.unsupportedScope("recovery session escapes application storage")
        }
        let journal = try JSONDecoder().decode(Journal.self, from: Self.readOwnedData(session.appendingPathComponent("session.json"), maximumBytes: 128_000))
        guard journal.version == 1, journal.ownerUID == getuid() else {
            throw NativeAerialSwitcherError.unsupportedScope("unsupported or foreign recovery journal")
        }
        // A successfully completed explicit restore is an inactive session;
        // pending writes are always reconciled, regardless of the owned flag.
        if !journal.hasOwnedChanges, journal.pendingSnapshotName == nil,
           ["restored", "settings-restored-native-unverified", "ownership-relinquished-current-settings-adopted"].contains(journal.status) {
            recoveryLoaded = true; return
        }
        conflictPaths = journal.conflictPaths
        guard Self.validSnapshotName(journal.expectedSnapshotName),
              journal.pendingSnapshotName.map(Self.validSnapshotName) ?? true else {
            throw NativeAerialSwitcherError.unsupportedScope("invalid recovery snapshot filename")
        }
        let backup = session.appendingPathComponent("Index.baseline.plist"), expected = session.appendingPathComponent(journal.expectedSnapshotName)
        let old = try Self.readOwnedData(backup, maximumBytes: 4_000_000), owned = try Self.readOwnedData(expected, maximumBytes: 4_000_000)
        guard Self.hash(old) == journal.baselineSHA256, Self.hash(owned) == journal.expectedSHA256,
              let uuid = journal.displayUUID, let mode = journal.baselinePermissions,
              let id = journal.baselineAssetID,
              try Self.validateSchema(Self.decodedTree(old), displayUUID: uuid).selection == id else {
            throw NativeAerialSwitcherError.unsupportedScope("recovery metadata or file hash mismatch")
        }
        _ = try Self.validateSchema(Self.decodedTree(owned), displayUUID: uuid)
        var recovered = owned
        var recoveredName = journal.expectedSnapshotName
        var recoveredOwned = journal.hasOwnedChanges
        if let pending = journal.pendingSnapshotName {
            let pendingData = try Self.readOwnedData(session.appendingPathComponent(pending), maximumBytes: 4_000_000)
            guard Self.hash(pendingData) == journal.pendingSHA256 else { throw NativeAerialSwitcherError.unsupportedScope("pending snapshot hash mismatch") }
            _ = try Self.validateSchema(Self.decodedTree(pendingData), displayUUID: uuid)
            try validateOwnedStore()
            let live = try Self.decodedTree(Data(contentsOf: store))
            let decision = try Self.recoveryOwnership(current: live, previous: Self.decodedTree(owned), pending: Self.decodedTree(pendingData))
            switch decision {
            case .pending: recovered = pendingData; recoveredName = pending; recoveredOwned = true
            case .previous: break
            case .conflict: conflictPaths.append("live settings match neither previous nor pending app snapshot")
            }
        }
        baselineData = old; expectedData = recovered; expectedSnapshotName = recoveredName; baselineSelection = id; baselineMode = NSNumber(value: mode)
        displayUUID = uuid; currentAssetID = journal.currentAssetID; baselineMovies = journal.baselineMovies
        backupURL = backup; sessionDirectory = session; mutated = recoveredOwned; recoveryLoaded = true
        // validatedCurrentData() must still compare the live Store before this
        // cached ownership can enable switching or a successful prepare result.
    }
    nonisolated enum RecoveryOwnership: Equatable { case previous, pending, conflict }
    nonisolated static func recoveryOwnership(current: Any, previous: Any, pending: Any) throws -> RecoveryOwnership {
        // Prefer previous when both are semantically equal (e.g. an explicit
        // no-op selection); pending alone proves that replacement took place.
        if try configurationConflictPaths(expected: previous, current: current).isEmpty { return .previous }
        if try configurationConflictPaths(expected: pending, current: current).isEmpty { return .pending }
        return .conflict
    }
    nonisolated static func validSnapshotName(_ name: String) -> Bool {
        if name == "Index.expected.plist" { return true }
        guard name.hasPrefix("Index.expected."), name.hasSuffix(".plist") else { return false }
        return UUID(uuidString: String(name.dropFirst("Index.expected.".count).dropLast(".plist".count))) != nil
    }
    private func validatedSupportDirectory() throws -> URL {
        let support = supportDirectory.standardizedFileURL
        try Self.requireCanonicalPath(support)
        guard support.path != "/", !support.path.hasPrefix(store.deletingLastPathComponent().path),
              !support.path.hasPrefix(aerialRoot.path), !support.path.hasPrefix("/System/") else {
            throw NativeAerialSwitcherError.unsupportedScope("backup directory must be application-owned storage")
        }
        if FileManager.default.fileExists(atPath: support.path) {
            try Self.requireOwnedDirectory(support)
            let backups = support.appendingPathComponent("WallpaperBackups")
            if FileManager.default.fileExists(atPath: backups.path) { try Self.requireOwnedDirectory(backups) }
        }
        return support
    }
    nonisolated static func requireCanonicalPath(_ url: URL) throws {
        guard url.standardizedFileURL.path == url.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw NativeAerialSwitcherError.unsupportedScope("symbolic links in a wallpaper or recovery path are unsupported")
        }
    }
    nonisolated static func requireOwnedDirectory(_ url: URL) throws {
        try requireCanonicalPath(url)
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeDirectory,
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw NativeAerialSwitcherError.unsupportedScope("recovery directories must be owned by this user")
        }
    }
    nonisolated static func readOwnedData(_ url: URL, maximumBytes: UInt64) throws -> Data {
        try requireCanonicalPath(url)
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular,
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = a[.size] as? NSNumber, size.uint64Value <= maximumBytes else {
            throw NativeAerialSwitcherError.unsupportedScope("metadata must be an owned regular file within the size limit")
        }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= maximumBytes else { throw NativeAerialSwitcherError.unsupportedScope("metadata grew beyond size limit") }
        return bytes
    }
    nonisolated private static func synchronizeFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    nonisolated private static func persistData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try synchronizeFile(url)
    }
    private func save<T: Encodable>(_ value: T, name: String) throws {
        guard let sessionDirectory else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = sessionDirectory.appendingPathComponent(name)
        try Self.persistData(encoder.encode(value), to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    nonisolated private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    nonisolated static func decodedTree(_ data: Data) throws -> Any {
        func decode(_ node: Any) throws -> Any {
            if let dict = node as? [String: Any] {
                var result = dict
                for (key, value) in dict {
                    if ["Configuration", "EncodedOptionValues"].contains(key), let data = value as? Data {
                        result[key] = try decode(PropertyListSerialization.propertyList(from: data, options: [], format: nil))
                    } else { result[key] = try decode(value) }
                }
                return result
            }
            if let array = node as? [Any] { return try array.map(decode) }
            return node
        }
        return try decode(PropertyListSerialization.propertyList(from: data, options: [], format: nil))
    }

    nonisolated static func originalSettingMismatchPaths(_ expected: Any, _ current: Any, path: String = "$") throws -> [String] {
        if let old = expected as? [String: Any] {
            guard let new = current as? [String: Any] else { return [path + " (type changed)"] }
            var mismatches: [String] = []
            for key in old.keys.sorted() {
                let child = path + "[\(String(reflecting: key))]"
                guard let value = new[key] else { mismatches.append(child + " (missing)"); continue }
                if key == "LastUse", old[key] is Date, value is Date { continue }
                mismatches += try originalSettingMismatchPaths(old[key]!, value, path: child)
            }
            return mismatches
        }
        if let old = expected as? [Any] {
            guard let new = current as? [Any] else { return [path + " (type changed)"] }
            var mismatches = old.count == new.count ? [] : [path + " (array count changed)"]
            for i in 0..<min(old.count, new.count) { mismatches += try originalSettingMismatchPaths(old[i], new[i], path: path + "[\(i)]") }
            return mismatches
        }
        let a = try PropertyListSerialization.data(fromPropertyList: ["value": expected], format: .binary, options: 0)
        let b = try PropertyListSerialization.data(fromPropertyList: ["value": current], format: .binary, options: 0)
        return a == b ? [] : [path]
    }

    nonisolated static func addedPaths(_ expected: Any, _ current: Any, path: [String] = []) -> [[String]] {
        if let old = expected as? [Any], let new = current as? [Any] {
            return new.indices.flatMap { index -> [[String]] in
                if index >= old.count { return [path + [String(index)]] }
                return addedPaths(old[index], new[index], path: path + [String(index)])
            }
        }
        guard let old = expected as? [String: Any], let new = current as? [String: Any] else { return [] }
        return new.keys.sorted().flatMap { key -> [[String]] in
            guard let before = old[key] else { return [path + [key]] }
            return addedPaths(before, new[key]!, path: path + [key])
        }
    }
    nonisolated static func pathString(_ path: [String]) -> String { "$" + path.map { "[\(String(reflecting: $0))]" }.joined() }

    nonisolated static func configurationConflictPaths(expected: Any, current: Any) throws -> [String] {
        var conflicts = try originalSettingMismatchPaths(expected, current)
        guard let root = current as? [String: Any], let expectedRoot = expected as? [String: Any],
              let originalDefault = expectedRoot["SystemDefault"], let spaces = root["Spaces"] as? [String: Any] else {
            return conflicts + ["root layout changed"]
        }
        for addition in addedPaths(expected, current) {
            guard addition.count == 2, addition[0] == "Spaces", UUID(uuidString: addition[1]) != nil,
                  let space = spaces[addition[1]] as? [String: Any],
                  let displayScopes = space["Displays"] as? [String: Any], let defaultScope = space["Default"] else {
                conflicts.append(pathString(addition) + " (unrecognized added setting)"); continue
            }
            conflicts += try originalSettingMismatchPaths(originalDefault, defaultScope, path: pathString(addition) + "[\"Default\"]")
            // Synthesized scopes must match in BOTH directions: an added
            // option is a settings change, not harmless scope normalization.
            conflicts += try originalSettingMismatchPaths(defaultScope, originalDefault, path: pathString(addition) + "[\"Default\"]")
            for (display, scope) in displayScopes {
                conflicts += try originalSettingMismatchPaths(originalDefault, scope, path: pathString(addition) + "[\"Displays\"][\(String(reflecting: display))]")
                conflicts += try originalSettingMismatchPaths(scope, originalDefault, path: pathString(addition) + "[\"Displays\"][\(String(reflecting: display))]")
            }
        }
        return conflicts
    }

    nonisolated static func validateSchema(_ tree: Any, displayUUID: String) throws -> (selection: String, ids: [String], paths: [String]) {
        guard let root = tree as? [String: Any], Set(root.keys) == Set(["AllSpacesAndDisplays", "SystemDefault", "Spaces", "Displays"]),
              root["AllSpacesAndDisplays"] as? String == "$null", let system = root["SystemDefault"],
              let displays = root["Displays"] as? [String: Any], Set(displays.keys) == Set([displayUUID]),
              let spaces = root["Spaces"] as? [String: Any], !spaces.isEmpty else {
            throw NativeAerialSwitcherError.unsupportedScope("expected known per-Space single-display layout")
        }
        var ids: [String] = [], paths: [String] = []
        func wrapper(_ node: Any, _ path: String) throws {
            guard let scope = node as? [String: Any], Set(scope.keys) == Set(["Type", "Linked"]), scope["Type"] as? String == "linked",
                  let linked = scope["Linked"] as? [String: Any], Set(linked.keys) == Set(["LastSet", "LastUse", "Content"]),
                  linked["LastSet"] is Date, linked["LastUse"] is Date,
                  let content = linked["Content"] as? [String: Any], Set(content.keys) == Set(["Choices", "Shuffle", "EncodedOptionValues"]),
                  content["Shuffle"] as? String == "$null", content["EncodedOptionValues"] is [String: Any],
                  let choices = content["Choices"] as? [[String: Any]], choices.count == 1,
                  Set(choices[0].keys) == Set(["Provider", "Files", "Configuration"]),
                  choices[0]["Provider"] as? String == provider, let files = choices[0]["Files"] as? [Any], files.isEmpty,
                  let config = choices[0]["Configuration"] as? [String: Any], Set(config.keys) == Set(["assetID"]),
                  let id = config["assetID"] as? String else {
                throw NativeAerialSwitcherError.unsupportedScope("unknown/non-linked/mixed choice at \(path)")
            }
            ids.append(id); paths.append(path + "[\"Linked\"][\"Content\"][\"Choices\"][0]")
        }
        try wrapper(system, "$[\"SystemDefault\"]")
        try wrapper(displays[displayUUID]!, "$[\"Displays\"][\(String(reflecting: displayUUID))]")
        for key in spaces.keys.sorted() {
            guard key.isEmpty || UUID(uuidString: key) != nil,
                  let space = spaces[key] as? [String: Any], Set(space.keys) == Set(["Default", "Displays"]),
                  let defaults = space["Default"], let localDisplays = space["Displays"] as? [String: Any],
                  Set(localDisplays.keys) == Set([displayUUID]) else { throw NativeAerialSwitcherError.unsupportedScope("unknown Space shape") }
            try wrapper(defaults, "$[\"Spaces\"][\(String(reflecting: key))][\"Default\"]")
            try wrapper(localDisplays[displayUUID]!, "$[\"Spaces\"][\(String(reflecting: key))][\"Displays\"][\(String(reflecting: displayUUID))]")
        }
        guard Set(ids).count == 1, let id = ids.first else { throw NativeAerialSwitcherError.unsupportedScope("different selections across scopes") }
        return (id, ids.sorted(), paths.sorted())
    }

    nonisolated static func replacingAssetID(_ data: Data, assetID: String) throws -> (data: Data, count: Int) {
        var count = 0
        func rewrite(_ node: Any, linked: Bool = false) throws -> Any {
            if var dict = node as? [String: Any] {
                if linked, dict["Provider"] as? String == provider, let blob = dict["Configuration"] as? Data,
                   var config = try PropertyListSerialization.propertyList(from: blob, options: [], format: nil) as? [String: Any] {
                    config["assetID"] = assetID
                    dict["Configuration"] = try PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0)
                    count += 1
                }
                for (key, value) in dict { dict[key] = try rewrite(value, linked: linked || key == "Linked") }
                return dict
            }
            if let array = node as? [Any] { return try array.map { try rewrite($0, linked: linked) } }
            return node
        }
        let tree = try rewrite(PropertyListSerialization.propertyList(from: data, options: [], format: nil))
        return (try PropertyListSerialization.data(fromPropertyList: tree, format: .binary, options: 0), count)
    }

    nonisolated static func command(_ executable: String, _ args: [String], timeout: TimeInterval, acceptedExitCodes: Set<Int32> = [0]) throws -> String {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardOutput = output; process.standardError = errors
        try process.run()
        defer {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
        }
        func cleanupOwnedDiagnostic() {
            guard process.isRunning else { return }
            process.terminate() // Only the exact child created by this Process.
            var deadline = ProcessInfo.processInfo.systemUptime + 0.18
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL) // Bounded fallback for this owned diagnostic child only.
                deadline = ProcessInfo.processInfo.systemUptime + 0.18
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            if !process.isRunning { process.waitUntilExit() }
        }
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = errors.fileHandleForReading.fileDescriptor
        guard fcntl(outFD, F_SETFL, fcntl(outFD, F_GETFL) | O_NONBLOCK) != -1,
              fcntl(errFD, F_SETFL, fcntl(errFD, F_GETFL) | O_NONBLOCK) != -1 else {
            cleanupOwnedDiagnostic()
            throw NativeAerialSwitcherError.commandFailed("cannot configure diagnostic pipes")
        }
        var stdoutData = Data(), stderrData = Data()
        func drain(_ descriptor: Int32, _ data: inout Data) {
            var buffer = [UInt8](repeating: 0, count: 8192)
            for _ in 0..<64 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
                guard count > 0 else { break } // EOF / EAGAIN: retry next pass.
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            // Drain both streams concurrently with process lifetime so output
            // larger than a pipe buffer cannot deadlock the child at write().
            drain(outFD, &stdoutData); drain(errFD, &stderrData)
            if stdoutData.count + stderrData.count > 8_000_000 {
                cleanupOwnedDiagnostic()
                throw NativeAerialSwitcherError.commandFailed("diagnostic output exceeded limit")
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                cleanupOwnedDiagnostic()
                throw NativeAerialSwitcherError.commandFailed("timeout: \(executable)")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        drain(outFD, &stdoutData); drain(errFD, &stderrData)
        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)
        guard acceptedExitCodes.contains(process.terminationStatus) else { throw NativeAerialSwitcherError.commandFailed("\(executable): \(stderr)") }
        return stdout
    }
}
