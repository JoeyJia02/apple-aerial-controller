import AppKit
import AVFoundation
import CoreGraphics

/// The first frame is prepared and displayed before a caller reloads Apple's
/// wallpaper behind this app-owned desktop window. Playback runs to natural end.
@MainActor
final class DesktopReplayController {
    enum State: Equatable, Sendable {
        case idle, preparing, prepared, playing, paused, holding
        case failed(String)

        var name: String {
            switch self {
            case .idle: "idle"
            case .preparing: "preparing"
            case .prepared: "prepared"
            case .playing: "playing"
            case .paused: "paused"
            case .holding: "holding"
            case .failed: "failed"
            }
        }
    }

    struct Diagnostics: Codable, Sendable {
        let state: String
        let windowVisible: Bool
        let playerTime: Double?
        let rate: Float?
        let readyForDisplay: Bool
        let level: Int?
        let key: Bool
        let main: Bool
        let ignoresMouseEvents: Bool
        let url: URL?
        let playerAttached: Bool
        let generation: UInt64
        let failure: String?
        let duration: Double?
        let heldAtEnd: Bool
    }

    enum ReplayError: LocalizedError {
        case requiresSingleBuiltInDisplay
        case invalidLocalFile
        case unsupportedWindowLevels
        case loadingTimedOut
        case seekFailed
        case prerollFailed
        case notPrepared
        case notPlaying
        case notPaused
        case playbackAlreadyEnded
        case preparedSourceMismatch
        case preservedFailure(String)
        case mediaFailed(String)
        case playbackStalled

        var errorDescription: String? {
            switch self {
            case .requiresSingleBuiltInDisplay: "重新播放暂时只支持单个内建显示屏。"
            case .invalidLocalFile: "找不到可读取的本地航拍视频。"
            case .unsupportedWindowLevels: "当前系统的桌面窗口层级不受支持。"
            case .loadingTimedOut: "航拍视频未能在 8 秒内准备好。"
            case .seekFailed: "无法从航拍视频开头重新播放。"
            case .prerollFailed: "航拍视频播放准备失败。"
            case .notPrepared: "航拍视频尚未准备好，或播放准备已取消。"
            case .notPlaying: "当前没有正在播放的航拍视频。"
            case .notPaused: "当前没有可以继续播放的已暂停航拍。"
            case .playbackAlreadyEnded: "当前航拍已完整播放，请使用重新播放。"
            case .preparedSourceMismatch: "待播放视频与已准备的视频不一致。"
            case .preservedFailure(let message): message
            case .mediaFailed(let message): "航拍视频播放失败：\(message)"
            case .playbackStalled: "航拍视频连续 30 秒没有播放进展，已恢复系统桌面。"
            }
        }
    }

    private(set) var state: State = .idle
    var onStateChange: (@MainActor (State) -> Void)?

    var diagnostics: Diagnostics {
        let session = visibleSession ?? preparingSession
        let seconds = session.map { CMTimeGetSeconds($0.player.currentTime()) }
        let duration = session.map { CMTimeGetSeconds($0.item.duration) }
        let failure: String?
        if case .failed(let message) = state { failure = message } else { failure = nil }
        return Diagnostics(
            state: state.name,
            windowVisible: window?.isVisible ?? false,
            playerTime: seconds.flatMap { $0.isFinite ? $0 : nil },
            rate: session?.player.rate,
            readyForDisplay: session?.layer.isReadyForDisplay ?? false,
            level: window?.level.rawValue,
            key: window?.isKeyWindow ?? false,
            main: window?.isMainWindow ?? false,
            ignoresMouseEvents: window?.ignoresMouseEvents ?? false,
            url: session?.url,
            playerAttached: session?.layer.player != nil && session?.player.currentItem != nil,
            generation: generation,
            failure: failure,
            duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            heldAtEnd: state == .holding && session?.completedToEnd == true
        )
    }

