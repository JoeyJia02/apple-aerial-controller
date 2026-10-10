import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var catalog: AerialCatalogSnapshot?
    @Published private(set) var selectedCategories: Set<AerialCategory>
    @Published private(set) var intervalMinutes: Int
    @Published var intervalChoice: Int
    @Published var customMinutes: String
    @Published private(set) var isLoading = false
    @Published private(set) var isSwitching = false
    @Published private(set) var isReplaying = false
    @Published private(set) var hasReplayFrame = false
    @Published private(set) var isAutomatic = false
    @Published private(set) var environmentReady = false
    @Published private(set) var canRestore = false
    @Published private(set) var externalChangeDetected = false
    @Published private(set) var currentAssetID: String?
    @Published private(set) var currentName = "正在检查资源…"
    @Published private(set) var message = "初次打开为暂停状态。"
    @Published private(set) var errorMessage: String?
    @Published private(set) var nextDue: Date?

    let scheduler = RotationScheduler()
    let switcher: NativeAerialSwitcher
    let preferenceStore: PreferenceStore
    let desktopReplay = DesktopReplayController()
    private var automaticGeneration: UInt64 = 0
    private var replayGeneration: UInt64 = 0
    private var nativeSelectionID: String?
    private var isTerminating = false
    private var rotationRequested: Bool
    private var startupResumePending: Bool
    private var preparedOwnedSession = false
    private var preferencesReadFailed = false
    private var observedSchedulerStatus: RotationScheduler.Status = .paused
    private var observedWake: Date?

    static let presets = [15, 30, 60, 120]

    init(supportDirectory: URL = ControllerPaths.supportDirectory) {
        preferenceStore = PreferenceStore(directory: supportDirectory)
        switcher = NativeAerialSwitcher(supportDirectory: supportDirectory.appendingPathComponent("wallpaper-backups"))
        let settings: ControllerPreferences
        do { settings = try preferenceStore.load() }
        catch {
            settings = ControllerPreferences()
            preferencesReadFailed = true
            errorMessage = "保存的设置无法读取，已使用默认值并保持暂停。"
        }
        selectedCategories = Set(settings.selectedCategoryKeys.compactMap(AerialCategory.init(rawValue:)))
        intervalMinutes = settings.intervalMinutes
        intervalChoice = Self.presets.contains(settings.intervalMinutes) ? settings.intervalMinutes : 0
        customMinutes = String(settings.intervalMinutes)
        rotationRequested = settings.rotationRequested
        startupResumePending = settings.rotationRequested
        desktopReplay.onStateChange = { [weak self] state in self?.replayStateChanged(state) }
        scheduler.onStateChange = { [weak self] in
            guard let self else { return }
            if self.observedSchedulerStatus != self.scheduler.status || self.observedWake != self.scheduler.lastWake {
                self.automaticGeneration &+= 1
            }
            self.observedSchedulerStatus = self.scheduler.status
            self.observedWake = self.scheduler.lastWake
            self.nextDue = self.scheduler.nextDue
        }
        Task { [weak self] in
            await self?.refresh()
        }
    }

    var playlist: [AerialAsset] { catalog?.playlist(categories: selectedCategories) ?? [] }
    var currentAsset: AerialAsset? { catalog?.assets.first { $0.assetID == currentAssetID } }
    var canSwitch: Bool { !isTerminating && environmentReady && !isLoading && !isSwitching && !playlist.isEmpty }
    var canReplay: Bool {
        guard !isTerminating, environmentReady, !isLoading, !isSwitching, !isReplaying,
              let asset = currentAsset, nativeSelectionID == asset.assetID else { return false }
        return asset.downloaded && asset.eligibleForNativeSwitch && asset.categories.contains(where: \.isPrimaryCategory)
    }

    private func replayStateChanged(_ state: DesktopReplayController.State) {
        switch state {
        case .idle:
            // Invalidate even while a native switch is awaiting its provider:
            // sleep/session/Space changes must prevent a later window appearing.
            if isReplaying || hasReplayFrame { message = "已回到系统壁纸画面。" }
            replayGeneration &+= 1
            isReplaying = false
            hasReplayFrame = false
        case .preparing:
            isReplaying = true
            // Keep the previous visible frame while the replacement decodes.
            message = "正在准备播放当前航拍…"
        case .prepared:
            isReplaying = true
            hasReplayFrame = true
            message = "首帧已准备，即将播放…"
        case .playing:
            isReplaying = true
            hasReplayFrame = true
            message = "正在播放当前航拍；完整播放后停在最后一帧。"
        case .holding:
            isReplaying = false
            hasReplayFrame = true
            message = "已完整播放，停在最后一帧。"
        case .failed(let reason):
            isReplaying = false
            hasReplayFrame = false
            errorMessage = reason
            message = "桌面播放未完成，已返回系统壁纸。"
        }
    }

    func stopReplay(updateMessage: Bool = true) {
        replayGeneration &+= 1
        isReplaying = false
        hasReplayFrame = false
        desktopReplay.stop()
        if updateMessage { message = "已回到系统壁纸画面。" }
    }

    func replay() async {
        guard canReplay, let assetID = currentAssetID else { return }
        // Cancel old asynchronous work without exposing the native wallpaper.
        replayGeneration &+= 1
        let generation = replayGeneration
        automaticGeneration &+= 1
        isSwitching = true
        errorMessage = nil
        defer { isSwitching = false }
        await playCurrentAerial(assetID: assetID, generation: generation, afterSwitch: false)
    }

    /// Replay starts a video; Next only verifies its already-running video after
    /// native commit. A media error must not undo the successful native selection.
    private func playCurrentAerial(assetID: String, generation: UInt64, afterSwitch: Bool) async {
        guard !isTerminating, generation == replayGeneration, currentAssetID == assetID else { return }
        if !afterSwitch {
            isReplaying = true
            message = "正在检查当前航拍…"
        }
        do {
            // Read-only validation: no Wallpaper Store write or native reload.
            let url = try await switcher.validatedReplaySource(expectedAssetID: assetID)
            guard !isTerminating, generation == replayGeneration, currentAssetID == assetID else { throw CancellationError() }
            if afterSwitch {
                try desktopReplay.validateActiveSource(url: url)
                if desktopReplay.state == .playing {
                    message = "正在播放当前航拍；完整播放后停在最后一帧。"
                }
            } else {
                try await desktopReplay.start(url: url)
            }
            guard !isTerminating, generation == replayGeneration else { return }
            if isAutomatic && !afterSwitch { scheduler.resetCountdown() }
        } catch is CancellationError {
            if generation == replayGeneration { stopReplay(updateMessage: true) }
        } catch {
            guard !isTerminating, generation == replayGeneration else { return }
            let mediaFailure: String?
            if case .failed(let reason) = desktopReplay.state { mediaFailure = reason }
            else { mediaFailure = nil }
            stopReplay(updateMessage: false)
            if error is NativeAerialSwitcherError {
                pause()
                applyDiagnostics(await switcher.diagnostics())
                errorMessage = readableError(error)
            } else {
                errorMessage = mediaFailure ?? error.localizedDescription
            }
            message = afterSwitch ? "壁纸已切换，但桌面播放未完成；已返回系统画面。" : "重播未完成，已返回系统壁纸。"
        }
    }

    func downloadedCount(_ category: AerialCategory) -> Int {
        catalog?.playlist(categories: [category]).count ?? 0
    }

    func localAssetCount(_ category: AerialCategory) -> Int {
        catalog?.assets.filter { $0.downloaded && $0.categories.contains(category) }.count ?? 0
    }

    func storageLabel(_ category: AerialCategory? = nil) -> String {
        guard let catalog else { return "正在统计…" }
        let summary = catalog.storage(categories: category.map { [$0] })
        return formattedStorage(summary)
    }

    var playlistStorageLabel: String { formattedStorage(AerialStorageSummary(assets: playlist)) }

    private func formattedStorage(_ summary: AerialStorageSummary) -> String {
        let size = ByteCountFormatter.string(fromByteCount: summary.byteCount, countStyle: .file)
        return summary.unmeasuredFileCount == 0 ? size : "至少 \(size)（\(summary.unmeasuredFileCount) 个文件未计量）"
    }

    func setCategory(_ category: AerialCategory, selected: Bool) {
        if selected { selectedCategories.insert(category) } else { selectedCategories.remove(category) }
        persistPreferences()
        if playlist.isEmpty { pause(); message = "请勾选至少一个有本地资源的分类。" }
    }

    func chooseInterval(_ choice: Int) {
        intervalChoice = choice
        guard choice != 0 else { customMinutes = String(intervalMinutes); return }
        applyInterval(choice)
    }

    func applyCustomInterval() {
        guard let value = Int(customMinutes.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...ControllerPreferences.maximumMinutes).contains(value) else {
            errorMessage = "请输入正整数分钟，最多525600分钟。"
            return
        }
        intervalChoice = 0
        applyInterval(value)
    }

    private func applyInterval(_ minutes: Int) {
        intervalMinutes = minutes
        customMinutes = String(minutes)
        errorMessage = nil
        persistPreferences()
        automaticGeneration &+= 1
        _ = scheduler.updateInterval(TimeInterval(minutes) * 60)
    }

    @discardableResult
    private func persistPreferences() -> Bool {
        do {
            try preferenceStore.save(ControllerPreferences(selectedCategoryKeys: selectedCategories.map(\.rawValue),
                                                           intervalMinutes: intervalMinutes,
                                                           rotationRequested: rotationRequested))
            preferencesReadFailed = false
            return true
        } catch {
            startupResumePending = false
            rotationRequested = false
            stopRuntime()
            errorMessage = "设置保存失败，已暂停：\(error.localizedDescription)"
            return false
        }
    }

    func refresh() async {
        guard !isLoading, !isSwitching, !isReplaying else { return }
        stopReplay(updateMessage: false)
        isLoading = true
        defer {
            isLoading = false
            resumeAfterLaunchIfRequested()
        }
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) { try AerialCatalog.load() }.value
            catalog = snapshot
            let diagnostic = try await switcher.prepare()
            applyDiagnostics(diagnostic)
            environmentReady = diagnostic.isPrepared && !diagnostic.isOperating && !diagnostic.externalChangeDetected
            preparedOwnedSession = diagnostic.hasOwnedChanges
            if !preferencesReadFailed { errorMessage = nil }
            message = isAutomatic ? "自动轮换中；\(playlist.count) 个可用航拍。" : "\(playlist.count) 个可用航拍；当前暂停。"
            if !environmentReady || playlist.isEmpty { pause() }
        } catch {
            preparedOwnedSession = false
            applyDiagnostics(await switcher.diagnostics())
            environmentReady = false
            pause()
            errorMessage = readableError(error)
            message = "环境检查未通过。"
        }
    }

    func toggleAutomatic() {
        if isAutomatic { pause(); message = "已暂停，当前壁纸保持。"; return }
        guard canSwitch else { return }
        startupResumePending = false
        startAutomatic(restoring: false)
    }

    private func resumeAfterLaunchIfRequested() {
        guard startupResumePending else { return }
        startupResumePending = false
        guard rotationRequested, !isAutomatic else { return }
        guard canSwitch, preparedOwnedSession else {
            pause()
            if errorMessage == nil { message = "上次轮换记录或环境无法确认，已暂停。请检查后手动开始。" }
            return
        }
        startAutomatic(restoring: true)
    }

    private func startAutomatic(restoring: Bool) {
        isAutomatic = true
        guard scheduler.begin(intervalSeconds: TimeInterval(intervalMinutes) * 60, onDue: { [weak self] in
            self?.queueAutomaticNext()
        }) else { pause(); errorMessage = "切换间隔无效。"; return }
        rotationRequested = true
        guard persistPreferences() else { return }
        if restoring {
            message = "已恢复自动轮换，等待完整间隔后切换。"
        } else {
            queueAutomaticNext()
        }
    }

    private func queueAutomaticNext() {
        guard isAutomatic, !isSwitching, !isReplaying else { return }
        let generation = automaticGeneration
        Task { await next(manual: false, generation: generation) }
    }

    func pause() {
        startupResumePending = false
        rotationRequested = false
        stopRuntime()
        if !preferencesReadFailed { persistPreferences() }
    }

    /// Quitting/logging out stops this process without clearing the saved intent.
    func stopForTermination() {
        isTerminating = true
        startupResumePending = false
        stopReplay(updateMessage: false)
        stopRuntime()
    }

    private func stopRuntime() {
        automaticGeneration &+= 1
        scheduler.pause()
        isAutomatic = false
        nextDue = nil
    }

    func next(manual: Bool = true, generation: UInt64? = nil) async {
        if !manual {
            guard isAutomatic, !isReplaying, scheduler.status == .running, generation == automaticGeneration else { return }
        }
        guard canSwitch else { return }
        if manual { automaticGeneration &+= 1 }
        let eligible = playlist.filter { $0.assetID != currentAssetID }
        guard let asset = eligible.randomElement() else {
            message = "当前已是池中唯一可用航拍。"
            if isAutomatic { scheduler.resetCountdown() }
            return
        }
        // Start the target as soon as its frame is ready. Native synchronization
        // follows behind the moving desktop surface, without a first-frame hold.
        replayGeneration &+= 1
        let playbackGeneration = replayGeneration
        isSwitching = true
        errorMessage = nil
        message = "正在准备\(asset.localizedName)…"
        defer { isSwitching = false }
        do {
            guard let url = asset.localVideoURL else { throw NativeAerialSwitcherError.invalidAsset(asset.assetID) }
            try await desktopReplay.prepare(url: url)
            guard !isTerminating, playbackGeneration == replayGeneration else { return }
            try desktopReplay.playPrepared(url: url)
            guard !isTerminating, playbackGeneration == replayGeneration else { return }
            if isAutomatic { scheduler.resetCountdown() }
        } catch is CancellationError {
            if playbackGeneration == replayGeneration { stopReplay(updateMessage: true) }
            return
        } catch {
            guard !isTerminating, playbackGeneration == replayGeneration else { return }
            stopReplay(updateMessage: false)
            pause()
            errorMessage = error.localizedDescription
            message = "视频未能开始播放，壁纸未切换。"
            return
        }
        message = "正在播放\(asset.localizedName)，正在同步系统壁纸…"
        do {
            let result = try await switcher.switch(assetID: asset.assetID)
            guard !isTerminating else { return }
            guard result.nativeProviderVerified else { throw ControllerError.nativeLoadNotVerified }
            currentAssetID = asset.assetID
            nativeSelectionID = asset.assetID
            currentName = asset.localizedName
            canRestore = await switcher.canRestore
        } catch {
            guard !isTerminating else { return }
            stopReplay(updateMessage: false)
            pause()
            let diagnostic = await switcher.diagnostics()
            applyDiagnostics(diagnostic)
            errorMessage = readableError(error)
            message = "切换失败，已暂停。"
            return
        }
        guard playbackGeneration == replayGeneration else {
            message = "壁纸已切换；桌面播放已取消。"
            return
        }
        await playCurrentAerial(assetID: asset.assetID, generation: playbackGeneration, afterSwitch: true)
    }

    func restore() async {
        guard !isSwitching, !isLoading, canRestore else { return }
        stopReplay(updateMessage: false)
        pause()
        isSwitching = true
        errorMessage = nil
        defer { isSwitching = false }
        do {
            let result = try await switcher.restore()
            guard result.selectionRestored else { throw ControllerError.restoreNotVerified }
            applyDiagnostics(await switcher.diagnostics())
            message = result.nativeProviderVerified ? "已恢复接管前设置，自动轮换保持暂停。" : "原设置已恢复；原生资源加载尚未确认。"
        } catch {
            applyDiagnostics(await switcher.diagnostics())
            errorMessage = readableError(error)
            message = "恢复未完成；已停止写入。"
        }
    }

    func adoptCurrentSettings() async {
        guard !isSwitching, !isLoading else { return }
        stopReplay(updateMessage: false)
        pause()
        isLoading = true
        defer { isLoading = false }
        do {
            let diagnostic = try await switcher.adoptCurrentSettings()
            applyDiagnostics(diagnostic)
            environmentReady = diagnostic.isPrepared && !diagnostic.externalChangeDetected
            errorMessage = nil
            message = "已接管当前设置；仍为暂停状态。"
        } catch { environmentReady = false; errorMessage = readableError(error) }
    }

    private func applyDiagnostics(_ diagnostic: NativeAerialSwitcherDiagnostics) {
        nativeSelectionID = diagnostic.currentAssetID
        canRestore = diagnostic.canRestore
        externalChangeDetected = diagnostic.externalChangeDetected
        if diagnostic.externalChangeDetected { environmentReady = false }
        let fixedID = diagnostic.currentAssetID.flatMap { value in catalog?.assets.contains { $0.assetID == value } == true ? value : nil }
        let id = fixedID ?? diagnostic.nativeMovieIDs.first ?? diagnostic.currentAssetID
        currentAssetID = id
        currentName = catalog?.assets.first { $0.assetID == id }?.localizedName ?? "系统当前航拍"
    }

    private func readableError(_ error: Error) -> String {
        if let native = error as? NativeAerialSwitcherError {
            switch native {
            case .busy: return "已有切换操作正在进行，请稍候。"
            case .unsupportedScope: return "当前版本支持单个内建显示器和系统原生航拍配置。请检查墙纸设置后刷新资源。"
            case .invalidAsset: return "目标航拍暂不可用，请刷新资源后重试。"
            case .concurrentSettingsChange: return "系统壁纸设置发生变化，已暂停以保护你的选择。可重新接管当前设置。"
            case .unsafeProcess, .commandFailed: return "原生壁纸服务检查失败，已暂停。请稍后刷新并重试。"
            case .rendererVerificationFailed: return "未能确认原生航拍加载，已暂停；请检查当前壁纸。"
            }
        }
        if let controller = error as? ControllerError {
            switch controller {
            case .nativeLoadNotVerified: return "未能确认原生航拍加载，已暂停。"
            case .restoreNotVerified: return "恢复结果未能确认；已停止写入，请检查当前壁纸。"
            }
        }
        let diagnostic = String(describing: error)
        if diagnostic.localizedCaseInsensitiveContains("external") || diagnostic.localizedCaseInsensitiveContains("changed") {
            return "系统壁纸设置发生变化，已暂停以保护你的选择。可重新接管当前设置。"
        }
        return diagnostic
    }
}

private enum ControllerError: Error {
    case nativeLoadNotVerified, restoreNotVerified
}
