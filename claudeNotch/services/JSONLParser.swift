//
//  JSONLParser.swift
//  claudeNotch
//
//  Created by Harrison Riehle on 2026. 01. 14..
//

import Foundation

// MARK: - Stats Cache Model (Primary Data Source)

struct StatsCache: Codable {
    let version: Int?
    let lastComputedDate: String?
    let dailyActivity: [DailyActivity]?
    let dailyModelTokens: [DailyModelTokens]?
    let modelUsage: [String: ModelStats]?
    let totalSessions: Int?
    let totalMessages: Int?
    let longestSession: LongestSession?
    let firstSessionDate: String?
    let hourCounts: [String: Int]?

    struct DailyActivity: Codable {
        let date: String
        let messageCount: Int?
        let sessionCount: Int?
        let toolCallCount: Int?
    }

    struct DailyModelTokens: Codable {
        let date: String
        let tokensByModel: [String: Int]?
    }

    struct ModelStats: Codable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
        let webSearchRequests: Int?
        let costUSD: Double?
        let contextWindow: Int?
        let maxOutputTokens: Int?
    }

    struct LongestSession: Codable {
        let sessionId: String?
        let duration: Int?
        let messageCount: Int?
        let timestamp: String?
    }
}

// MARK: - JSONL Log Entry Model (Fallback Data Source)

struct ClaudeLogEntry: Codable {
    let parentUuid: String?
    let isSidechain: Bool?
    let userType: String?
    let cwd: String?
    let sessionId: String?
    let version: String?
    let gitBranch: String?
    let agentId: String?
    let slug: String?
    let type: String?  // "user" or "assistant"
    let message: MessageContent?
    let uuid: String?
    let timestamp: String?
    let requestId: String?

    struct MessageContent: Codable {
        let role: String?
        let model: String?
        let id: String?
        let type: String?
        let content: ContentValue?
        let stop_reason: String?
        let usage: TokenUsage?

        // Content can be string or array
        enum ContentValue: Codable {
            case string(String)
            case array([ContentBlock])

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let string = try? container.decode(String.self) {
                    self = .string(string)
                } else if let array = try? container.decode([ContentBlock].self) {
                    self = .array(array)
                } else {
                    self = .string("")
                }
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .string(let value):
                    try container.encode(value)
                case .array(let value):
                    try container.encode(value)
                }
            }
        }

        struct ContentBlock: Codable {
            let type: String?
            let text: String?
        }
    }

    struct TokenUsage: Codable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
        let service_tier: String?
        let cache_creation: CacheCreation?

        struct CacheCreation: Codable {
            let ephemeral_5m_input_tokens: Int?
            let ephemeral_1h_input_tokens: Int?
        }

        var totalTokens: Int {
            return (input_tokens ?? 0) +
                   (output_tokens ?? 0) +
                   (cache_read_input_tokens ?? 0) +
                   (cache_creation_input_tokens ?? 0)
        }
    }
}

// MARK: - History Entry Model

struct HistoryEntry: Codable {
    let display: String?
    let pastedContents: [String: String]?
    let timestamp: Int?  // Unix timestamp in milliseconds
    let project: String?
    let sessionId: String?
}

// MARK: - Session Breakdown

struct SessionBreakdown {
    let quickCount: Int    // < 5 assistant messages
    let focusedCount: Int  // 5–20 assistant messages
    let deepCount: Int     // > 20 assistant messages
    var total: Int { quickCount + focusedCount + deepCount }
}

// MARK: - Parsed Usage Data

struct ParsedCodeUsage {
    var totalTokensAllTime: Int = 0
    var weeklyTokens: Int = 0
    var todayTokens: Int = 0
    var sonnetTokens: Int = 0
    var opusTokens: Int = 0
    var haikuTokens: Int = 0
    var totalSessions: Int = 0
    var totalMessages: Int = 0
    var lastUpdated: Date = Date()
}

// MARK: - JSONL Parser

class JSONLParser {
    private let claudeDir: URL
    private let statsCacheFile: URL
    private let projectsDir: URL
    private let historyFile: URL