    private var generation: UInt64 = 0
    private var window: DesktopReplayWindow?
    private var visibleSession: DesktopReplaySession?
    private var preparingSession: DesktopReplaySession?
    // Keep the old layer underneath until the new player advances. At most two
    // players/layers are retained; preparing a third releases the oldest first.
    private var retiringSession: DesktopReplaySession?
    private var lifetimeObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var playbackMonitor: Task<Void, Never>?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            observeStop(name, center: center)
        }
        observeStop(NSApplication.didChangeScreenParametersNotification,
                    center: NotificationCenter.default)
    }

    isolated deinit {
        releaseCurrentResources()
        for (center, observer) in lifetimeObservers { center.removeObserver(observer) }
    }

    /// Returns with the replacement's first frame visible and paused at zero.
    /// Keeps the existing frame visible while decoding the replacement.
    /// Performs no native wallpaper configuration writes or provider reloads.
    func prepare(url: URL) async throws {
        generation &+= 1
        let token = generation
        playbackMonitor?.cancel()
        playbackMonitor = nil
        preparingSession?.release()
        preparingSession = nil
        releaseRetiringSession()
        visibleSession?.player.pause()

        do {
            try ensureCurrent(token)
            guard NSScreen.screens.count == 1,
                  let screen = NSScreen.screens.first,
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDisplayIsBuiltin(number.uint32Value) != 0 else {
                throw ReplayError.requiresSingleBuiltInDisplay
            }
            let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow)) + 1
            guard desktopLevel < Int(CGWindowLevelForKey(.desktopIconWindow)) else {
                throw ReplayError.unsupportedWindowLevels
            }
            let localURL = canonicalURL(url)
            guard url.isFileURL,
                  FileManager.default.isReadableFile(atPath: localURL.path),
                  let values = try? localURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw ReplayError.invalidLocalFile
            }

            let window = desktopWindow(screen: screen, level: desktopLevel)
            let session = DesktopReplaySession(url: localURL, token: token)
            session.layer.frame = window.contentView?.bounds ?? .zero
            session.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            session.layer.videoGravity = .resizeAspectFill
            session.layer.opacity = 0
            window.contentView?.layer?.addSublayer(session.layer)
            preparingSession = session
            installMediaObservers(session: session)
            publish(.preparing)
            try ensureCurrent(token)

            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            try await wait(session: session, deadline: deadline) {
                session.item.status == .readyToPlay && session.player.status == .readyToPlay
            }
            session.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) {
                [weak self, weak session] finished in
                Task { @MainActor [weak self, weak session] in
                    guard let self, let session, self.isCurrent(session) else { return }
                    session.seekFinished = finished
                }
            }
            try await wait(session: session, deadline: deadline) { session.seekFinished != nil }
            guard session.seekFinished == true else { throw ReplayError.seekFailed }

            guard session.player.status == .readyToPlay, session.player.rate == 0 else {
                throw ReplayError.prerollFailed
            }
            session.player.preroll(atRate: 1) { [weak self, weak session] finished in
                Task { @MainActor [weak self, weak session] in
                    guard let self, let session, self.isCurrent(session) else { return }
                    session.prerollFinished = finished
                }
            }
            try await wait(session: session, deadline: deadline) { session.prerollFinished != nil }
            guard session.prerollFinished == true else { throw ReplayError.prerollFailed }
            try await wait(session: session, deadline: deadline) { session.layer.isReadyForDisplay }
            try checkPreparation(session)

            // Replace layers inside one persistent desktop window. Its transparent
            // backing cannot expose a blank black rectangle during the handoff.
            retiringSession = visibleSession
            visibleSession = session
            preparingSession = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            session.layer.opacity = 1
            CATransaction.commit()
            window.orderFront(nil)
            window.displayIfNeeded()
            CATransaction.flush()
            // Allow a display turn before the caller reloads WallpaperAgent.
            // This is a compositor handoff, never a screen capture.
            try await Task.sleep(for: .milliseconds(40))
            try checkPreparation(session)
            publish(.prepared)
            try ensureCurrent(token)
        } catch {
            if generation == token {
                generation &+= 1
                releaseCurrentResources()
                publish(error is CancellationError ? .idle : .failed(error.localizedDescription))
            }
            throw error
        }
    }

    /// Starts the displayed first frame immediately; native selection can follow.
    /// Does not seek, rebuild the window, or change the wallpaper store.
    func playPrepared(url: URL) throws {
        try Task.checkCancellation()
        guard state == .prepared, let session = visibleSession, isCurrent(session) else {
            throw ReplayError.notPrepared
        }
        guard url.isFileURL, canonicalURL(url) == session.url else {
            throw ReplayError.preparedSourceMismatch
        }
        try checkPreparation(session)
        guard session.player.rate == 0 else { throw ReplayError.notPrepared }
        session.lastProgressAt = ContinuousClock.now
        let seconds = CMTimeGetSeconds(session.player.currentTime())
        session.lastObservedMediaSeconds = seconds.isFinite ? seconds : nil
        session.player.play()
        publish(.playing)
        try ensureCurrent(session.token)
        installPlaybackMonitor(session: session)
    }

    /// Read-only confirmation after a native switch. A short video may already
    /// have ended; validating it must never seek, restart, or pause playback.
    func validateActiveSource(url: URL) throws {
        try Task.checkCancellation()
        try throwIfFailed()
        guard state == .playing || state == .paused || state == .holding else {
            throw ReplayError.notPrepared
        }
        let session = try validatedVisibleSession()
        guard url.isFileURL, canonicalURL(url) == session.url else {
            throw ReplayError.preparedSourceMismatch
        }
        if state == .holding, !session.completedToEnd { throw ReplayError.notPrepared }
    }

    /// Holds the current decoded frame without replacing the player or seeking.
    /// A natural end that races this request settles into holding, not paused.
    func pausePlayback() throws {
        try Task.checkCancellation()
        try throwIfFailed()
        guard state != .holding else { throw ReplayError.playbackAlreadyEnded }
        guard state == .playing else { throw ReplayError.notPlaying }
        let session = try validatedVisibleSession()
        session.player.pause()
        playbackMonitor?.cancel()
        playbackMonitor = nil
        if session.completedToEnd || hasReachedNaturalEnd(session) {
            holdLastFrame(session: session)
            return
        }
        publish(.paused)
        try ensureCurrent(session.token)
    }

    /// Continues the same player at its existing media time. A stopped, failed,
    /// or naturally completed session cannot be resumed through this method.
    func resumePlayback() throws {
        try Task.checkCancellation()
        try throwIfFailed()
        guard state != .holding else { throw ReplayError.playbackAlreadyEnded }
        guard state == .paused else { throw ReplayError.notPaused }
        let session = try validatedVisibleSession()
        if session.completedToEnd || hasReachedNaturalEnd(session) {
            holdLastFrame(session: session)
            return
        }
        session.lastProgressAt = ContinuousClock.now
        let seconds = CMTimeGetSeconds(session.player.currentTime())
        session.lastObservedMediaSeconds = seconds.isFinite ? seconds : nil
        session.player.play()
        publish(.playing)
        try ensureCurrent(session.token)
        installPlaybackMonitor(session: session)
    }

    private func throwIfFailed() throws {
        if case .failed(let message) = state { throw ReplayError.preservedFailure(message) }
    }

    private func validatedVisibleSession() throws -> DesktopReplaySession {
        guard let session = visibleSession, isCurrent(session),
              let window, window.isVisible,
              let hostLayer = window.contentView?.layer,
              session.layer.superlayer === hostLayer,
              session.layer.isReadyForDisplay,
              session.layer.player === session.player,
              session.player.currentItem === session.item else {
            throw ReplayError.notPrepared
        }
        try checkPreparation(session)
        return session
    }

    /// The end notification is authoritative. This exact-boundary check only
    /// reconciles its possible delivery delay while a zero-rate player is at the
    /// valid natural endpoint; no tolerance can cut off the final video frames.
    private func hasReachedNaturalEnd(_ session: DesktopReplaySession) -> Bool {
        guard session.player.rate == 0 else { return false }
        let current = session.player.currentTime()
        let duration = session.item.duration
        let seconds = CMTimeGetSeconds(current)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard current.isNumeric, duration.isNumeric,
              seconds.isFinite, durationSeconds.isFinite, durationSeconds > 0 else { return false }
        return CMTimeCompare(current, duration) >= 0
    }

    /// Convenience for replaying without a native configuration change.
    /// Sleep/session/Space changes clear prepared and visible frames. Public session
    /// notifications are not exact lock notifications; the lock UI covers this window.
    func start(url: URL) async throws {
        let token = generation &+ 1
        do {
            try await prepare(url: url)
            try ensureCurrent(token)
            try playPrepared(url: url)
        } catch {
            if generation == token {
                generation &+= 1
                releaseCurrentResources()
                publish(error is CancellationError ? .idle : .failed(error.localizedDescription))
            }
            throw error
        }
    }

    func stop() {
        generation &+= 1
        releaseCurrentResources()
        publish(.idle)
    }

    private func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func desktopWindow(screen: NSScreen, level: Int) -> DesktopReplayWindow {
        if let window { return window }
        let window = DesktopReplayWindow(contentRect: screen.frame, styleMask: .borderless,
                                         backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = NSWindow.Level(rawValue: level)
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = view
        self.window = window
        return window
    }

    private func wait(session: DesktopReplaySession, deadline: ContinuousClock.Instant,
                      until ready: @MainActor () -> Bool) async throws {
        while true {
            try checkPreparation(session)
            if ready() { return }
            if ContinuousClock.now >= deadline { throw ReplayError.loadingTimedOut }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    private func checkPreparation(_ session: DesktopReplaySession) throws {
        try ensureCurrent(session.token)
        guard isCurrent(session) else { throw CancellationError() }
        if let failure = session.pendingMediaFailure { throw ReplayError.mediaFailed(failure) }
        if session.item.status == .failed {
            throw ReplayError.mediaFailed(session.item.error?.localizedDescription ?? "未知错误")
        }
        if session.player.status == .failed {
            throw ReplayError.mediaFailed(session.player.error?.localizedDescription ?? "未知错误")
        }
    }

    private func ensureCurrent(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func isCurrent(_ session: DesktopReplaySession) -> Bool {
        generation == session.token && !session.isReleased &&
            (preparingSession === session || visibleSession === session)
    }

    private func installMediaObservers(session: DesktopReplaySession) {
        let center = NotificationCenter.default
        session.mediaObservers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                          object: session.item, queue: .main) {
            [weak self, weak session] _ in
            // queue: .main permits synchronous actor isolation, so an already
            // delivered natural end cannot sit behind a subsequent resume task.
            MainActor.assumeIsolated {
                guard let session else { return }
                self?.holdLastFrame(session: session)
            }
        })
        session.mediaObservers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                                          object: session.item, queue: .main) {
            [weak self, weak session] _ in
            Task { @MainActor [weak self, weak session] in
                guard let session else { return }
                self?.recordMediaFailure("未能完整播放此视频", session: session)
            }
        })
        session.itemStatusObservation = session.item.observe(\.status, options: [.new]) {
            [weak self, weak session] _, _ in
            Task { @MainActor [weak self, weak session] in
                guard let self, let session, self.isCurrent(session),
                      session.item.status == .failed else { return }
                self.recordMediaFailure(session.item.error?.localizedDescription ?? "未知错误",
                                        session: session)
            }
        }
    }

    private func recordMediaFailure(_ message: String, session: DesktopReplaySession) {
        guard isCurrent(session) else { return }
        session.pendingMediaFailure = message
        if state != .preparing { fail(.mediaFailed(message), token: session.token) }
    }

    private func holdLastFrame(session: DesktopReplaySession) {
        guard isCurrent(session), visibleSession === session,
              state == .playing || state == .paused else { return }
        session.player.pause()
        session.completedToEnd = true
        playbackMonitor?.cancel()
        playbackMonitor = nil
        releaseRetiringSession()
        publish(.holding)
    }

    private func installPlaybackMonitor(session: DesktopReplaySession) {
        playbackMonitor = Task { @MainActor [weak self, weak session] in
            while true {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let session,
                      self?.checkPlayback(session: session, now: ContinuousClock.now) == true else { return }
            }
        }
    }

    private func checkPlayback(session: DesktopReplaySession, now: ContinuousClock.Instant) -> Bool {
        guard isCurrent(session), visibleSession === session, state == .playing else { return false }
        if session.item.status == .failed {
            fail(.mediaFailed(session.item.error?.localizedDescription ?? "未知错误"), token: session.token)
            return false
        }
        if session.player.status == .failed {
            fail(.mediaFailed(session.player.error?.localizedDescription ?? "未知错误"), token: session.token)
            return false
        }
        let seconds = CMTimeGetSeconds(session.player.currentTime())
        if seconds.isFinite,
           session.lastObservedMediaSeconds.map({ seconds > $0 + 0.01 }) ?? true {
            session.lastObservedMediaSeconds = seconds
            session.lastProgressAt = now
            releaseRetiringSession()
        }
        // Duration is advisory. Only natural end enters holding; long or unknown
        // durations keep playing while media time continues to advance.
        if let lastProgressAt = session.lastProgressAt,
           now >= lastProgressAt.advanced(by: .seconds(30)) {
            fail(.playbackStalled, token: session.token)
            return false
        }
        return true
    }

    private func fail(_ error: ReplayError, token: UInt64) {
        guard generation == token else { return }
        generation &+= 1
        releaseCurrentResources()
        publish(.failed(error.localizedDescription))
    }

    private func observeStop(_ name: Notification.Name, center: NotificationCenter) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        }
        lifetimeObservers.append((center, observer))
    }

    private func releaseRetiringSession() {
        retiringSession?.release()
        retiringSession = nil
    }

    private func releaseCurrentResources() {
        playbackMonitor?.cancel()
        playbackMonitor = nil
        window?.orderOut(nil)
        preparingSession?.release()
        preparingSession = nil
        visibleSession?.release()
        visibleSession = nil
        releaseRetiringSession()
        window?.close()
        window = nil
    }

    private func publish(_ state: State) {
        self.state = state
        onStateChange?(state)
    }
}

@MainActor
private final class DesktopReplaySession {
    let url: URL
    let token: UInt64
    let item: AVPlayerItem
    let player: AVPlayer
    let layer: AVPlayerLayer
    var itemStatusObservation: NSKeyValueObservation?
    var mediaObservers: [NSObjectProtocol] = []
    var seekFinished: Bool?
    var prerollFinished: Bool?
    var pendingMediaFailure: String?
    var lastObservedMediaSeconds: Double?
    var lastProgressAt: ContinuousClock.Instant?
    var completedToEnd = false
    private(set) var isReleased = false

    init(url: URL, token: UInt64) {
        self.url = url
        self.token = token
        item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        layer = AVPlayerLayer(player: player)
        layer.backgroundColor = NSColor.clear.cgColor
    }

    isolated deinit { release() }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        for observer in mediaObservers { NotificationCenter.default.removeObserver(observer) }
        mediaObservers.removeAll()
        player.pause()
        player.cancelPendingPrerolls()
        item.cancelPendingSeeks()
        layer.player = nil
        player.replaceCurrentItem(with: nil)
        layer.removeFromSuperlayer()
    }
}

@MainActor
private final class DesktopReplayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

