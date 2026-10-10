import Foundation

private enum CatalogCheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): message } }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CatalogCheckFailure.failed(message) }
}

@main
private struct CatalogChecks {
    static let landscape = "A33A55D9-EDEA-4596-A850-6C10B54FBBB5"
    static let underwater = "8BE8B524-6EAE-43F5-A3E8-01DCFA1BCD4B"
    static let unknown = "00000000-0000-0000-0000-000000000099"
    static let first = "00000000-0000-0000-0000-000000000001"
    static let second = "00000000-0000-0000-0000-000000000002"
    static let third = "00000000-0000-0000-0000-000000000003"
    static let fourth = "00000000-0000-0000-0000-000000000004"
    static let fifth = "00000000-0000-0000-0000-000000000005"
    static let sixth = "00000000-0000-0000-0000-000000000006"

    static func main() throws {
        let fm = FileManager()
        let directory = fm.temporaryDirectory.appendingPathComponent("AerialCatalogChecks-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let root = directory.appendingPathComponent("aerials")
        let manifest = root.appendingPathComponent("manifest/entries.json")
        let bundle = root.appendingPathComponent("manifest/TVIdleScreenStrings.bundle")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        func write(_ data: Data, to url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        func plist(_ object: Any, to url: URL) throws {
            try write(PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0), to: url)
        }
        func asset(_ id: String, categories: [String], shuffle: Bool = true) -> [String: Any] {
            ["id": id, "categories": categories, "localizedNameKey": "name." + id,
             "accessibilityLabel": "Landscape Underwater Name", "includeInShuffle": shuffle,
             "previewImage": "https://example.invalid/preview.jpg"]
        }
        let json: [String: Any] = [
            "categories": [
                ["id": landscape, "localizedNameKey": "AerialCategoryLandscapes"],
                ["id": underwater, "localizedNameKey": "AerialCategoryUnderwater"],
                ["id": landscape, "localizedNameKey": "AerialCategoryCities"]
            ],
            "assets": [
                asset(first, categories: [landscape]),
                asset(second, categories: [underwater], shuffle: false),
                asset(third, categories: [landscape]),
                asset(fourth, categories: [unknown]),
                asset(fifth, categories: [unknown, underwater, landscape, underwater]),
                asset(sixth, categories: [landscape]),
                asset(first, categories: [underwater]),
                asset("../../escape", categories: [landscape])
            ]
        ]
        try write(JSONSerialization.data(withJSONObject: json), to: manifest)
        try plist(["zh_CN": ["name." + first: "中文航拍", "AerialCategoryLandscapes": "自然景观", "numeric": 42],
                   "en": ["name." + second: "English fallback", "AerialCategoryUnderwater": "Underwater"]],
                  to: resources.appendingPathComponent("Localizable.nocache.loctable"))
        for id in [first, second, fourth, fifth] {
            let size = [first: 2, second: 3, fourth: 5, fifth: 7][id]!
            try write(Data(repeating: 1, count: size), to: root.appendingPathComponent("videos/" + id + ".mov"))
        }
        try write(Data(), to: root.appendingPathComponent("videos/" + third + ".mov"))
        try write(Data(repeating: 1, count: 11), to: root.appendingPathComponent("4KSDR240FPS/" + third + ".mov"))
        let outsideMovie = directory.appendingPathComponent("outside.mov")
        try write(Data([1]), to: outsideMovie)
        try fm.createSymbolicLink(at: root.appendingPathComponent("videos/" + sixth + ".mov"), withDestinationURL: outsideMovie)

        let current = try AerialCatalog.load(rootURL: root, preferredLanguage: "zh-Hans-CN")
        try check(current.assets.count == 6, "duplicate or invalid UUID reached catalog")
        try check(current.assets.first?.localizedName == "中文航拍", "mixed-type loctable lost string names")
        try check(current.assets[1].localizedName == "English fallback", "per-key English fallback failed")
        try check(current.assets[2].localVideoURL?.path.contains("4KSDR240FPS") == true, "empty movie masked valid alternate local directory")
        try check(current.assets[5].downloaded == false, "escaped video symlink marked downloaded")
        try check(current.assets[3].category == .unknown, "asset name was used to guess category")
        try check(current.categories.contains(where: { $0.id == unknown && $0.category == .unknown }), "unmapped category omitted")
        try check(current.assets[4].categoryIdentifiers == [unknown, underwater, landscape], "manifest category relationships were not preserved")
        try check(!current.assets[1].includeInShuffle, "Apple shuffle metadata was not preserved")
        try check(current.playlist(categories: [.landscape, .underwater]).map(\.id) == [first, second, fifth],
                  "custom playlist obeyed Apple's shuffle flag or included unknown, missing or unverified alternate-directory movies")
        try check(current.playlist(categories: [.underwater]).map(\.id) == [second, fifth],
                  "Apple shuffle exclusion incorrectly removed a downloaded asset from its selected category")
        try check(current.assets[2].downloaded && !current.assets[2].eligibleForNativeSwitch, "unverified alternate directory entered native rotation")
        let allStorage = current.storage()
        try check(allStorage.fileCount == 5 && allStorage.byteCount == 28 && allStorage.unmeasuredFileCount == 0,
                  "storage includes Apple shuffle exclusions, unknown and alternate files but excludes empty files and escaped symlinks")
        try check(current.storage(categories: [.landscape]).byteCount == 20, "category storage lost alternate-directory file")
        try check(current.storage(categories: [.landscape, .underwater]).byteCount == 23,
                  "category union double counted a multi-category asset")
        try check(AerialStorageSummary(assets: current.playlist(categories: [.landscape, .underwater])).byteCount == 12,
                  "playlist storage counted files outside the usable pool")
        try check(AerialStorageSummary(assets: [current.assets[0], current.assets[0]]).byteCount == 2,
                  "storage counted duplicate local paths twice")
        try check(current.playlist(categories: [.mac, .unknown]).isEmpty, "non-primary category entered selectable pool")
        try check(!current.diagnostics.isEmpty, "invalid and unmapped metadata had no diagnostics")
        print("PASS current loctable: mixed values, language aliases/fallback, category identities, pool filtering, regular nonempty videos")
        print("PASS custom playlist includes downloaded Apple shuffle exclusions while preserving their metadata")
        print("PASS video sizes: exact metadata bytes, category union/path deduplication, native pool boundary")

        try fm.removeItem(at: resources.appendingPathComponent("Localizable.nocache.loctable"))
        let legacy = bundle.appendingPathComponent("zh_CN.lproj/Localizable.nocache.strings")
        try plist(["name." + first: "旧版中文航拍", "AerialCategoryLandscapes": "自然景观", "numeric": 9], to: legacy)
        let old = try AerialCatalog.load(rootURL: root)
        try check(old.assets.first?.localizedName == "旧版中文航拍", "legacy flat .strings layout failed")
        print("PASS legacy .strings: binary plist and mixed values")

        try plist(["name." + first: "Contents 名称"],
                  to: resources.appendingPathComponent("zh_CN.lproj/Localizable.nocache.strings"))
        try fm.removeItem(at: legacy)
        let contents = try AerialCatalog.load(rootURL: root)
        try check(contents.assets.first?.localizedName == "Contents 名称", "Contents/Resources .strings layout failed")
        print("PASS Contents/Resources .strings layout")

        let encoded = try JSONEncoder().encode(current)
        let decoded = try JSONDecoder().decode(AerialCatalogSnapshot.self, from: encoded)
        try check(decoded == current, "Codable snapshot round trip changed values")
        var olderJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        olderJSON["assets"] = (olderJSON["assets"] as! [[String: Any]]).map { entry in
            var copy = entry
            copy.removeValue(forKey: "localVideoFileSizeBytes")
            return copy
        }
        let older = try JSONDecoder().decode(AerialCatalogSnapshot.self, from: JSONSerialization.data(withJSONObject: olderJSON))
        try check(older.storage().unmeasuredFileCount == 5 && older.storage().byteCount == 0,
                  "old snapshots must mark unmeasured file sizes instead of treating them as measured zero")
        try check(Set(current.assets).count == 6, "Hashable asset identity lost records")
        print("PASS Codable/Hashable immutable snapshot round trip")

        let escapedLocalization = directory.appendingPathComponent("outside.strings")
        try plist(["name." + first: "MUST NOT READ"], to: escapedLocalization)
        let contentsStrings = resources.appendingPathComponent("zh_CN.lproj/Localizable.nocache.strings")
        try fm.removeItem(at: contentsStrings)
        try fm.createSymbolicLink(at: contentsStrings, withDestinationURL: escapedLocalization)
        let safe = try AerialCatalog.load(rootURL: root)
        try check(safe.assets.first?.localizedName != "MUST NOT READ", "localization escaped root")
        let invalidLanguage = try AerialCatalog.load(rootURL: root, preferredLanguage: "../../outside")
        try check(invalidLanguage.assets.first?.localizedName != "MUST NOT READ", "language path injection reached file")
        print("PASS localization symlink boundary and language path validation")

        let outsideManifest = directory.appendingPathComponent("outside.json")
        try write(JSONSerialization.data(withJSONObject: json), to: outsideManifest)
        try fm.removeItem(at: manifest)
        try fm.createSymbolicLink(at: manifest, withDestinationURL: outsideManifest)
        do {
            _ = try AerialCatalog.load(rootURL: root)
            throw CatalogCheckFailure.failed("manifest symlink escape accepted")
        } catch AerialCatalogError.unreadableFile { }
        try fm.removeItem(at: manifest)
        try write(Data(repeating: 32, count: 8 * 1_024 * 1_024 + 1), to: manifest)
        do {
            _ = try AerialCatalog.load(rootURL: root)
            throw CatalogCheckFailure.failed("oversized manifest accepted")
        } catch AerialCatalogError.oversizedFile { }
        try write(Data("{bad json}".utf8), to: manifest)
        do {
            _ = try AerialCatalog.load(rootURL: root)
            throw CatalogCheckFailure.failed("corrupt manifest accepted")
        } catch AerialCatalogError.invalidManifest { }
        print("PASS escaped, oversized and malformed manifests fail safely")

        if CommandLine.arguments.contains("--live") {
            let live = try AerialCatalog.load()
            let allPrimaryPool = live.playlist(categories: Set(AerialCategory.primaryCategories))
            let poolIDs = Set(allPrimaryPool.map(\.assetID))
            let appleShuffleExclusions = live.assets.filter {
                !$0.includeInShuffle && $0.downloaded && $0.eligibleForNativeSwitch && $0.categories.contains(where: \.isPrimaryCategory)
            }
            try check(appleShuffleExclusions.allSatisfy { poolIDs.contains($0.assetID) },
                      "downloaded primary-category video was excluded only by Apple's shuffle metadata")
            print("LIVE assets=\(live.assets.count), categories=\(live.categories.count), downloaded=\(live.assets.filter(\.downloaded).count), landscape+underwater pool=\(live.playlist(categories: [.landscape, .underwater]).count)")
            print("LIVE all primary-category pool=\(allPrimaryPool.count), Apple shuffle exclusions included=\(appleShuffleExclusions.count)")
            print("LIVE indexed video bytes=\(live.storage().byteCount), unmeasured=\(live.storage().unmeasuredFileCount)")
            for category in live.categories {
                let members = live.assets.filter { $0.categoryIdentifiers.contains(category.id) }
                print("LIVE \(category.localizedName): \(members.count) assets / \(members.filter(\.downloaded).count) local / \(AerialStorageSummary(assets: members).byteCount) bytes")
            }
            print("LIVE names: \(live.assets.prefix(3).map(\.localizedName).joined(separator: ", "))")
            for diagnostic in live.diagnostics { print("LIVE diagnostic: \(diagnostic)") }
        }
        print("All catalog checks passed. No wallpaper configuration was written or resources downloaded.")
    }
}
