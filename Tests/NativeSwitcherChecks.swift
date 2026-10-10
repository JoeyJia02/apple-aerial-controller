import Foundation

private enum NativeSwitcherCheckFailure: Error {
    case failed(String)
}
private func assertCheck(_ condition: Bool, _ label: String) throws {
    guard condition else { throw NativeSwitcherCheckFailure.failed(label) }
    print("PASS \(label)")
}

@main
private struct NativeSwitcherChecks {
    static let display = "00000000-0000-0000-0000-000000000100"
    static let space = "00000000-0000-0000-0000-000000000200"
    static let target = "00000000-0000-0000-0000-000000000001"
    static let baseline = "00000000-0000-0000-0000-000000000002"
    static func fixture() throws -> [String: Any] {
        let config = try PropertyListSerialization.data(fromPropertyList: ["assetID": "shuffle-all-aerials"], format: .binary, options: 0)
        let options = try PropertyListSerialization.data(fromPropertyList: ["values": ["frequency": ["id": "shuffle_every_12_hours"]]], format: .binary, options: 0)
        let scope: [String: Any] = ["Type": "linked", "Linked": [
            "LastSet": Date(timeIntervalSince1970: 0), "LastUse": Date(timeIntervalSince1970: 1),
            "Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.aerials", "Files": [Any](), "Configuration": config]],
                        "Shuffle": "$null", "EncodedOptionValues": options]
        ]]
        return ["AllSpacesAndDisplays": "$null", "SystemDefault": scope, "Displays": [display: scope],
                "Spaces": ["": ["Default": scope, "Displays": [display: scope]]]]
    }
    static func main() async throws {
        let raw = try PropertyListSerialization.data(fromPropertyList: fixture(), format: .binary, options: 0)
        let original = try NativeAerialSwitcher.decodedTree(raw)
        let schema = try NativeAerialSwitcher.validateSchema(original, displayUUID: display)
        try assertCheck(schema.ids.count == 4 && schema.selection == "shuffle-all-aerials", "strict single-display Linked schema")
        let candidate = try NativeAerialSwitcher.replacingAssetID(raw, assetID: target)
        let candidateTree = try NativeAerialSwitcher.decodedTree(candidate.data)
        let changes = try NativeAerialSwitcher.originalSettingMismatchPaths(original, candidateTree)
        try assertCheck(candidate.count == 4 && changes.count == 4 && changes.allSatisfy { $0.hasSuffix("[\"assetID\"]") }, "only embedded assetID leaves are changed")
        let reverted = try NativeAerialSwitcher.replacingAssetID(candidate.data, assetID: "shuffle-all-aerials")
        try assertCheck(try NativeAerialSwitcher.originalSettingMismatchPaths(original, NativeAerialSwitcher.decodedTree(reverted.data)).isEmpty, "asset-only rollback preserves options, provider, Files and timestamps")
        try assertCheck(try !NativeAerialSwitcher.configurationConflictPaths(expected: original, current: candidateTree).isEmpty, "manual selection change loses ownership")
        try assertCheck(try NativeAerialSwitcher.recoveryOwnership(current: original, previous: original, pending: candidateTree) == .previous,
                        "crash before live replacement keeps previous ownership")
        try assertCheck(try NativeAerialSwitcher.recoveryOwnership(current: candidateTree, previous: original, pending: candidateTree) == .pending,
                        "crash after live replacement recognizes pending ownership even before finalize")
        let other = try NativeAerialSwitcher.decodedTree(NativeAerialSwitcher.replacingAssetID(raw, assetID: baseline).data)
        try assertCheck(try NativeAerialSwitcher.recoveryOwnership(current: other, previous: original, pending: candidateTree) == .conflict,
                        "crash plus external selection never claims ownership")
        try assertCheck(!NativeAerialSwitcher.validSnapshotName("../Index.expected.plist") && !NativeAerialSwitcher.validSnapshotName("Index.expected.bad.plist") && NativeAerialSwitcher.validSnapshotName("Index.expected.\(UUID().uuidString).plist"),
                        "immutable recovery snapshot names cannot traverse directories")
        try assertCheck(try NativeAerialSwitcher.originalSettingMismatchPaths(["LastUse": Date(timeIntervalSince1970: 1)], ["LastUse": Date(timeIntervalSince1970: 5)]).isEmpty, "Date LastUse changes are operational")
        try assertCheck(try !NativeAerialSwitcher.originalSettingMismatchPaths(["LastUse": Date()], ["LastUse": "invalid"]).isEmpty, "LastUse type changes are not ignored")
        try assertCheck(try !NativeAerialSwitcher.originalSettingMismatchPaths(["LastSet": Date(timeIntervalSince1970: 1)], ["LastSet": Date(timeIntervalSince1970: 5)]).isEmpty, "LastSet settings changes retain ownership guard")
        try assertCheck(try !NativeAerialSwitcher.originalSettingMismatchPaths(["flag": true], ["flag": 1]).isEmpty, "boolean and numeric settings remain distinct")
        try assertCheck(try !NativeAerialSwitcher.originalSettingMismatchPaths(["Choices": [1]], ["Choices": [1, 2]]).isEmpty, "array counts cannot silently change")
        var normalized = original as! [String: Any]
        var spaces = normalized["Spaces"] as! [String: Any]
        let defaultScope = normalized["SystemDefault"]!
        spaces[space] = ["Default": defaultScope, "Displays": [display: defaultScope]]
        normalized["Spaces"] = spaces
        _ = try NativeAerialSwitcher.validateSchema(normalized, displayUUID: display)
        try assertCheck(try NativeAerialSwitcher.configurationConflictPaths(expected: original, current: normalized).isEmpty, "matching system-generated Space is preserved")
        func addOption(_ value: Any) -> Any {
            if var dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    if key == "EncodedOptionValues", var options = child as? [String: Any] {
                        options["unexpected"] = true; dictionary[key] = options
                    } else { dictionary[key] = addOption(child) }
                }
                return dictionary
            }
            if let array = value as? [Any] { return array.map(addOption) }
            return value
        }
        spaces[space] = addOption(spaces[space]!); normalized["Spaces"] = spaces
        try assertCheck(try !NativeAerialSwitcher.configurationConflictPaths(expected: original, current: normalized).isEmpty, "additional setting inside new Space is rejected bidirectionally")
        try assertCheck(NativeAerialSwitcher.addedPaths(["array": [["known": true]]], ["array": [["known": true, "extra": 1]]]) == [["array", "0", "extra"]], "added dictionary keys inside arrays are detected")

        let root = URL(fileURLWithPath: "/fixture/com.apple.wallpaper/aerials")
        let validPath = root.appendingPathComponent("videos/\(target).mov").path
        let rows = NativeAerialSwitcher.parseMovies("p100\ncWallpaperAerialsExtension\nf4\nn\(validPath)\nn/elsewhere/\(target).mov\nn\(root.path)/videos/not-a-uuid.mov\np101\ncOtherProvider\nf5\nn\(validPath)\n", aerialRoot: root)
        try assertCheck(rows.count == 1 && rows[0].assetID == target && rows[0].pid == "100", "lsof parser accepts only exact native directory, provider and UUID")
        let before = NativeAerialMovie(pid: "100", fileDescriptor: "4", path: validPath, assetID: target)
        let fresh = NativeAerialMovie(pid: "101", fileDescriptor: "4", path: root.appendingPathComponent("videos/\(baseline).mov").path, assetID: baseline)
        let known = Set([target, baseline]), baseIDs = Set([baseline])
        try assertCheck(!NativeAerialSwitcher.restorationTransition(before: [before], after: [before], baselineIDs: baseIDs, knownIDs: known, fixedBaselineID: nil), "old opened FD cannot prove restored policy")
        try assertCheck(!NativeAerialSwitcher.restorationTransition(before: [], after: [fresh], baselineIDs: baseIDs, knownIDs: known, fixedBaselineID: nil), "missing fresh predecessor cannot prove restored provider")
        try assertCheck(NativeAerialSwitcher.restorationTransition(before: [before], after: [fresh], baselineIDs: baseIDs, knownIDs: known, fixedBaselineID: baseline), "new provider plus exact fixed baseline is valid loading evidence")
        let freshTarget = NativeAerialMovie(pid: "101", fileDescriptor: "4", path: validPath, assetID: target)
        let previousBaseline = NativeAerialMovie(pid: "100", fileDescriptor: "4", path: fresh.path, assetID: baseline)
        let newlyOpenedTarget = NativeAerialMovie(pid: "100", fileDescriptor: "5", path: validPath, assetID: target)
        try assertCheck(!NativeAerialSwitcher.restorationTransition(before: [before], after: [before], baselineIDs: [target], knownIDs: [target], fixedBaselineID: target),
                        "pre-opened target FD cannot verify a new switch")
        try assertCheck(NativeAerialSwitcher.restorationTransition(before: [before], after: [freshTarget], baselineIDs: [target], knownIDs: [target], fixedBaselineID: target),
                        "new provider opening the exact target verifies switch loading")
        try assertCheck(NativeAerialSwitcher.restorationTransition(before: [previousBaseline], after: [newlyOpenedTarget], baselineIDs: [target], knownIDs: [target], fixedBaselineID: target),
                        "existing provider newly opening the exact target verifies switch loading")
        try assertCheck(!NativeAerialSwitcher.restorationTransition(before: [before], after: [fresh], baselineIDs: [target], knownIDs: [target], fixedBaselineID: target),
                        "new provider opening another asset cannot verify switch loading")
        try assertCheck(!NativeAerialSwitcher.restorationTransition(before: [], after: [freshTarget], baselineIDs: [target], knownIDs: [target], fixedBaselineID: target),
                        "missing predecessor cannot verify switch loading")

        let large = try NativeAerialSwitcher.command("/usr/bin/awk", ["BEGIN { for(i=0;i<350000;i++) printf \"X\"; for(i=0;i<280000;i++) printf \"Y\" > \"/dev/stderr\" }"], timeout: 3)
        try assertCheck(large.utf8.count == 350000, "bounded diagnostic drains both streams beyond pipe capacity")
        let began = ProcessInfo.processInfo.systemUptime
        var timedOut = false
        do { _ = try NativeAerialSwitcher.command("/bin/sleep", ["2"], timeout: 0.1) }
        catch { timedOut = true }
        try assertCheck(timedOut && ProcessInfo.processInfo.systemUptime - began < 0.7, "owned diagnostic timeout terminates and reaps child promptly")

        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("NativeSwitcherInitCheck-\(UUID().uuidString)")
        let switcher = NativeAerialSwitcher(supportDirectory: directory)
        let d = await switcher.diagnostics()
        try assertCheck(!fm.fileExists(atPath: directory.path) && !d.isPrepared && !d.hasOwnedChanges && !d.canRestore,
                        "actor initialization has no filesystem writes, preparation or timers")
        let canonical = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("NativeSwitcherFileCheck-\(UUID().uuidString)")
        try fm.createDirectory(at: canonical, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: canonical) }
        let metadata = canonical.appendingPathComponent("metadata.plist"), link = canonical.appendingPathComponent("link.plist")
        try Data([1,2,3]).write(to: metadata)
        try fm.createSymbolicLink(at: link, withDestinationURL: metadata)
        var linkRejected = false, sizeRejected = false
        do { _ = try NativeAerialSwitcher.readOwnedData(link, maximumBytes: 10) } catch { linkRejected = true }
        do { _ = try NativeAerialSwitcher.readOwnedData(metadata, maximumBytes: 2) } catch { sizeRejected = true }
        try assertCheck(linkRejected && sizeRejected && (try NativeAerialSwitcher.readOwnedData(metadata, maximumBytes: 10)).count == 3,
                        "local recovery files reject symbolic links and oversized input")

        let videos = canonical.appendingPathComponent("videos", isDirectory: true)
        try fm.createDirectory(at: videos, withIntermediateDirectories: true)
        let mainCategory = "00000000-0000-0000-0000-000000000300"
        let macCategory = "00000000-0000-0000-0000-000000000301"
        let macAsset = "00000000-0000-0000-0000-000000000003"
        let missingAsset = "00000000-0000-0000-0000-000000000004"
        let emptyAsset = "00000000-0000-0000-0000-000000000005"
        let linkedAsset = "00000000-0000-0000-0000-000000000006"
        let assetManifest = NativeAerialSwitcher.Manifest(assets: [
            ["id": target, "categories": [mainCategory], "includeInShuffle": false],
            ["id": baseline, "categories": [mainCategory], "includeInShuffle": true],
            ["id": macAsset, "categories": [macCategory], "includeInShuffle": true],
            ["id": missingAsset, "categories": [mainCategory]],
            ["id": emptyAsset, "categories": [mainCategory]],
            ["id": linkedAsset, "categories": [mainCategory]]
        ], categoryIDs: [mainCategory, macCategory], eligibleCategoryIDs: [mainCategory])
        for id in [target, baseline, macAsset] {
            try Data([1, 2, 3]).write(to: videos.appendingPathComponent("\(id).mov"))
        }
        try Data().write(to: videos.appendingPathComponent("\(emptyAsset).mov"))
        try fm.createSymbolicLink(at: videos.appendingPathComponent("\(linkedAsset).mov"),
                                  withDestinationURL: videos.appendingPathComponent("\(target).mov"))
        for id in [target, baseline] {
            try NativeAerialSwitcher.validateLocalAsset(id, manifest: assetManifest, aerialRoot: canonical)
        }
        try assertCheck(true, "custom native selection accepts both Apple shuffle flag values")
        func assetRejected(_ id: String) -> Bool {
            do {
                try NativeAerialSwitcher.validateLocalAsset(id, manifest: assetManifest, aerialRoot: canonical)
                return false
            } catch { return true }
        }
        try assertCheck([macAsset, missingAsset, emptyAsset, linkedAsset, "not-a-uuid", UUID().uuidString].allSatisfy(assetRejected),
                        "custom native selection still rejects unsupported, missing, empty, linked and unknown assets")

        // Replay must use the live fixed selection, rather than a cached UI ID
        // or one of the provider's pre-opened videos. Exercise the same guard
        // used by the read-only production method with real decoded fixtures.
        let fixedReplay = try NativeAerialSwitcher.validateSchema(candidateTree, displayUUID: display).selection
        try NativeAerialSwitcher.validateReplaySelection(expectedAssetID: target, currentAssetID: fixedReplay)
        try NativeAerialSwitcher.validateLocalAsset(target, manifest: assetManifest, aerialRoot: canonical)
        try assertCheck(true, "replay accepts the current fixed local asset even when Apple excludes it from shuffle")
        let externallySelected = try NativeAerialSwitcher.validateSchema(other, displayUUID: display).selection
        func replayConflict(_ expected: String, _ current: String?) -> Bool {
            do {
                try NativeAerialSwitcher.validateReplaySelection(expectedAssetID: expected, currentAssetID: current)
                return false
            } catch NativeAerialSwitcherError.concurrentSettingsChange(let paths) {
                return !paths.isEmpty
            } catch { return false }
        }
        try assertCheck(replayConflict(target, externallySelected),
                        "replay rejects a stale UI target after a different live fixed selection")
        try assertCheck(replayConflict(target, schema.selection) && replayConflict(target, nil),
                        "replay never treats a shuffle policy or unknown current selection as a fixed video")
        var malformedReplayRejected = false
        do { try NativeAerialSwitcher.validateReplaySelection(expectedAssetID: "../video", currentAssetID: "../video") }
        catch NativeAerialSwitcherError.invalidAsset { malformedReplayRejected = true }
        try assertCheck(malformedReplayRejected, "replay rejects a malformed expected UUID before constructing a video path")
        print("All native switcher offline checks passed. No live wallpaper Store was read/written and no WallpaperAgent/provider was signaled.")
    }
}
