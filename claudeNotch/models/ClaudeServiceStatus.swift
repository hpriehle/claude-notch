//
//  ClaudeServiceStatus.swift
//  claudeNotch
//
//  Created by Harrison Riehle on 2026. 03. 23..
//

import SwiftUI

// MARK: - Statuspage.io API Response Models

struct StatusPageSummary: Codable {
    let page: StatusPage
    let components: [StatusComponent]
    let incidents: [StatusIncident]
    let scheduledMaintenances: [StatusIncident]
    let status: StatusOverall

    enum CodingKeys: String, CodingKey {
        case page, components, incidents, status
        case scheduledMaintenances = "scheduled_maintenances"
    }
}

struct StatusPage: Codable {
    let id: String
    let name: String
    let url: String
}

struct StatusComponent: Codable {
    let id: String
    let name: String
    let status: String
}

struct StatusIncident: Codable {
    let id: String
    let name: String
    let status: String
    let impact: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, impact
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct StatusOverall: Codable {
    let indicator: String
    let description: String
}

// MARK: - App-Facing Models

enum ServiceHealthLevel: Int, Comparable {
    case operational = 0
    case degradedPerformance = 1
    case partialOutage = 2
    case majorOutage = 3
    case unknown = 4

    static func < (lhs: ServiceHealthLevel, rhs: ServiceHealthLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func from(statusString: String) -> ServiceHealthLevel {
        switch statusString {
        case "operational": return .operational
        case "degraded_performance": return .degradedPerformance
        case "partial_outage": return .partialOutage
        case "major_outage": return .majorOutage
        default: return .unknown
        }
    }

    static func fromIndicator(_ indicator: String) -> ServiceHealthLevel {
        switch indicator {
        case "none": return .operational
        case "minor": return .degradedPerformance
        case "major": return .partialOutage
        case "critical": return .majorOutage
        default: return .unknown
        }
    }

    var label: String {
        switch self {
        case .operational: return "OK"
        case .degradedPerformance: return "Degraded"
        case .partialOutage: return "Partial Outage"
        case .majorOutage: return "Outage"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .operational: return .green
        case .degradedPerformance: return .yellow
        case .partialOutage: return .orange
        case .majorOutage: return .red
        case .unknown: return .gray
        }
    }

    var systemImage: String {
        switch self {
        case .operational: return "checkmark.circle.fill"
        case .degradedPerformance: return "exclamationmark.triangle.fill"
        case .partialOutage: return "exclamationmark.triangle.fill"
        case .majorOutage: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

struct ClaudeServiceSnapshot {
    let apiStatus: ServiceHealthLevel
    let codeStatus: ServiceHealthLevel
    let overallDescription: String
    let activeIncidents: [StatusIncident]
    let statusPageURL: URL
    let fetchedAt: Date

    var worstRelevantStatus: ServiceHealthLevel {
        max(apiStatus, codeStatus)
    }

    var hasIssue: Bool {
        let worst = worstRelevantStatus
        return worst > .operational && worst != .unknown
    }

    static let unknown = ClaudeServiceSnapshot(
        apiStatus: .unknown,
        codeStatus: .unknown,
        overallDescription: "Unable to fetch status",
        activeIncidents: [],
        statusPageURL: URL(string: "https://status.claude.com")!,
        fetchedAt: Date()
    )
}
