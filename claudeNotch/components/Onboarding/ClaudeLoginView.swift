//
//  ClaudeLoginView.swift
//  claudeNotch
//

import SwiftUI

struct ClaudeLoginView: View {
    let onSuccess: () -> Void
    let onSkip: () -> Void

    @State private var isConnecting = false
    @State private var isConnected = false
    @State private var connectionError: String?

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: isConnected ? "checkmark.circle.fill" : "person.crop.circle.badge.checkmark")
                .resizable()
                .scaledToFit()
                .frame(width: 70, height: 56)
                .foregroundColor(isConnected ? .green : .effectiveAccent)
                .padding(.top, 32)
                .animation(.easeInOut(duration: 0.3), value: isConnected)

            Text("Connect Your Claude Account")
                .font(.title)
                .fontWeight(.semibold)

            if isConnected {
                Text("Successfully connected! Your usage data will appear in the notch.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.green)
                    .padding(.horizontal)
            } else {
                Text("ClaudeNotch reads your usage data directly from Anthropic's API. Connect your Claude Code account to see real-time session and weekly usage percentages.")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if !isConnected {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Setup")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fontWeight(.semibold)

                    HStack(alignment: .top, spacing: 8) {
                        Text("1.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        Text("Install Claude Code CLI (if not already installed)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Text("2.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Run `claude /login` in your terminal")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Copy command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("claude /login", forType: .string)
                            }
                            .font(.caption2)
                            .buttonStyle(.link)
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Text("3.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        Text("Click \"Connect\" below after logging in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
            }

            if let error = connectionError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 32)
            }

            HStack {
                if !isConnected {
                    Button("Skip") { onSkip() }
                        .buttonStyle(.bordered)
                }
                Button(isConnecting ? "Connecting..." : (isConnected ? "Continue" : "Connect")) {
                    if isConnected {
                        onSuccess()
                    } else {
                        connect()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting)
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }

    private func connect() {
        isConnecting = true
        connectionError = nil

        ClaudeOAuthCredentialStore.shared.invalidateCache()

        if ClaudeOAuthCredentialStore.shared.hasCredentials {
            ClaudeUsageService.shared.connectOAuth()
            isConnecting = false
            withAnimation { isConnected = true }
        } else {
            isConnecting = false
            connectionError = "No OAuth credentials found. Install Claude Code CLI and run `claude /login` in your terminal first."
        }
    }
}

#Preview {
    ClaudeLoginView(onSuccess: { }, onSkip: { })
        .frame(width: 400, height: 600)
}
