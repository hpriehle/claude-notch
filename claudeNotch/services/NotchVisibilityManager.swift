//
//  NotchVisibilityManager.swift
//  claudeNotch
//
//  Created by Harrison Riehle on 2026. 03. 20..
//

import Defaults
import Foundation

@MainActor
class NotchVisibilityManager: ObservableObject {
    static let shared = NotchVisibilityManager()

    @Published var isNotchHidden: Bool = false

    private var unhideTask: Task<Void, Never>?

    private init() {}

    /// Hide the notch indefinitely
    func hideIndefinitely() {
        unhideTask?.cancel()
        unhideTask = nil
        isNotchHidden = true

        // Ensure menu bar icon is enabled so the user can unhide
        if !Defaults[.menubarIcon] {
            Defaults[.menubarIcon] = true
        }

        hideAllWindows()
    }

    /// Hide the notch for a specific duration
    func hide(for duration: TimeInterval) {
        unhideTask?.cancel()
        isNotchHidden = true
        hideAllWindows()

        unhideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.showNotch()
        }
    }

    /// Hide until a specific date (e.g., 8am)
    func hide(until date: Date) {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return }
        hide(for: interval)
    }

    /// Hide until 8am (today if before 8am, tomorrow if after)
    func hideTillMorning() {
        let calendar = Calendar.current
        let now = Date()
        var target = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: now)!

        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target)!
        }

        hide(until: target)
    }

    /// Show the notch (unhide)
    func showNotch() {
        unhideTask?.cancel()
        unhideTask = nil
        isNotchHidden = false
        showAllWindows()
    }

    // MARK: - Window management via notifications

    private func hideAllWindows() {
        NotificationCenter.default.post(name: .notchShouldHide, object: nil)
    }

    private func showAllWindows() {
        NotificationCenter.default.post(name: .notchShouldShow, object: nil)
    }
}
