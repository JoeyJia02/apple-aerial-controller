import Foundation

private enum SchedulerCheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SchedulerCheckFailure.failed(message) }
}

@main
private struct SchedulerChecks {
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        for seconds: TimeInterval in [900, 1800, 3600] {
            var model = RotationDeadlineModel()
            try check(model.begin(intervalSeconds: seconds, now: start), "valid interval rejected")
            let firstDue = start.addingTimeInterval(seconds)
            try check(model.nextDue == firstDue, "incorrect \(seconds)-second first deadline")
            try check(!model.consumeDue(now: firstDue.addingTimeInterval(-1)), "fired before deadline")
            try check(model.consumeDue(now: firstDue), "did not fire at deadline")
            try check(!model.consumeDue(now: firstDue), "repeated immediate callback")
            try check(model.nextDue == firstDue.addingTimeInterval(seconds), "did not restart full interval")
            print("PASS \(Int(seconds / 60)) minutes: deadline and one callback")
        }

        var sleeping = RotationDeadlineModel()
        sleeping.begin(intervalSeconds: 60, now: start)
        sleeping.willSleep()
        try check(sleeping.status == .sleeping && sleeping.nextDue == nil, "sleep retained old deadline")
        let wake = start.addingTimeInterval(301)
        try check(!sleeping.consumeDue(now: wake), "sleep consumed historical periods")
        sleeping.didWake(now: wake)
        try check(sleeping.status == .running && sleeping.lastWake == wake, "wake state not updated")
        try check(sleeping.nextDue == wake.addingTimeInterval(60), "wake did not restart full interval")
        try check(!sleeping.consumeDue(now: wake), "immediate wake catch-up")
        try check(!sleeping.consumeDue(now: wake.addingTimeInterval(59)), "wake period shortened")
        print("PASS sleep: five missed periods discarded; wake waits a full interval")

        var lateAwake = RotationDeadlineModel()
        lateAwake.begin(intervalSeconds: 60, now: start)
        try check(lateAwake.consumeDue(now: wake), "late awake callback not consumed")
        try check(!lateAwake.consumeDue(now: wake), "late awake callback caused a burst")
        try check(lateAwake.nextDue == wake.addingTimeInterval(60), "late callback replayed old slots")
        print("PASS delayed awake event: no callback burst or old-slot replay")

        sleeping.willSleep()
        sleeping.pause()
        sleeping.didWake(now: wake.addingTimeInterval(100))
        try check(sleeping.status == .paused && sleeping.nextDue == nil, "wake resumed paused scheduler")
        try check(!sleeping.consumeDue(now: wake.addingTimeInterval(10_000)), "paused scheduler fired")
        print("PASS pause during sleep: wake cannot restart it")

        var manual = RotationDeadlineModel()
        manual.begin(intervalSeconds: 900, now: start)
        let manualCompleted = start.addingTimeInterval(899)
        manual.resetCountdown(now: manualCompleted)
        try check(manual.nextDue == manualCompleted.addingTimeInterval(900), "manual Next did not reset countdown")
        try check(!manual.consumeDue(now: start.addingTimeInterval(900)), "old automatic deadline flashed after manual Next")
        manual.updateInterval(1800, now: start.addingTimeInterval(1000))
        try check(manual.nextDue == start.addingTimeInterval(2800), "running interval edit did not restart period")
        manual.willSleep()
        manual.updateInterval(3600, now: start.addingTimeInterval(1100))
        try check(manual.status == .sleeping && manual.nextDue == nil, "interval edit woke scheduler")
        manual.didWake(now: start.addingTimeInterval(2000))
        try check(manual.nextDue == start.addingTimeInterval(5600), "wake did not use edited interval")
        print("PASS manual Next and interval edits: full fresh countdown, no old deadline")

        var restarted = RotationDeadlineModel()
        restarted.updateInterval(1800, now: wake)
        try check(restarted.status == .paused && restarted.nextDue == nil, "loading UI interval resumed historical deadline")
        restarted.resetCountdown(now: wake)
        try check(restarted.status == .paused && restarted.nextDue == nil, "manual reset resumed paused scheduler")
        let unchanged = restarted
        for invalid in [-1.0, 0, .nan, .infinity, RotationDeadlineModel.maximumInterval + 1] {
            try check(!restarted.begin(intervalSeconds: invalid, now: wake), "invalid begin accepted")
            try check(!restarted.updateInterval(invalid, now: wake), "invalid update accepted")
            try check(restarted == unchanged, "invalid input changed state")
        }
        print("PASS restart is paused; invalid preferences do not change scheduling state")
        print("All production-model checks passed. No real system sleep or wallpaper writes were performed.")
    }
}
