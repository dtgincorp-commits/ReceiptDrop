import BackgroundTasks
import Foundation

/// Reads receipts the user parked with the share extension's "Save for
/// Later", overnight, so a batch of photos does not spend AI credits or
/// network the moment they are shared.
///
/// What iOS actually promises here is worth being precise about, because the
/// feature's name over-promises: `BGProcessingTask` is *scheduled*, not
/// guaranteed. The system decides when — typically overnight while charging,
/// which is why `earliestBeginDate` targets the small hours — but it may run
/// hours late, may skip a night, and never runs at all if the user has
/// force-quit the app. That is why held entries also have a grace period
/// after which the foreground path takes them anyway
/// (`QueueEntry.heldLongEnoughToForce`): this service is the preferred route,
/// not the only one.
enum OvernightProcessingService {
    /// Must match BGTaskSchedulerPermittedIdentifiers in project.yml — iOS
    /// throws on registration if the identifier is not declared there, and
    /// project.yml is the source of truth because xcodegen regenerates
    /// Info.plist and silently drops anything not declared in it.
    static let taskIdentifier = "com.datatechnologygroup.receipts4tax.overnight"

    /// Registers the handler. Must be called before the app finishes
    /// launching — `BGTaskScheduler` rejects a late registration — so this
    /// belongs in `ReceiptDropApp.init`, not in a view's `onAppear`.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier, using: nil
        ) { task in
            handle(task)
        }
    }

    /// Asks for a run in the next quiet window. Cheap and idempotent —
    /// submitting again simply replaces the pending request — so it is safe
    /// to call on every background transition rather than tracking whether a
    /// request is already outstanding.
    static func scheduleIfNeeded() {
        let held = SubmissionStore.loadQueue().filter { $0.isPending && $0.isHeld }
        guard !held.isEmpty else {
            // Nothing waiting: cancel rather than leave a request that would
            // wake the app to do nothing.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            return
        }

        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        // Extraction is a network round-trip to the user's AI provider, so a
        // run without connectivity would just fail every entry and burn the
        // scheduling opportunity.
        request.requiresNetworkConnectivity = true
        // Deliberately NOT requiring external power. It makes a run more
        // likely to be granted, but a user who does not charge overnight
        // would never get one at all — and the work is a handful of HTTP
        // requests, not a library sweep.
        request.requiresExternalPower = false
        request.earliestBeginDate = nextQuietWindow()

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Submission fails on simulators and when the user has disabled
            // Background App Refresh. Not worth surfacing: the grace period
            // means those receipts still get read, just on foreground.
        }
    }

    /// 2am tomorrow, or 2am today if it has not happened yet.
    ///
    /// A time rather than an interval, because "overnight" is what the user
    /// asked for and an interval would drift into the middle of the day.
    static func nextQuietWindow(from now: Date = Date(),
                                calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 2
        components.minute = 0
        guard let todayAt2 = calendar.date(from: components) else {
            return now.addingTimeInterval(6 * 60 * 60)
        }
        return todayAt2 > now ? todayAt2 : todayAt2.addingTimeInterval(24 * 60 * 60)
    }

    private static func handle(_ task: BGTask) {
        // Reschedule first: the next run is only ever requested from a
        // previous one or from backgrounding, and an early return below would
        // otherwise end the chain silently.
        scheduleIfNeeded()

        // iOS calls this when it is about to reclaim the time. Whatever has
        // finished stays saved — each receipt is committed as it completes —
        // and whatever has not stays in the queue for the next run.
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        PendingSubmissionProcessor.processAllPending {
            task.setTaskCompleted(success: true)
        }
    }
}
