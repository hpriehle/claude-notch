//
//  ClaudeLogMonitor.swift
//  claudeNotch
//
//  Created by Harrison Riehle on 2026. 01. 14..
//

import Foundation
import Combine

/// Monitors the ~/.claude/ directory for changes to usage statistics
class ClaudeLogMonitor: ObservableObject {
    static let shared = ClaudeLogMonitor()

    // MARK: - Published Properties

    @Published private(set) var isMonitoring: Bool = false
    @Published private(set) var lastChangeDetected: Date?

    // MARK: - Private Properties

    private let claudeDir: URL
    private let statsCacheFile: URL
    private let projectsDir: URL

    private var statsCacheMonitor: DispatchSourceFileSystemObject?
    private var projectsMonitor: DispatchSourceFileSystemObject?
    private var claudeDirMonitor: DispatchSourceFileSystemObject?

    private var statsCacheFileDescriptor: Int32 = -1
    private var projectsFileDescriptor: Int32 = -1
    private var claudeDirFileDescriptor: Int32 = -1

    private var onChange: (() -> Void)?
    private let monitorQueue = DispatchQueue(label: "com.claudenotch.logmonitor", qos: .utility)

    // Debounce to avoid rapid-fire updates
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.5

    // MARK: - Initialization

    private init() {
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
        print("[ClaudeLogMonitor] Initialized with claude directory: \(claudeDir.path)")
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public Methods

    func startMonitoring(onChange: @escaping () -> Void) {
        guard !isMonitoring else {
            print("[ClaudeLogMonitor] Already monitoring")
            return
        }

        self.onChange = onChange

        // Check if Claude directory exists
        guard FileManager.default.fileExists(atPath: claudeDir.path) else {
            print("[ClaudeLogMonitor] ~/.claude directory not found - monitoring for creation")
            monitorForClaudeDirectoryCreation()
            return
        }

        setupMonitors()
    }

    func stopMonitoring() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        // Cancel and clean up stats cache monitor
        statsCacheMonitor?.cancel()
        statsCacheMonitor = nil
        if statsCacheFileDescriptor >= 0 {
            close(statsCacheFileDescriptor)
            statsCacheFileDescriptor = -1
        }

        // Cancel and clean up projects monitor
        projectsMonitor?.cancel()
        projectsMonitor = nil
        if projectsFileDescriptor >= 0 {
            close(projectsFileDescriptor)
            projectsFileDescriptor = -1
        }

        // Cancel and clean up claude directory monitor
        claudeDirMonitor?.cancel()
        claudeDirMonitor = nil
        if claudeDirFileDescriptor >= 0 {
            close(claudeDirFileDescriptor)
            claudeDirFileDescriptor = -1
        }

        DispatchQueue.main.async {
            self.isMonitoring = false
        }

        print("[ClaudeLogMonitor] Stopped monitoring")
    }

    // MARK: - Private Methods

    private func setupMonitors() {
        // Monitor stats-cache.json (primary source)
        if FileManager.default.fileExists(atPath: statsCacheFile.path) {
            setupStatsCacheMonitor()
        } else {
            print("[ClaudeLogMonitor] stats-cache.json not found - will monitor directory for creation")
        }

        // Monitor projects directory for new logs
        if FileManager.default.fileExists(atPath: projectsDir.path) {
            setupProjectsMonitor()
        }

        // Monitor claude directory for new files
        setupClaudeDirMonitor()

        DispatchQueue.main.async {
            self.isMonitoring = true
        }

        print("[ClaudeLogMonitor] Started monitoring ~/.claude/")
    }

    private func setupStatsCacheMonitor() {
        statsCacheFileDescriptor = open(statsCacheFile.path, O_EVTONLY)
        guard statsCacheFileDescriptor >= 0 else {
            print("[ClaudeLogMonitor] Failed to open stats-cache.json for monitoring")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: statsCacheFileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: monitorQueue
        )

        source.setEventHandler { [weak self] in
            self?.handleStatsCacheChange()
        }

        source.setCancelHandler { [weak self] in
            guard let self = self, self.statsCacheFileDescriptor >= 0 else { return }
            close(self.statsCacheFileDescriptor)
            self.statsCacheFileDescriptor = -1
        }

        source.resume()
        statsCacheMonitor = source

        print("[ClaudeLogMonitor] Watching stats-cache.json")
    }

