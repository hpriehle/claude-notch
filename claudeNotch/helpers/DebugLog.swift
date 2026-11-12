//
//  DebugLog.swift
//  claudeNotch
//
//  Appends diagnostic lines to ~/Library/Logs/claudeNotch/debug.log.
//  print() output is lost when the app is launched from Finder or `open`,
//  so OAuth/credential diagnostics also go here. Active in Debug builds, or in
//  any build when the "debugFileLog" user default is true. Never log secrets.
//

import Foundation

enum DebugLog {
    private static let queue = DispatchQueue(label: "claudeNotch.debuglog")
    private static let maxBytes = 1_000_000

    static var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: "debugFileLog")
        #endif
    }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/claudeNotch/debug.log")
    }

    static func log(_ message: String) {
        print(message)
        guard isEnabled else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let url = fileURL
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                try? fm.removeItem(at: url)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
