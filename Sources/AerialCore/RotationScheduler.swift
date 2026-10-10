import Foundation
import AppKit

/// The production scheduling model. It never replays missed deadlines.
/// Saved UI preferences may supply an interval, but every new model is paused.
struct RotationDeadlineModel: Equatable, Sendable {
    enum Status: String, Sendable { case paused, running, sleeping }

    static let defaultInterval: TimeInterval = 15 * 60
    static let maximumInterval: TimeInterval = 365 * 24 * 60 * 60

    private(set) var status: Status = .paused
    private(set) var intervalSeconds: TimeInterval = Self.defaultInterval
    private(set) var nextDue: Date?
    private(set) var lastWake: Date?

    static func validInterval(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds >= 1 && seconds <= maximumInterval
    }

    @discardableResult
    mutating func begin(intervalSeconds: TimeInterval, now: Date) -> Bool {
        guard Self.validInterval(intervalSeconds) else { return false }
        self.intervalSeconds = intervalSeconds
        status = .running
        nextDue = now.addingTimeInterval(intervalSeconds)
        return true
    }

    mutating func pause() {
        status = .paused
        nextDue = nil
    }

    @discardableResult
    mutating func updateInterval(_ seconds: TimeInterval, now: Date) -> Bool {
        guard Self.validInterval(seconds) else { return false }
        intervalSeconds = seconds
        if status == .running { nextDue = now.addingTimeInterval(seconds) }
        return true
    }

    mutating func resetCountdown(now: Date) {
        guard status == .running else { return }
        nextDue = now.addingTimeInterval(intervalSeconds)
    }

    mutating func willSleep() {
        guard status == .running else { return }
        status = .sleeping
        nextDue = nil
    }

    mutating func didWake(now: Date) {
        lastWake = now
        guard status != .paused else { return }
        status = .running
        nextDue = now.addingTimeInterval(intervalSeconds)
    }

    /// A delayed awake callback is consumed once, then begins a full interval.
    /// Wake uses didWake above and cannot consume historical sleeping periods.
    @discardableResult
    mutating func consumeDue(now: Date) -> Bool {
        guard status == .running, let nextDue, now >= nextDue else { return false }
        self.nextDue = now.addingTimeInterval(intervalSeconds)
        return true
    }
}

/// Immutable observer ownership. NotificationCenter registration/removal is
/// thread safe; actual handlers below always execute on OperationQueue.main.
private final class WorkspaceObserver: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit { center.removeObserver(token) }
}

/// The run loop may retain its timer target; keep the scheduler reference weak.
@MainActor
private final class RotationTimerTarget: NSObject {
    weak var scheduler: RotationScheduler?

    init(scheduler: RotationScheduler) { self.scheduler = scheduler }

    @objc func fire(_ timer: Timer) {
        guard let scheduler else { timer.invalidate(); return }
        scheduler.timerFired(timer)
    }
}

/// One-shot native timer for the menu-bar controller. The caller starts its own
/// switching Task and may skip a due callback while a prior switch is busy.
/// There is no queue of missed targets and no immediate catch-up after wake.
@MainActor
final class RotationScheduler: NSObject {
    typealias Status = RotationDeadlineModel.Status

    var status: Status { model.status }
    var nextDue: Date? { model.nextDue }
    var lastWake: Date? { model.lastWake }
    var intervalSeconds: TimeInterval { model.intervalSeconds }
    var onStateChange: (@MainActor () -> Void)?

    private var model = RotationDeadlineModel()
    private var timer: Timer?
    private var onDue: (@MainActor () -> Void)?
    private var observers: [WorkspaceObserver] = []
    private lazy var timerTarget = RotationTimerTarget(scheduler: self)

    override init() {
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        let sleep = center.addObserver(forName: NSWorkspace.willSleepNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        }
        let wake = center.addObserver(forName: NSWorkspace.didWakeNotification,
                                      object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidWake() }
        }
        observers = [WorkspaceObserver(center: center, token: sleep),
                     WorkspaceObserver(center: center, token: wake)]
    }

    /// Returns false for invalid intervals without changing the current state.
    @discardableResult
    func begin(intervalSeconds: TimeInterval, onDue: @escaping @MainActor () -> Void) -> Bool {
        guard model.begin(intervalSeconds: intervalSeconds, now: Date()) else { return false }
        self.onDue = onDue
        armTimer()
        onStateChange?()
        return true
    }

    func pause() {
        model.pause()
        cancelTimer()
        onStateChange?()
    }

    /// Changing the interval while running starts a full new interval.
    /// While sleeping or paused it only updates the stored interval.
    @discardableResult
    func updateInterval(_ seconds: TimeInterval) -> Bool {
        guard model.updateInterval(seconds, now: Date()) else { return false }
        armTimer()
        onStateChange?()
        return true
    }

    /// Call after a successful manual Next so the old deadline cannot cause an
    /// automatic switch immediately afterward. Paused remains paused.
    func resetCountdown() {
        model.resetCountdown(now: Date())
        armTimer()
        onStateChange?()
    }

    private func handleWillSleep() {
        model.willSleep()
        cancelTimer()
        onStateChange?()
    }

    private func handleDidWake() {
        model.didWake(now: Date())
        armTimer()
        onStateChange?()
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func armTimer() {
        cancelTimer()
        guard status == .running, let deadline = nextDue else { return }
        let next = Timer(fireAt: deadline, interval: 0, target: timerTarget,
                         selector: #selector(RotationTimerTarget.fire(_:)), userInfo: nil, repeats: false)
        next.tolerance = min(1, intervalSeconds * 0.01)
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    fileprivate func timerFired(_ firedTimer: Timer) {
        // An invalidated pre-sleep/pre-reset callback must not trigger a target.
        guard timer === firedTimer else { return }
        guard model.consumeDue(now: Date()) else { armTimer(); return }
        armTimer()
        onDue?()
        onStateChange?()
    }
}
