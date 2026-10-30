import AppKit
import Foundation

/// Starts and ends an awake session automatically while any bundle id in
/// `config.agentList` is running, so a closed lid never cuts off a remote
/// session (Hermes over SSH, for example).
///
/// It only decides *when* a session exists. Everything else stays with the
/// existing machinery: the start is the same journal-first transaction the
/// menu uses, and the battery, thermal and timer rules end the session exactly
/// as they do for one the user started.
///
/// A session this class started is an *auto session*. If the user ends one by
/// hand, auto-hold pauses until an agent app next launches or quits, so the
/// app never fights the person using it.
@MainActor
final class AgentAutoHold {
    private let manager: SessionManager
    private var observers: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?
    /// True while the session on screen was started by this class.
    private var autoStarted = false
    /// Set when an auto session vanished without this class ending it (the
    /// user ended it, or the timer/battery floors did). Cleared when the set of
    /// running agent apps changes.
    private var paused = false
    private var evaluating = false

    init(manager: SessionManager) {
        self.manager = manager
    }

    /// Watch app launches and terminations, with a slow poll as a safety net
    /// for missed notifications (and for a session ended by its own timer).
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.paused = false
                    await self?.evaluate()
                }
            })
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.evaluate()
                try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
            }
        }
        Log.info("auto-hold: watching agent apps")
    }

    /// One evaluation pass. Cheap and idempotent; overlapping calls are dropped.
    func evaluate() async {
        guard !evaluating else { return }
        evaluating = true
        defer { evaluating = false }

        let config = manager.config

        guard config.autoHoldWhileAgentsRun else {
            if autoStarted, manager.isActive {
                let outcome = await manager.end(reason: .agentsGone)
                Log.info("auto-hold: ended, feature turned off (\(outcome))")
            }
            autoStarted = false
            paused = false
            return
        }

        let running = agentsRunning(in: config.agentList)

        if !running {
            if autoStarted, manager.isActive {
                let outcome = await manager.end(reason: .agentsGone)
                Log.info("auto-hold: ended, no agent app running (\(outcome))")
            }
            if !manager.isActive {
                autoStarted = false
            }
            return
        }

        // An agent app is running.
        guard !manager.isActive else { return }

        if autoStarted {
            // The session we started is gone but the app is still running: the
            // user ended it, or a floor did. Do not immediately restart it.
            autoStarted = false
            paused = true
            Log.info("auto-hold: paused, session ended outside auto-hold")
            return
        }

        guard !paused else { return }

        await manager.start(duration: config.maxDuration)
        autoStarted = manager.isActive
        if autoStarted {
            Log.info("auto-hold: session started, agent app running")
        } else {
            Log.error("auto-hold: start did not take")
        }
    }

    private func agentsRunning(in agentList: [String]) -> Bool {
        let ids = Set(agentList.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard !ids.isEmpty else { return false }
        return NSWorkspace.shared.runningApplications.contains { app in
            guard !app.isTerminated, let id = app.bundleIdentifier else { return false }
            return ids.contains(id)
        }
    }
}
