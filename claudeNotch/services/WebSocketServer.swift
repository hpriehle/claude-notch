//
//  WebSocketServer.swift
//  claudeNotch
//
//  Created by Harrison Riehle on 2026. 01. 14..
//

import Foundation
import Network
import Combine
import Defaults

/// WebSocket server that receives usage data from browser extension
class WebSocketServer: ObservableObject {

    // MARK: - Timestamp Helper

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private func ts() -> String {
        return Self.timestampFormatter.string(from: Date())
    }
    static let shared = WebSocketServer()

    // MARK: - Published Properties

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var connectedClients: Int = 0
    @Published private(set) var lastDataReceived: Date?

    // MARK: - Private Properties

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var connectionActivity: [ObjectIdentifier: Date] = [:]  // Track last activity per connection
    private let serverQueue = DispatchQueue(label: "com.claudenotch.websocket", qos: .userInitiated)
    private var cleanupTimer: DispatchSourceTimer?
    private let connectionTimeout: TimeInterval = 60  // Close connections idle for > 60 seconds

    // Callback for when usage data is received
    var onUsageReceived: ((WebUsageData) -> Void)?

    // MARK: - Initialization

    private init() {}

    deinit {
        stop()
    }

    // MARK: - Public Methods

    func start(port: UInt16? = nil) {
        guard !isRunning else {
            print("[WebSocketServer \(ts())] Already running")
            return
        }

        let serverPort = port ?? Defaults[.webSocketPort]

        do {
            // Use simple TCP parameters (not loopback-restricted)
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            // Add WebSocket as application protocol
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: serverPort)!)

