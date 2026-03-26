//
//  ClaudeStatusService.swift
//  claudeNotch
//
//  Created by Harrison Riehle on 2026. 03. 23..
//

import Foundation
import SwiftUI
import UserNotifications
import Defaults

/// Monitors Claude service health by polling the public Statuspage.io API.
class ClaudeStatusService: ObservableObject {
    static let shared = ClaudeStatusService()

    // MARK: - Published State

    @Published private(set) var currentStatus: ClaudeServiceSnapshot = .unknown
    @Published private(set) var isLoaded: Bool = false

    // MARK: - Private

    private let statusURL = URL(string: "https://status.claude.com/api/v2/summary.json")!
    private let refreshInterval: TimeInterval = 150 // 2.5 minutes
    private var timer: Timer?
    private var lastStatus: ClaudeServiceSnapshot?
    private var isFirstFetch: Bool = true

    private static let claudeAPIComponentName = "Claude API"
    private static let claudeCodeComponentName = "Claude Code"

    // MARK: - Init

    private init() {
        Task { await fetchStatus() }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { await self?.fetchStatus() }
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Public

    func refresh() {
        Task { await fetchStatus() }
    }

    // MARK: - Fetch

    private func fetchStatus() async {
        var request = URLRequest(url: statusURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[ClaudeStatusService] No HTTP response")
                return
            }

            guard httpResponse.statusCode == 200 else {
                print("[ClaudeStatusService] HTTP \(httpResponse.statusCode)")
                return
            }

            let decoder = JSONDecoder()
            let summary: StatusPageSummary
            do {
                summary = try decoder.decode(StatusPageSummary.self, from: data)
            } catch {
                let preview = String(data: data.prefix(500), encoding: .utf8) ?? "nil"
                print("[ClaudeStatusService] Decode error: \(error)")
                print("[ClaudeStatusService] Response preview: \(preview)")
                throw error
            }

            let componentNames = summary.components.map { $0.name }
            print("[ClaudeStatusService] Components: \(componentNames)")

            let apiComponent = summary.components.first { $0.name.hasPrefix(Self.claudeAPIComponentName) }
            let codeComponent = summary.components.first { $0.name.hasPrefix(Self.claudeCodeComponentName) }

            // Fall back to overall indicator if specific components not found
            let overallLevel = ServiceHealthLevel.fromIndicator(summary.status.indicator)
            let apiStatus = apiComponent.map { ServiceHealthLevel.from(statusString: $0.status) } ?? overallLevel
            let codeStatus = codeComponent.map { ServiceHealthLevel.from(statusString: $0.status) } ?? overallLevel

            if apiComponent == nil || codeComponent == nil {
                print("[ClaudeStatusService] Component not found — api: \(apiComponent != nil), code: \(codeComponent != nil). Using overall: \(summary.status.indicator)")
            }

            let snapshot = ClaudeServiceSnapshot(
                apiStatus: apiStatus,
                codeStatus: codeStatus,
                overallDescription: summary.status.description,
                activeIncidents: summary.incidents,
                statusPageURL: URL(string: "https://status.claude.com")!,
                fetchedAt: Date()
            )

            let previousWorst = lastStatus?.worstRelevantStatus
            lastStatus = snapshot

            await MainActor.run {
                self.currentStatus = snapshot
                self.isLoaded = true
            }

            // Notify on status changes (skip first fetch)
            if !isFirstFetch,
               let previousWorst = previousWorst,
               snapshot.worstRelevantStatus != previousWorst,
               snapshot.hasIssue,
               Defaults[.enableServiceStatusNotifications] {
                sendStatusNotification(snapshot: snapshot)
            }
            isFirstFetch = false

        } catch {
            print("[ClaudeStatusService] Fetch failed: \(error.localizedDescription)")
            // Keep cached data
            if !isLoaded, lastStatus == nil {
                await MainActor.run {
                    self.isLoaded = true
                }
            }
            isFirstFetch = false
        }
    }

    // MARK: - Notifications

    private func sendStatusNotification(snapshot: ClaudeServiceSnapshot) {
        let content = UNMutableNotificationContent()
        content.title = "Claude Service Issue"
        content.body = snapshot.overallDescription
        content.sound = .default
        content.threadIdentifier = "claude-service-status"

        let request = UNNotificationRequest(
            identifier: "claude-status-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[ClaudeStatusService] Notification failed: \(error.localizedDescription)")
            }
        }
    }
}
