//
//  MotionPolicy.swift
//  claudeNotch
//
//  Decides when the notch may animate or tick, so it stays near zero redraws when idle.
//

import AppKit
import Combine
import SwiftUI

/// App-wide answer to "may anything move or tick right now?".
/// Decorative animations (face blink, marquee) stop when Reduce Motion or Low Power Mode is on,
/// and everything that ticks pauses while the displays sleep or the screen is locked.
@MainActor
final class MotionPolicy: ObservableObject {
    static let shared = MotionPolicy()

    @Published private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var displaysAsleep = false
    @Published private(set) var screenLocked = false

    /// Nobody can see the notch: displays asleep or screen locked.
    var isDisplayInactive: Bool { displaysAsleep || screenLocked }

    /// Purely decorative motion (blinking face, scrolling text).
    var allowsDecorativeAnimation: Bool { !reduceMotion && !lowPowerMode && !isDisplayInactive }

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { p in
            p.set(\.reduceMotion, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.set(\.displaysAsleep, true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.set(\.displaysAsleep, false) }
        observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) { p in
            p.set(\.lowPowerMode, ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.set(\.screenLocked, true) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.set(\.screenLocked, false) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ apply: @escaping @MainActor (MotionPolicy) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                apply(self)
            }
        }
        observers.append((center, token))
    }

    /// Assign only on change, so observers are not woken by equal values.
    private func set(_ keyPath: ReferenceWritableKeyPath<MotionPolicy, Bool>, _ value: Bool) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

/// When a countdown to `date` next shows a different value, so views redraw only then
/// (instead of every second regardless of what is shown).
enum CountdownTick {
    /// - Parameter showsSeconds: whether the text shows seconds when under an hour away (MM:SS).
    /// - Returns: seconds to wait, or nil once the date has passed (nothing will change any more).
    static func delay(until date: Date?, showsSeconds: Bool = true, now: Date = Date()) -> TimeInterval? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return nil }
        let step: TimeInterval = (showsSeconds && interval < 3600) ? 1 : 60
        let untilChange = interval.truncatingRemainder(dividingBy: step)
        return max(untilChange, 0.05) + 0.02
    }
}

extension View {
    /// Calls `update` on appear and then only when a countdown to `date` changes what it shows.
    /// The loop belongs to the view: it ends when the view disappears or `date` changes.
    /// While the displays sleep or the screen is locked it waits instead of ticking.
    func countdownTicks(until date: Date?, showsSeconds: Bool = true, _ update: @escaping @MainActor () -> Void) -> some View {
        task(id: date) {
            update()
            while !Task.isCancelled {
                guard let delay = CountdownTick.delay(until: date, showsSeconds: showsSeconds) else {
                    update()  // show the final "Now"/"soon" state, then stop
                    return
                }
                try? await Task.sleep(for: .seconds(delay))
                while !Task.isCancelled && MotionPolicy.shared.isDisplayInactive {
                    try? await Task.sleep(for: .seconds(5))
                }
                guard !Task.isCancelled else { return }
                update()
            }
        }
    }
}