            listener?.stateUpdateHandler = { [weak self] state in
                self?.handleListenerStateChange(state)
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener?.start(queue: serverQueue)

            // Start periodic cleanup of stale connections
            startCleanupTimer()

            print("[WebSocketServer \(ts())] Starting on port \(serverPort)...")

        } catch {
            print("[WebSocketServer \(ts())] Failed to start: \(error)")
        }
    }

    func stop() {
        stopCleanupTimer()

        listener?.cancel()
        listener = nil

        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        connectionActivity.removeAll()

        DispatchQueue.main.async {
            self.isRunning = false
            self.connectedClients = 0
        }

        print("[WebSocketServer \(ts())] Stopped")
    }

    // MARK: - Connection Cleanup Timer

    private func startCleanupTimer() {
        stopCleanupTimer()

        let timer = DispatchSource.makeTimerSource(queue: serverQueue)
        timer.schedule(deadline: .now() + 30, repeating: 30)  // Check every 30 seconds
        timer.setEventHandler { [weak self] in
            self?.cleanupStaleConnections()
        }
        timer.resume()
        cleanupTimer = timer
    }

    private func stopCleanupTimer() {
        cleanupTimer?.cancel()
        cleanupTimer = nil
    }

    private func cleanupStaleConnections() {
        let now = Date()
        var staleConnections: [NWConnection] = []

        for connection in connections {
            let id = ObjectIdentifier(connection)
            if let lastActivity = connectionActivity[id] {
                if now.timeIntervalSince(lastActivity) > connectionTimeout {
                    staleConnections.append(connection)
                }
            } else {
                // No activity recorded, consider it stale
                staleConnections.append(connection)
            }
        }

        if !staleConnections.isEmpty {
            print("[WebSocketServer \(ts())] Cleaning up \(staleConnections.count) stale connection(s)")
            for connection in staleConnections {
                removeConnection(connection)
            }
        }
    }

    // MARK: - Private Methods

    private func handleListenerStateChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            print("[WebSocketServer \(self.ts())] Server ready and listening")
            DispatchQueue.main.async {
                self.isRunning = true
            }

        case .failed(let error):
            print("[WebSocketServer \(self.ts())] Server failed: \(error)")
            DispatchQueue.main.async {
                self.isRunning = false
            }
            // Try to restart after delay
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.start()
            }

        case .cancelled:
            print("[WebSocketServer \(self.ts())] Server cancelled")
            DispatchQueue.main.async {
                self.isRunning = false
            }

        default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        print("[WebSocketServer \(ts())] New connection from \(connection.endpoint)")

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionStateChange(connection, state: state)
        }

        connections.append(connection)
        connection.start(queue: serverQueue)

        DispatchQueue.main.async {
            self.connectedClients = self.connections.count
        }

        // Start receiving data
        receiveData(from: connection)
    }

    private func handleConnectionStateChange(_ connection: NWConnection, state: NWConnection.State) {
        switch state {
        case .ready:
            print("[WebSocketServer \(self.ts())] Connection ready")
            // Track initial activity
            connectionActivity[ObjectIdentifier(connection)] = Date()

        case .waiting(let error):
            print("[WebSocketServer \(self.ts())] Connection waiting: \(error)")
            // Connection stalled, close it to prevent resource leak
            connection.cancel()

        case .failed(let error):
            print("[WebSocketServer \(self.ts())] Connection failed: \(error)")
            removeConnection(connection)

        case .cancelled:
            print("[WebSocketServer \(self.ts())] Connection cancelled")
            removeConnection(connection)

        default:
            break
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        // Cancel connection to release file descriptor
        connection.cancel()

        // Remove from tracking
        let id = ObjectIdentifier(connection)
        connectionActivity.removeValue(forKey: id)
        connections.removeAll { $0 === connection }

        DispatchQueue.main.async {
            self.connectedClients = self.connections.count
        }
        print("[WebSocketServer \(self.ts())] Connection removed, \(self.connections.count) remaining")
    }

    private func receiveData(from connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("[WebSocketServer \(self.ts())] Receive error: \(error)")
                return
            }

            if let content = content, !content.isEmpty {
                // Update activity timestamp
                self.connectionActivity[ObjectIdentifier(connection)] = Date()
                self.handleReceivedData(content, from: connection)
            }

            // Continue receiving if connection is still active
            if connection.state == .ready {
                self.receiveData(from: connection)
            }
        }
    }

    private func handleReceivedData(_ data: Data, from connection: NWConnection) {
        // Parse JSON from browser extension
        do {
            let decoder = JSONDecoder()
            let webData = try decoder.decode(WebUsageData.self, from: data)

            print("[WebSocketServer \(ts())] Received usage data: session=\(webData.sessionPercent)%, weekly=\(webData.weeklyAllPercent)%")

            DispatchQueue.main.async {
                self.lastDataReceived = Date()
                self.onUsageReceived?(webData)
            }

            // Send acknowledgment
            sendAcknowledgment(to: connection)

        } catch {
            print("[WebSocketServer \(ts())] Failed to parse data: \(error)")

            // Try to parse as simple ping/test message
            if let message = String(data: data, encoding: .utf8) {
                print("[WebSocketServer \(ts())] Received message: \(message)")

                if message == "ping" {
                    sendPong(to: connection)
                }
            }
        }
    }

    private func sendAcknowledgment(to connection: NWConnection) {
        let response = ["status": "ok", "timestamp": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONEncoder().encode(response) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "ack", metadata: [metadata])
            connection.send(content: data, contentContext: context, completion: .idempotent)
        }
    }

    private func sendPong(to connection: NWConnection) {
        let pong = "pong".data(using: .utf8)!
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "pong", metadata: [metadata])
        connection.send(content: pong, contentContext: context, completion: .idempotent)
    }

    // MARK: - Broadcast to All Clients

    func broadcast(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "broadcast", metadata: [metadata])

        for connection in connections where connection.state == .ready {
            connection.send(content: data, contentContext: context, completion: .idempotent)
        }
    }

    /// Request the browser extension to fetch fresh usage data
    func requestRefresh() {
        print("[WebSocketServer \(ts())] Requesting refresh from extension")
        broadcast("{\"type\":\"REFRESH\"}")
    }
}

// MARK: - Web Usage Data Model

struct WebUsageData: Codable {
    let sessionPercent: Int
    let weeklyAllPercent: Int
    let weeklySonnetPercent: Int
    let sessionResetTime: String  // ISO-8601
    let weeklyAllResetTime: String
    let weeklySonnetResetTime: String
    let accountType: String

    // Parse ISO-8601 dates
    var sessionResetDate: Date? {
        return ISO8601DateFormatter().date(from: sessionResetTime)
    }

    var weeklyAllResetDate: Date? {
        return ISO8601DateFormatter().date(from: weeklyAllResetTime)
    }

    var weeklySonnetResetDate: Date? {
        return ISO8601DateFormatter().date(from: weeklySonnetResetTime)
    }
}
