import AppKit
import CryptoKit
import Foundation
import Darwin

private struct StartupCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
private struct StartupCase: Codable {
    let name: String
    let passed: Bool
    let isAutomatic: Bool
    let isSwitching: Bool
    let schedulerStatus: String
    let environmentReady: Bool
    let canRestore: Bool
    let poolCount: Int
    let nextDueSecondsFromObservation: Double?
    let savedRotationRequested: Bool?
    let errorMessage: String?
    let message: String
}
private struct StartupSummary: Codable {
    let passed: Bool
    let elapsedSeconds: Double
    let cases: [StartupCase]
    let errors: [String]
    let storeSHA256Before: String?
    let storeSHA256After: String?
    let storeBytesUnchanged: Bool
    let limitation: String
}

@MainActor
private final class StartupChecks: NSObject, NSApplicationDelegate {
    let directory: URL
    let started = ProcessInfo.processInfo.systemUptime
    let store = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    var before: Data?
    var fixtureData: Data?
    var displayUUID: String?
    var baselineSelection: String?
    var baselinePermissions: UInt16 = 0
    var models: [AppModel] = []
    var cases: [StartupCase] = []
    var errors: [String] = []
    var watchdog: Timer?
    var finished = false

    init(directory: URL) { self.directory = directory }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let timer = Timer(timeInterval: 29, target: self, selector: #selector(hardDeadline), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common); watchdog = timer
        Task { await run() }
    }
    func require(_ value: Bool, _ message: String) throws {
        guard value else { throw StartupCheckFailure(message) }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func fixture(_ name: String, requested: Bool? = false, categories: [String] = ["landscape", "underwater"], owned: Bool = false, corruptJournal: Bool = false, mismatchedExpected: Bool = false) throws -> URL {
        let result = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let requested {
            try PreferenceStore(directory: result).save(ControllerPreferences(selectedCategoryKeys: categories, intervalMinutes: 15, rotationRequested: requested))
        } else {
            try writeJSON(["version": 1, "selectedCategoryKeys": categories, "intervalMinutes": 15], to: result.appendingPathComponent("preferences.json"))
        }
        if owned {
            guard let fixtureData, let displayUUID, let baselineSelection else { throw StartupCheckFailure("Missing initial read-only fixture metadata") }
            let root = result.appendingPathComponent("wallpaper-backups")
            let id = UUID().uuidString
            let session = root.appendingPathComponent("WallpaperBackups/\(id)")
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let expected = mismatchedExpected ? try NativeAerialSwitcher.replacingAssetID(fixtureData, assetID: "00000000-0000-0000-0000-000000009999").data : fixtureData
            let backup = session.appendingPathComponent("Index.baseline.plist")
            for (url, bytes) in [(backup, fixtureData), (session.appendingPathComponent("Index.expected.plist"), expected)] {
                try bytes.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            try writeJSON(["version": 1, "session": id], to: root.appendingPathComponent("active-wallpaper-session.json"))
            let journal: [String: Any] = [
                "version": 1, "ownerUID": getuid(), "capturedAt": Date().timeIntervalSinceReferenceDate,
                "status": "selected", "baselineAssetID": baselineSelection,
                "currentAssetID": mismatchedExpected ? "00000000-0000-0000-0000-000000009999" : baselineSelection,
                "expectedSHA256": Self.hash(expected), "expectedSnapshotName": "Index.expected.plist",
                "baselineSHA256": Self.hash(fixtureData), "baselinePermissions": baselinePermissions,
                "displayUUID": displayUUID, "baselineMovies": [], "hasOwnedChanges": true,
                "backupPath": backup.path, "conflictPaths": [],
                "limitation": "SYNTHETIC TEST FIXTURE: current live bytes were copied as baseline/expected. This tests startup decisions, not actual ownership acquisition or wallpaper switching."
            ]
            if corruptJournal { try Data("{broken journal}".utf8).write(to: session.appendingPathComponent("session.json")) }
            else { try writeJSON(journal, to: session.appendingPathComponent("session.json")) }
        }
        return result
    }
    func makeModel(_ support: URL) -> AppModel {
        let result = AppModel(supportDirectory: support)
        models.append(result)
        return result
    }
    func settled(_ model: AppModel) async throws {
        let began = ProcessInfo.processInfo.systemUptime
        // Its actual init owns the refresh task; the race-specific case also
        // calls the read-only refresh. Never call an action that selects wallpaper.
        repeat {
            try await Task.sleep(for: .milliseconds(20))
            if !model.isLoading && (model.catalog != nil || model.errorMessage != nil), ProcessInfo.processInfo.systemUptime - began >= 0.12 { break }
            try require(ProcessInfo.processInfo.systemUptime - began < 5, "Initialization did not settle within five seconds")
        } while true
        try await Task.sleep(for: .milliseconds(40))
        try require(!model.isLoading && !model.isSwitching, "Startup started an unexpected wallpaper operation")
        let replay = model.desktopReplay.diagnostics
        try require(replay.state == "idle" && !replay.windowVisible && !replay.playerAttached
                    && !model.isReplaying && !model.hasReplayFrame,
                    "Startup unexpectedly created a replay window/player")
    }
    func savedIntent(_ support: URL) -> Bool? { try? PreferenceStore(directory: support).load().rotationRequested }
    func record(_ name: String, _ model: AppModel, _ support: URL) {
        let entry = StartupCase(name: name, passed: true, isAutomatic: model.isAutomatic, isSwitching: model.isSwitching,
            schedulerStatus: model.scheduler.status.rawValue, environmentReady: model.environmentReady,
            canRestore: model.canRestore, poolCount: model.playlist.count,
            nextDueSecondsFromObservation: model.nextDue?.timeIntervalSinceNow,
            savedRotationRequested: savedIntent(support), errorMessage: model.errorMessage, message: model.message)
        cases.append(entry); print("PASS \(name)")
        fflush(stdout)
    }
    func paused(_ model: AppModel) throws {
        try require(!model.isAutomatic && !model.isSwitching && model.nextDue == nil && model.scheduler.status == .paused, "Expected paused runtime with no due date")
    }
    func resumed(_ model: AppModel) throws {
        let remaining = model.nextDue?.timeIntervalSinceNow ?? -1
        try require(model.environmentReady && model.isAutomatic && !model.isSwitching && model.scheduler.status == .running && remaining > 895 && remaining <= 901,
                    "Expected a fresh fifteen-minute countdown and no immediate selection")
    }
    func run() async {
        do {
            before = try Data(contentsOf: store)
            let probe = NativeAerialSwitcher(supportDirectory: directory.appendingPathComponent("readonly-preflight"))
            let diagnostic = try await probe.prepare()
            try require(diagnostic.isPrepared && !diagnostic.externalChangeDetected, "Live read-only native configuration is unsupported")
            fixtureData = try Data(contentsOf: store)
            displayUUID = diagnostic.displayUUID
            baselineSelection = try NativeAerialSwitcher.validateSchema(NativeAerialSwitcher.decodedTree(fixtureData!), displayUUID: displayUUID!).selection
            baselinePermissions = (try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            try require(baselinePermissions > 0, "Could not capture Store permission metadata")

            let fresh = directory.appendingPathComponent("fresh")
            let freshModel = makeModel(fresh); try await settled(freshModel); try paused(freshModel)
            record("fresh launch remains paused", freshModel, fresh); freshModel.stopForTermination()

            let legacy = try fixture("legacy", requested: nil)
            let legacyModel = makeModel(legacy); try await settled(legacyModel); try paused(legacyModel)
            record("legacy preferences remain paused", legacyModel, legacy); legacyModel.stopForTermination()

            let refreshRace = try fixture("concurrent-refresh", requested: true, owned: true)
            let refreshRaceModel = makeModel(refreshRace)
            await refreshRaceModel.refresh()
            try await settled(refreshRaceModel); try resumed(refreshRaceModel)
            try require(savedIntent(refreshRace) == true, "Concurrent refresh consumed the startup intent before preparation completed")
            record("immediate concurrent refresh preserves requested startup", refreshRaceModel, refreshRace)
            refreshRaceModel.stopForTermination()

            let valid = try fixture("valid-owned", requested: true, owned: true)
            let validModel = makeModel(valid); try await settled(validModel); try resumed(validModel)
            try require(savedIntent(valid) == true && validModel.canRestore, "Valid fixture lost its requested intent or read-only recovery eligibility")
            record("requested valid synthetic ownership resumes full interval", validModel, valid)
            validModel.stopForTermination(); try paused(validModel)
            try require(savedIntent(valid) == true, "Termination cleared the saved running intent")
            record("stopForTermination preserves saved true", validModel, valid)
            let restarted = makeModel(valid); try await settled(restarted); try resumed(restarted)
            record("new instance resumes retained intent", restarted, valid)
            restarted.pause(); try paused(restarted); try require(savedIntent(valid) == false, "Explicit pause did not persist false")
            let pausedRestart = makeModel(valid); try await settled(pausedRestart); try paused(pausedRestart)
            record("pause persists false across a new instance", pausedRestart, valid); pausedRestart.stopForTermination()

            let immediatePause = try fixture("immediate-pause", requested: true, owned: true)
            let immediatelyPaused = makeModel(immediatePause); immediatelyPaused.pause()
            try await settled(immediatelyPaused); try paused(immediatelyPaused)
            try require(savedIntent(immediatePause) == false, "Immediate pause did not clear intent")
            record("pause before asynchronous refresh prevents revival", immediatelyPaused, immediatePause); immediatelyPaused.stopForTermination()

            let immediateStop = try fixture("immediate-stop", requested: true, owned: true)
            let immediatelyStopped = makeModel(immediateStop); immediatelyStopped.stopForTermination()
            try await settled(immediatelyStopped); try paused(immediatelyStopped)
            try require(savedIntent(immediateStop) == true, "Immediate termination cleared intent")
            record("termination before asynchronous refresh prevents revival", immediatelyStopped, immediateStop)

            let empty = try fixture("empty-pool", requested: true, categories: [], owned: true)
            let emptyModel = makeModel(empty); try await settled(emptyModel); try paused(emptyModel)
            try require(emptyModel.playlist.isEmpty && savedIntent(empty) == false, "Empty pool retained automatic intent")
            record("empty pool safely pauses and saves false", emptyModel, empty); emptyModel.stopForTermination()

            let missing = try fixture("missing-owner", requested: true)
            let missingModel = makeModel(missing); try await settled(missingModel); try paused(missingModel)
            try require(!missingModel.canRestore && savedIntent(missing) == false, "Missing ownership was automatically adopted")
            record("missing ownership safely pauses and saves false", missingModel, missing); missingModel.stopForTermination()

            let badPreferences = try fixture("bad-preferences", requested: false, owned: true)
            let broken = Data("{broken preferences}".utf8)
            try broken.write(to: badPreferences.appendingPathComponent("preferences.json"), options: .atomic)
            let badPrefModel = makeModel(badPreferences); try await settled(badPrefModel); try paused(badPrefModel)
            try require(badPrefModel.errorMessage != nil && (try Data(contentsOf: badPreferences.appendingPathComponent("preferences.json"))) == broken,
                        "Corrupt preferences were silently overwritten or not reported")
            record("corrupt preferences remain untouched and paused", badPrefModel, badPreferences); badPrefModel.stopForTermination()

            let badJournal = try fixture("bad-journal", requested: true, owned: true, corruptJournal: true)
            let badJournalModel = makeModel(badJournal); try await settled(badJournalModel); try paused(badJournalModel)
            try require(!badJournalModel.environmentReady && badJournalModel.errorMessage != nil && savedIntent(badJournal) == false,
                        "Corrupt journal enabled automatic startup")
            record("corrupt journal safely pauses and saves false", badJournalModel, badJournal); badJournalModel.stopForTermination()

            let mismatch = try fixture("external-selection", requested: true, owned: true, mismatchedExpected: true)
            let mismatchModel = makeModel(mismatch); try await settled(mismatchModel); try paused(mismatchModel)
            try require(mismatchModel.externalChangeDetected && savedIntent(mismatch) == false, "A nonmatching expected selection was accepted")
            record("nonmatching synthetic ownership detects external settings", mismatchModel, mismatch); mismatchModel.stopForTermination()
        } catch { errors.append(String(describing: error)) }
        finish()
    }
    @objc func hardDeadline() {
        errors.append("Thirty-second budget expired; runtime timers stopped. No wallpaper action was authorized.")
        finish()
    }
    func finish() -> Never {
        guard !finished else { Darwin.exit(3) }
        finished = true; watchdog?.invalidate()
        for model in models { model.stopForTermination() }
        let after = try? Data(contentsOf: store)
        let unchanged = before != nil && before == after
        if !unchanged { errors.append("Live Store bytes changed during read-only startup tests; source attribution is not established") }
        let summary = StartupSummary(passed: errors.isEmpty && cases.count == 14 && unchanged,
            elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, cases: cases, errors: errors,
            storeSHA256Before: before.map(Self.hash), storeSHA256After: after.map(Self.hash), storeBytesUnchanged: unchanged,
            limitation: "Production AppModel initialization and AppKit run loop were exercised with synthetic ownership journals built from copied live bytes. This is not actual ownership acquisition, wallpaper switching, visual animation, a macOS login event, or SMAppService registration. Only startup countdowns under thirty seconds were tested; no automatic fifteen-minute deadline was reached.")
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(summary).write(to: directory.appendingPathComponent("summary.json"), options: .atomic)
        } catch { print("Summary write failed: \(error)"); Darwin.exit(4) }
        print("FINAL passed=\(summary.passed) cases=\(cases.count) elapsed=\(summary.elapsedSeconds) StoreBytesUnchanged=\(unchanged)")
        for error in errors { print("ERROR \(error)") }
        fflush(stdout); Darwin.exit(summary.passed ? 0 : 1)
    }
}

@main
private struct StartupChecksMain {
    nonisolated static func main() {
        guard CommandLine.arguments.count == 2 else { print("Usage: startup-checks FRESH_WORKSPACE_DIRECTORY"); Darwin.exit(64) }
        let proposed = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard proposed.path == proposed.resolvingSymlinksInPath().path, proposed.path.hasPrefix(workspace.path + "/"), !FileManager.default.fileExists(atPath: proposed.path) else {
            print("Expected a fresh canonical workspace subdirectory"); Darwin.exit(64)
        }
        do { try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { print("Could not create workspace fixture directory: \(error)"); Darwin.exit(64) }
        // AppKit may fail to deliver didFinishLaunching in a restricted GUI
        // environment. This independent watchdog bounds that startup path too.
        let processWatchdog = DispatchSource.makeTimerSource(queue: .global())
        processWatchdog.schedule(deadline: .now() + 30)
        processWatchdog.setEventHandler {
            print("ERROR startup-checks process exceeded its thirty-second bound")
            fflush(stdout)
            Darwin.exit(124)
        }
        processWatchdog.resume()
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let checks = StartupChecks(directory: proposed)
            app.delegate = checks; app.setActivationPolicy(.prohibited)
            withExtendedLifetime((checks, processWatchdog)) { app.run() }
        }
        Darwin.exit(2)
    }
}
