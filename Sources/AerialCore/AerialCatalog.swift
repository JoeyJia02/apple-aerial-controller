import Foundation

public enum AerialCategory: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case landscape, underwater, cityscape, earth, mac, unknown

    public var id: String { rawValue }
    public static var primaryCategories: [AerialCategory] { [.landscape, .underwater, .cityscape, .earth] }
    public var isPrimaryCategory: Bool { Self.primaryCategories.contains(self) }
    public var displayName: String {
        switch self {
        case .landscape: "自然景观"
        case .underwater: "水下景观"
        case .cityscape: "城市景观"
        case .earth: "地球"
        case .mac: "Mac"
        case .unknown: "未知分类"
        }
    }

    fileprivate init(manifestNameKey: String?) {
        switch manifestNameKey {
        case "AerialCategoryLandscapes": self = .landscape
        case "AerialCategoryUnderwater": self = .underwater
        case "AerialCategoryCities": self = .cityscape
        case "AerialCategorySpace": self = .earth
        case "AerialCategoryMac": self = .mac
        default: self = .unknown
        }
    }
}

public struct AerialCategoryInfo: Identifiable, Codable, Hashable, Sendable {
    /// Apple manifest category identifier; this is independent of its display name.
    public let id: String
    public let category: AerialCategory
    public let localizedName: String
    public let manifestNameKey: String?

    public init(id: String, category: AerialCategory, localizedName: String, manifestNameKey: String?) {
        self.id = id
        self.category = category
        self.localizedName = localizedName
        self.manifestNameKey = manifestNameKey
    }
}

public struct AerialAsset: Identifiable, Codable, Hashable, Sendable {
    public let assetID: String
    public var id: String { assetID }
    public let localizedName: String
    public let category: AerialCategory
    public let categoryIdentifier: String
    public let categoryName: String
    /// Preserve every manifest relationship; a future asset can have several categories.
    public let categoryIdentifiers: [String]
    public let categories: [AerialCategory]
    public let localVideoURL: URL?
    /// A verified regular, nonempty local file exists. This does not imply full video decoding.
    public let downloaded: Bool
    /// Logical file size captured during the background scan; no video data is read.
    public let localVideoFileSizeBytes: Int64?
    /// Only videos/ has been verified with this app's native backend on this Mac.
    public var eligibleForNativeSwitch: Bool {
        localVideoURL?.deletingLastPathComponent().lastPathComponent == "videos"
    }
    /// Apple's shuffle metadata; it does not restrict this app's custom playlist.
    public let includeInShuffle: Bool
    /// Manifest metadata only. The catalog never fetches this URL.
    public let thumbnailURL: URL?

    public init(assetID: String, localizedName: String, category: AerialCategory,
                categoryIdentifier: String, categoryName: String,
                categoryIdentifiers: [String], categories: [AerialCategory],
                localVideoURL: URL?, includeInShuffle: Bool, thumbnailURL: URL?,
                localVideoFileSizeBytes: Int64? = nil) {
        self.assetID = assetID
        self.localizedName = localizedName
        self.category = category
        self.categoryIdentifier = categoryIdentifier
        self.categoryName = categoryName
        self.categoryIdentifiers = categoryIdentifiers
        self.categories = categories
        self.localVideoURL = localVideoURL
        self.downloaded = localVideoURL != nil
        self.localVideoFileSizeBytes = localVideoFileSizeBytes
        self.includeInShuffle = includeInShuffle
        self.thumbnailURL = thumbnailURL
    }
}

public struct AerialStorageSummary: Equatable, Sendable {
    public let fileCount: Int
    public let byteCount: Int64
    public let unmeasuredFileCount: Int

    /// Count each indexed local path once, including assets belonging to several categories.
    public init(assets: [AerialAsset]) {
        var files: [URL: Int64] = [:]
        var unmeasured: Set<URL> = []
        for asset in assets {
            guard let url = asset.localVideoURL else { continue }
            let key = url.standardizedFileURL
            let size = asset.localVideoFileSizeBytes.flatMap { $0 >= 0 ? $0 : nil }
            if let size {
                files[key] = size
                unmeasured.remove(key)
            } else if files[key] == nil {
                unmeasured.insert(key)
            }
        }
        fileCount = files.count + unmeasured.count
        unmeasuredFileCount = unmeasured.count
        byteCount = files.values.reduce(0) { total, size in
            let sum = total.addingReportingOverflow(size)
            return sum.overflow ? Int64.max : sum.partialValue
        }
    }
}

public struct AerialCatalogSnapshot: Codable, Hashable, Sendable {
    public let assets: [AerialAsset]
    public let categories: [AerialCategoryInfo]
    public let refreshedAt: Date
    public let diagnostics: [String]

    public init(assets: [AerialAsset], categories: [AerialCategoryInfo], refreshedAt: Date, diagnostics: [String]) {
        self.assets = assets
        self.categories = categories
        self.refreshedAt = refreshedAt
        self.diagnostics = diagnostics
    }

