//
//  HorizontalScrollPageDetector.swift
//  claudeNotch
//
//  Detects horizontal-dominant trackpad swipes for page navigation.
//  NEVER consumes events — always returns them so other monitors are unaffected.
//  Safe to run alongside PanGesture.swift's vertical monitor.
//

import AppKit

/// Watches for horizontally-dominant scroll wheel events and fires a page-change callback.
///
/// Safety: PanGesture.swift handles events where abs(deltaY) > abs(deltaX)*1.5.
/// This class handles events where abs(deltaX) > abs(deltaY)*1.5.
/// These two conditions are mutually exclusive — zero interference.
@MainActor
final class HorizontalScrollPageDetector {

    /// Called with +1 (swipe left → next page) or -1 (swipe right → prev page).
    var onPageChange: ((Int) -> Void)?

    private var monitor: Any?
    private var accumulated: CGFloat = 0
    private var fired = false
    private let triggerThreshold: CGFloat = 30
    private let axisDominanceFactor: CGFloat = 1.5

    // MARK: - Lifecycle

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            self?.handleEvent(event)
            return event  // ALWAYS return — never consume
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        reset()
    }

    // MARK: - Event handling

    private func handleEvent(_ event: NSEvent) {
        if event.phase == .ended || event.momentumPhase == .ended {
            reset(); return
        }

        let absDX = abs(event.scrollingDeltaX)
        let absDY = abs(event.scrollingDeltaY)

        // Only handle horizontal-dominant events
        guard absDX >= axisDominanceFactor * absDY, absDX > 0.1 else { return }

        // Scale mouse wheel to match trackpad feel
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        accumulated += event.scrollingDeltaX * scale

        guard !fired, abs(accumulated) >= triggerThreshold else { return }
        fired = true
        // deltaX > 0 = finger right = go to prev page; deltaX < 0 = finger left = go to next page
        onPageChange?(accumulated > 0 ? -1 : 1)
    }

    private func reset() {
        accumulated = 0
        fired = false
    }
}