    init() {
        // Use actual home directory, not sandboxed container
        let homeDir: URL
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            homeDir = URL(fileURLWithPath: String(cString: home))
        } else {
            homeDir = FileManager.default.homeDirectoryForCurrentUser
        }
        claudeDir = homeDir.appendingPathComponent(".claude")
        statsCacheFile = claudeDir.appendingPathComponent("stats-cache.json")
        projectsDir = claudeDir.appendingPathComponent("projects")
        historyFile = claudeDir.appendingPathComponent("history.jsonl")
        print("[JSONLParser] Initialized with home directory: \(homeDir.path)")
        print("[JSONLParser] Claude directory path: \(claudeDir.path)")
    }

    // MARK: - Primary: Parse Stats Cache

    func parseStatsCache() -> StatsCache? {
        guard FileManager.default.fileExists(atPath: statsCacheFile.path) else {
            print("[JSONLParser] stats-cache.json not found at \(statsCacheFile.path)")
            return nil
        }

        do {
            let data = try Data(contentsOf: statsCacheFile)
            let decoder = JSONDecoder()
            let stats = try decoder.decode(StatsCache.self, from: data)
            print("[JSONLParser] Successfully parsed stats-cache.json")
            return stats
        } catch {
            print("[JSONLParser] Failed to parse stats-cache.json: \(error)")
            return nil
        }
    }

    // MARK: - Convert Stats Cache to Usage Data

    func usageFromStatsCache(_ stats: StatsCache) -> ParsedCodeUsage {
        var usage = ParsedCodeUsage()

        // Get total tokens from modelUsage
        if let modelUsage = stats.modelUsage {
            for (modelName, modelStats) in modelUsage {
                let tokens = (modelStats.inputTokens ?? 0) +
                            (modelStats.outputTokens ?? 0) +
                            (modelStats.cacheReadInputTokens ?? 0) +
                            (modelStats.cacheCreationInputTokens ?? 0)

                usage.totalTokensAllTime += tokens

                // Categorize by model
                let lowerName = modelName.lowercased()
                if lowerName.contains("sonnet") {
                    usage.sonnetTokens += tokens
                } else if lowerName.contains("opus") {
                    usage.opusTokens += tokens
                } else if lowerName.contains("haiku") {
                    usage.haikuTokens += tokens
                }
            }
        }

        // Get weekly tokens from dailyModelTokens
        if let dailyTokens = stats.dailyModelTokens {
            let calendar = Calendar.current
            let now = Date()
            let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)!
            let startOfToday = calendar.startOfDay(for: now)

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"

            for daily in dailyTokens {
                guard let date = dateFormatter.date(from: daily.date) else { continue }

                if let tokensByModel = daily.tokensByModel {
                    let dayTotal = tokensByModel.values.reduce(0, +)

                    // Weekly tokens
                    if date >= weekAgo {
                        usage.weeklyTokens += dayTotal
                    }

                    // Today's tokens
                    if date >= startOfToday {
                        usage.todayTokens += dayTotal
                    }
                }
            }
        }

        usage.totalSessions = stats.totalSessions ?? 0
        usage.totalMessages = stats.totalMessages ?? 0
        usage.lastUpdated = Date()

        return usage
    }

    // MARK: - Fallback: Parse JSONL Files

    func parseJSONLFile(at url: URL) -> [ClaudeLogEntry] {
        var entries: [ClaudeLogEntry] = []

        guard let fileContents = try? String(contentsOf: url, encoding: .utf8) else {
            print("[JSONLParser] Failed to read file: \(url.path)")
            return entries
        }

        let lines = fileContents.components(separatedBy: "\n")
        let decoder = JSONDecoder()

        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let data = line.data(using: .utf8) else { continue }

            do {
                let entry = try decoder.decode(ClaudeLogEntry.self, from: data)
                entries.append(entry)
            } catch {
                // Skip malformed lines - this is expected for some log types
                continue
            }
        }

        return entries
    }

    func parseAllProjectLogs() -> [ClaudeLogEntry] {
        var allEntries: [ClaudeLogEntry] = []

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            print("[JSONLParser] Projects directory not found at \(projectsDir.path)")
            return allEntries
        }

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return allEntries
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }

            let entries = parseJSONLFile(at: fileURL)
            allEntries.append(contentsOf: entries)
        }

        print("[JSONLParser] Parsed \(allEntries.count) entries from project logs")
        return allEntries
    }

    // MARK: - Calculate Usage from Log Entries

    func usageFromLogEntries(_ entries: [ClaudeLogEntry]) -> ParsedCodeUsage {
        var usage = ParsedCodeUsage()

        let calendar = Calendar.current
        let now = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        let startOfToday = calendar.startOfDay(for: now)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var sessionIds = Set<String>()

        for entry in entries {
            // Only count assistant messages with usage data
            guard entry.type == "assistant",
                  let message = entry.message,
                  let usageData = message.usage else {
                continue
            }

            let tokens = usageData.totalTokens
            usage.totalTokensAllTime += tokens

            // Track sessions
            if let sessionId = entry.sessionId {
                sessionIds.insert(sessionId)
            }

            // Count messages
            usage.totalMessages += 1

            // Categorize by model
            if let model = message.model {
                let lowerModel = model.lowercased()
                if lowerModel.contains("sonnet") {
                    usage.sonnetTokens += tokens
                } else if lowerModel.contains("opus") {
                    usage.opusTokens += tokens
                } else if lowerModel.contains("haiku") {
                    usage.haikuTokens += tokens
                }
            }

            // Check date for weekly/today
            if let timestampStr = entry.timestamp,
               let date = isoFormatter.date(from: timestampStr) {
                if date >= weekAgo {
                    usage.weeklyTokens += tokens
                }
                if date >= startOfToday {
                    usage.todayTokens += tokens
                }
            }
        }

        usage.totalSessions = sessionIds.count
        usage.lastUpdated = Date()

        return usage
    }

    // MARK: - Live Stats from JSONL (more current than stats-cache)

    func liveStatsFromEntries(_ entries: [ClaudeLogEntry]) -> (sessions: Int, messages: Int) {
        var sessionIds = Set<String>()
        var messages = 0
        for entry in entries where entry.type == "assistant" {
            messages += 1
            if let sid = entry.sessionId { sessionIds.insert(sid) }
        }
        return (sessions: sessionIds.count, messages: messages)
    }

    // MARK: - Daily Output Tokens from JSONL (fills stats-cache gaps)

    func dailyOutputTokensFromEntries(_ entries: [ClaudeLogEntry]) -> [String: Int] {
        var daily: [String: Int] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        for entry in entries where entry.type == "assistant" {
            guard let ts = entry.timestamp,
                  let date = iso.date(from: ts),
                  let outputTokens = entry.message?.usage?.output_tokens,
                  outputTokens > 0 else { continue }
            let key = fmt.string(from: date)
            daily[key, default: 0] += outputTokens
        }
        return daily
    }

    // MARK: - Session Classification

    func classifySessionsFromLogs(_ entries: [ClaudeLogEntry]) -> SessionBreakdown {
        var sessionMsgCounts: [String: Int] = [:]
        for entry in entries where entry.type == "assistant" {
            if let sid = entry.sessionId {
                sessionMsgCounts[sid, default: 0] += 1
            }
        }
        var quick = 0, focused = 0, deep = 0
        for count in sessionMsgCounts.values {
            if count < 5        { quick += 1 }
            else if count <= 20 { focused += 1 }
            else                { deep += 1 }
        }
        return SessionBreakdown(quickCount: quick, focusedCount: focused, deepCount: deep)
    }

    // MARK: - Check if Claude Directory Exists

    func claudeDirectoryExists() -> Bool {
        return FileManager.default.fileExists(atPath: claudeDir.path)
    }

    func statsCacheExists() -> Bool {
        return FileManager.default.fileExists(atPath: statsCacheFile.path)
    }

    var statsCachePath: URL {
        return statsCacheFile
    }

    var projectsPath: URL {
        return projectsDir
    }
}
