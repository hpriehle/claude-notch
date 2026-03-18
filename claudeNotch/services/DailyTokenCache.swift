//
//  DailyTokenCache.swift
//  claudeNotch
//
//  Disk-backed cache of daily output-token counts parsed from ~/.claude/projects/**/*.jsonl.
//  Incremental: on each update only files modified since the last cache write are re-parsed.
//  Past days are finalized at midnight and never re-parsed again.
//

import Foundation

// MARK: - Cache File Model

private struct DailyTokenCacheFile: Codable {
    var cachedAt: Date
    var daily: [String: Int]          // "yyyy-MM-dd" → total output tokens
    var finalizedDates: Set<String>   // locked past days — never re-parsed
}

// MARK: - DailyTokenCache

final class DailyTokenCache {

    static let shared = DailyTokenCache()

    private let cacheURL: URL
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private let iso1: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso2: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("claudeNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        cacheURL = appSupport.appendingPathComponent("daily_token_cache.json")
    }

    // MARK: - Public API

    /// Load cache from disk instantly. Returns empty dict if no cache exists.
    func load() -> [String: Int] {
        return loadFile()?.daily ?? [:]
    }

    /// Lock yesterday's token count. Future `update()` calls will never overwrite it.
    /// Call on app launch and at 12:01 AM each day.
    func finalizeYesterday() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let key = dateFormatter.string(from: yesterday)
        guard var file = loadFile() else { return }
        guard !file.finalizedDates.contains(key) else { return }
        file.finalizedDates.insert(key)
        save(file)
    }

    /// Update cache by parsing only JSONL files modified since the last cache write.
    /// First run (no cache): restricts to files from the past 91 days.
    /// Returns merged daily token counts.
    func update(projectsDir: URL) async -> [String: Int] {
        return await Task.detached(priority: .utility) { [self] in
            let existing: DailyTokenCacheFile
            if let file = loadFile() {
                existing = file
            } else {
                let cutoff = Date(timeIntervalSinceNow: -91 * 86400)
                existing = DailyTokenCacheFile(cachedAt: cutoff, daily: [:], finalizedDates: [])
            }

            let newNow = Date()
            let todayKey = dateFormatter.string(from: newNow)
            let finalizedDates = existing.finalizedDates

            // For today: always re-parse from start of day so we get the full total.
            // For past days: only parse files modified since last cache write.
            let todayCutoff = Calendar.current.startOfDay(for: newNow)
            let historyCutoff = existing.cachedAt

            let todayTokens = parseNewFiles(since: todayCutoff, in: projectsDir, onlyDate: todayKey)
            let historyTokens = parseNewFiles(since: historyCutoff, in: projectsDir, excludeDate: todayKey)

            // Merge: today is fully re-counted from all of today's files;
            // past days only fill in if missing; finalized dates are never overwritten.
            var merged = existing.daily

            // Today: full recount from start of day
            if let todayTotal = todayTokens[todayKey], todayTotal > 0 {
                merged[todayKey] = todayTotal
            }

            // History: fill in any missing past days
            for (date, tokens) in historyTokens {
                guard !finalizedDates.contains(date) else { continue }
                if merged[date] == nil {
                    merged[date] = tokens
                }
            }

            let updated = DailyTokenCacheFile(cachedAt: newNow, daily: merged, finalizedDates: finalizedDates)
            save(updated)
            return merged
        }.value
    }

    // MARK: - Private Helpers

    private func loadFile() -> DailyTokenCacheFile? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(DailyTokenCacheFile.self, from: data)
    }

    private func save(_ file: DailyTokenCacheFile) {
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    private func parseNewFiles(since cutoff: Date, in projectsDir: URL, onlyDate: String? = nil, excludeDate: String? = nil) -> [String: Int] {
        var daily: [String: Int] = [:]
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return daily }

        let decoder = JSONDecoder()

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                  mod >= cutoff else { continue }

            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line)
                guard s.contains("\"assistant\"") else { continue }
                guard let data = s.data(using: .utf8),
                      let entry = try? decoder.decode(ClaudeLogEntry.self, from: data),
                      entry.type == "assistant",
                      let ts = entry.timestamp,
                      let date = iso1.date(from: ts) ?? iso2.date(from: ts),
                      date >= cutoff,
                      let tokens = entry.message?.usage?.output_tokens,
                      tokens > 0 else { continue }
                let key = dateFormatter.string(from: date)
                if let only = onlyDate, key != only { continue }
                if let exclude = excludeDate, key == exclude { continue }
                daily[key, default: 0] += tokens
            }
        }

        return daily
    }
}