    public func playlist(categories selected: Set<AerialCategory>) -> [AerialAsset] {
        let primarySelection = selected.filter(\.isPrimaryCategory)
        return assets.filter { asset in
            asset.downloaded && asset.eligibleForNativeSwitch
                && asset.categories.contains(where: primarySelection.contains)
        }
    }

    public func storage(categories selected: Set<AerialCategory>? = nil) -> AerialStorageSummary {
        AerialStorageSummary(assets: assets.filter { asset in
            selected.map { selection in asset.categories.contains(where: selection.contains) } ?? true
        })
    }
}

public enum AerialCatalogError: Error, LocalizedError, Sendable {
    case invalidRoot, missingManifest(URL), unreadableFile(URL), oversizedFile(URL), invalidManifest

    public var errorDescription: String? {
        switch self {
        case .invalidRoot: "航拍资源目录必须是本地目录。"
        case .missingManifest(let url): "未找到 Apple 航拍资源清单：\(url.path)"
        case .unreadableFile(let url): "无法安全读取航拍元数据：\(url.path)"
        case .oversizedFile(let url): "航拍元数据文件超过读取上限：\(url.path)"
        case .invalidManifest: "Apple 航拍资源清单格式无法识别。"
        }
    }
}

/// Synchronous, read-only loading. Call from a background task and publish the
/// immutable Sendable snapshot on the UI actor. No downloads or preference writes.
public enum AerialCatalog {
    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)
    }

    public static func load(rootURL: URL? = nil, preferredLanguage: String = "zh_CN") throws -> AerialCatalogSnapshot {
        let proposed = rootURL ?? defaultRootURL
        guard proposed.isFileURL else { throw AerialCatalogError.invalidRoot }
        let root = proposed.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager()
        let manifestURL = root.appendingPathComponent("manifest/entries.json")
        guard fm.fileExists(atPath: manifestURL.path) else { throw AerialCatalogError.missingManifest(manifestURL) }
        let bytes = try smallFile(manifestURL, inside: root, maximumBytes: 8 * 1_024 * 1_024, fm: fm)
        guard let manifest = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let manifestAssets = manifest["assets"] as? [[String: Any]],
              let manifestCategories = manifest["categories"] as? [[String: Any]] else {
            throw AerialCatalogError.invalidManifest
        }
        var diagnostics: [String] = []
        let localizations = localization(root: root, preferredLanguage: preferredLanguage, fm: fm, diagnostics: &diagnostics)
        func name(_ key: String?, fallback: String) -> String {
            guard let key else { return fallback }
            for table in localizations {
                if let value = table[key], !value.isEmpty { return value }
            }
            return fallback
        }

        var categories: [AerialCategoryInfo] = []
        var categoryMap: [String: AerialCategoryInfo] = [:]
        for entry in manifestCategories {
            guard let id = entry["id"] as? String, UUID(uuidString: id) != nil else {
                diagnostics.append("忽略缺少有效 UUID 的分类。")
                continue
            }
            guard categoryMap[id] == nil else {
                diagnostics.append("清单包含重复分类 UUID：\(id)")
                continue
            }
            let key = entry["localizedNameKey"] as? String
            let category = AerialCategory(manifestNameKey: key)
            let info = AerialCategoryInfo(id: id, category: category,
                localizedName: name(key, fallback: category.displayName), manifestNameKey: key)
            categories.append(info)
            categoryMap[id] = info
        }

        var assets: [AerialAsset] = []
        var seenIDs: Set<String> = []
        var unresolvedIDs: Set<String> = []
        var fallbackNames = 0
        for entry in manifestAssets {
            guard let id = entry["id"] as? String, UUID(uuidString: id) != nil else {
                diagnostics.append("忽略缺少有效 UUID 的资源。")
                continue
            }
            guard seenIDs.insert(id).inserted else {
                diagnostics.append("清单包含重复资源 UUID：\(id)")
                continue
            }
            let categoryIDs = orderedUnique(entry["categories"] as? [String] ?? [])
            let infos = categoryIDs.map { identifier -> AerialCategoryInfo in
                if let info = categoryMap[identifier] { return info }
                unresolvedIDs.insert(identifier)
                return AerialCategoryInfo(id: identifier, category: .unknown,
                                          localizedName: AerialCategory.unknown.displayName, manifestNameKey: nil)
            }
            let primary = infos.first(where: { $0.category.isPrimaryCategory }) ?? infos.first
            let key = entry["localizedNameKey"] as? String
            if key == nil || !localizations.contains(where: { $0[key!] != nil }) { fallbackNames += 1 }
            let movie = localMovie(id, root: root, fm: fm)
            let size = movie.flatMap { url in
                (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            }
            let thumbnail = (entry["previewImage"] as? String).flatMap(URL.init(string:)).flatMap { url in
                ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? url : nil
            }
            assets.append(AerialAsset(assetID: id,
                localizedName: name(key, fallback: entry["accessibilityLabel"] as? String ?? id),
                category: primary?.category ?? .unknown, categoryIdentifier: primary?.id ?? "",
                categoryName: primary?.localizedName ?? AerialCategory.unknown.displayName,
                categoryIdentifiers: categoryIDs, categories: orderedUnique(infos.map(\.category)),
                localVideoURL: movie, includeInShuffle: entry["includeInShuffle"] as? Bool ?? false,
                thumbnailURL: thumbnail, localVideoFileSizeBytes: size))
        }
        for identifier in unresolvedIDs.sorted() where categoryMap[identifier] == nil {
            categories.append(AerialCategoryInfo(id: identifier, category: .unknown,
                localizedName: AerialCategory.unknown.displayName, manifestNameKey: nil))
        }
        if !unresolvedIDs.isEmpty {
            diagnostics.append("资源引用了未映射分类；未按名称猜测分类：\(unresolvedIDs.sorted().joined(separator: ", "))")
        }
        if fallbackNames > 0 { diagnostics.append("\(fallbackNames) 个资源名称使用清单名称或 UUID 后备值。") }
        let alternateCount = assets.filter { $0.downloaded && !$0.eligibleForNativeSwitch }.count
        if alternateCount > 0 {
            diagnostics.append("\(alternateCount) 个备用目录视频已计入下载和大小；该目录尚未通过本机原生切换验收，未纳入轮换池。")
        }
        if assets.isEmpty { diagnostics.append("清单中没有可识别的航拍资源。") }
        return AerialCatalogSnapshot(assets: assets, categories: categories, refreshedAt: Date(),
                                     diagnostics: orderedUnique(diagnostics))
    }

    private static func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func smallFile(_ url: URL, inside root: URL, maximumBytes: Int, fm: FileManager) throws -> Data {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/"),
              let attributes = try? fm.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { throw AerialCatalogError.unreadableFile(url) }
        guard size.int64Value >= 0, size.int64Value <= Int64(maximumBytes) else { throw AerialCatalogError.oversizedFile(url) }
        guard let handle = try? FileHandle(forReadingFrom: resolved) else { throw AerialCatalogError.unreadableFile(url) }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw AerialCatalogError.oversizedFile(url) }
        return data
    }

    private static func localMovie(_ id: String, root: URL, fm: FileManager) -> URL? {
        for directory in ["videos", "4KSDR240FPS"] {
            let url = root.appendingPathComponent(directory, isDirectory: true).appendingPathComponent(id + ".mov")
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/"),
                  let attributes = try? fm.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.int64Value > 0 else { continue }
            return resolved
        }
        return nil
    }

    private static func languageCandidates(_ preferred: String) -> [String] {
        guard !preferred.isEmpty, preferred.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-" )).contains($0) }) else { return ["en"] }
        let normalized = preferred.replacingOccurrences(of: "-", with: "_")
        let parts = normalized.split(separator: "_").map(String.init)
        var languages = [preferred, normalized]
        if parts.first?.lowercased() == "zh" {
            let traditional = parts.contains { ["hant", "tw", "hk", "mo"].contains($0.lowercased()) }
            languages += traditional ? ["zh_TW", "zh_Hant", "zh_HK"] : ["zh_CN", "zh_Hans"]
        }
        if let base = parts.first { languages.append(base) }
        return orderedUnique(languages + ["en"])
    }

    private static func localization(root: URL, preferredLanguage: String, fm: FileManager,
                                     diagnostics: inout [String]) -> [[String: String]] {
        let bundle = root.appendingPathComponent("manifest/TVIdleScreenStrings.bundle", isDirectory: true)
        let containers = [bundle.appendingPathComponent("Contents/Resources", isDirectory: true), bundle]
        let languages = languageCandidates(preferredLanguage)
        var tables: [String: [String: String]] = [:]
        func dictionary(_ url: URL) -> [String: Any]? {
            guard fm.fileExists(atPath: url.path) else { return nil }
            do {
                let data = try smallFile(url, inside: root, maximumBytes: 4 * 1_024 * 1_024, fm: fm)
                guard let result = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                    diagnostics.append("忽略无法识别的本地名称表：\(url.lastPathComponent)")
                    return nil
                }
                return result
            } catch {
                diagnostics.append("无法读取本地名称表：\(url.lastPathComponent)")
                return nil
            }
        }
        func strings(_ values: [String: Any]) -> [String: String] {
            values.reduce(into: [:]) { output, pair in
                if let value = pair.value as? String { output[pair.key] = value }
            }
        }
        for container in containers {
            if let all = dictionary(container.appendingPathComponent("Localizable.nocache.loctable")) {
                for language in languages {
                    if let values = all[language] as? [String: Any] {
                        tables[language, default: [:]].merge(strings(values)) { _, fresh in fresh }
                    }
                }
            }
        }
        for language in languages {
            for container in containers {
                if let values = dictionary(container.appendingPathComponent(language + ".lproj/Localizable.nocache.strings")) {
                    tables[language, default: [:]].merge(strings(values)) { _, fresh in fresh }
                }
            }
        }
        if tables.values.allSatisfy(\.isEmpty) { diagnostics.append("没有可读取的本地名称表，将使用清单名称。") }
        return languages.compactMap { tables[$0] }
    }
}