    private func setupProjectsMonitor() {
        projectsFileDescriptor = open(projectsDir.path, O_EVTONLY)
        guard projectsFileDescriptor >= 0 else {
            print("[ClaudeLogMonitor] Failed to open projects directory for monitoring")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: projectsFileDescriptor,
            eventMask: [.write, .extend, .rename, .link],
            queue: monitorQueue
        )

        source.setEventHandler { [weak self] in
            self?.handleProjectsChange()
        }

        source.setCancelHandler { [weak self] in
            guard let self = self, self.projectsFileDescriptor >= 0 else { return }
            close(self.projectsFileDescriptor)
            self.projectsFileDescriptor = -1
        }

        source.resume()
        projectsMonitor = source

        print("[ClaudeLogMonitor] Watching projects directory")
    }

    private func setupClaudeDirMonitor() {
        claudeDirFileDescriptor = open(claudeDir.path, O_EVTONLY)
        guard claudeDirFileDescriptor >= 0 else {
            print("[ClaudeLogMonitor] Failed to open .claude directory for monitoring")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: claudeDirFileDescriptor,
            eventMask: [.write, .extend, .rename, .link],
            queue: monitorQueue
        )

        source.setEventHandler { [weak self] in
            self?.handleClaudeDirChange()
        }

        source.setCancelHandler { [weak self] in
            guard let self = self, self.claudeDirFileDescriptor >= 0 else { return }
            close(self.claudeDirFileDescriptor)
            self.claudeDirFileDescriptor = -1
        }

        source.resume()
        claudeDirMonitor = source

        print("[ClaudeLogMonitor] Watching .claude directory")
    }

    private func monitorForClaudeDirectoryCreation() {
        // Watch the home directory for the .claude folder to be created
        let homeDir = FileManager.default.homeDirectoryForCurrentUser

        claudeDirFileDescriptor = open(homeDir.path, O_EVTONLY)
        guard claudeDirFileDescriptor >= 0 else {
            print("[ClaudeLogMonitor] Failed to open home directory for monitoring")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: claudeDirFileDescriptor,
            eventMask: [.write, .rename, .link],
            queue: monitorQueue
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }

            if FileManager.default.fileExists(atPath: self.claudeDir.path) {
                print("[ClaudeLogMonitor] .claude directory created!")
                source.cancel()
                self.claudeDirFileDescriptor = -1
                self.setupMonitors()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self = self, self.claudeDirFileDescriptor >= 0 else { return }
            close(self.claudeDirFileDescriptor)
            self.claudeDirFileDescriptor = -1
        }

        source.resume()
        claudeDirMonitor = source

        print("[ClaudeLogMonitor] Waiting for .claude directory to be created...")
    }

    // MARK: - Event Handlers

    private func handleStatsCacheChange() {
        print("[ClaudeLogMonitor] stats-cache.json changed")
        triggerDebouncedUpdate()
    }

    private func handleProjectsChange() {
        print("[ClaudeLogMonitor] Projects directory changed")
        triggerDebouncedUpdate()
    }

    private func handleClaudeDirChange() {
        // Check if stats-cache.json was just created
        if statsCacheMonitor == nil && FileManager.default.fileExists(atPath: statsCacheFile.path) {
            print("[ClaudeLogMonitor] stats-cache.json created - setting up monitor")
            setupStatsCacheMonitor()
            triggerDebouncedUpdate()
        }
    }

    private func triggerDebouncedUpdate() {
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            DispatchQueue.main.async {
                self.lastChangeDetected = Date()
                self.onChange?()
            }
        }

        debounceWorkItem = workItem
        monitorQueue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    // MARK: - Utility

    var statsCacheExists: Bool {
        return FileManager.default.fileExists(atPath: statsCacheFile.path)
    }

    var claudeDirectoryExists: Bool {
        return FileManager.default.fileExists(atPath: claudeDir.path)
    }
}
