//
//  SettingsView.swift
//  claudeNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//  Modified for ClaudeNotch by Harrison Riehle on 2026. 01. 14..
//

import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import Sparkle
import SwiftUI
import SwiftUIIntrospect

struct SettingsView: View {
    @State private var selectedTab = "General"
    @State private var accentColorUpdateTrigger = UUID()

    let updaterController: SPUStandardUpdaterController?

    init(updaterController: SPUStandardUpdaterController? = nil) {
        self.updaterController = updaterController
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                NavigationLink(value: "General") {
                    Label("General", systemImage: "gear")
                }
                NavigationLink(value: "Claude") {
                    Label("Claude", systemImage: "sparkles")
                }
                NavigationLink(value: "About") {
                    Label("About", systemImage: "info.circle")
                }
            }
            .listStyle(SidebarListStyle())
            .tint(.effectiveAccent)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                switch selectedTab {
                case "General":
                    GeneralSettings()
                case "Claude":
                    ClaudeSettings()
                case "About":
                    if let controller = updaterController {
                        About(updaterController: controller)
                    } else {
                        // Fallback with a default controller
                        About(
                            updaterController: SPUStandardUpdaterController(
                                startingUpdater: false, updaterDelegate: nil,
                                userDriverDelegate: nil))
                    }
                default:
                    GeneralSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("")
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 700)
        .background(Color(NSColor.windowBackgroundColor))
        .tint(.effectiveAccent)
        .id(accentColorUpdateTrigger)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AccentColorChanged"))) { _ in
            accentColorUpdateTrigger = UUID()
        }
    }
}

struct GeneralSettings: View {
    @State private var screens: [(uuid: String, name: String)] = NSScreen.screens.compactMap { screen in
        guard let uuid = screen.displayUUID else { return nil }
        return (uuid, screen.localizedName)
    }
    @EnvironmentObject var vm: ClaudeViewModel
    @ObservedObject var coordinator = ClaudeViewCoordinator.shared

    @Default(.gestureSensitivity) var gestureSensitivity
    @Default(.minimumHoverDuration) var minimumHoverDuration
    @Default(.nonNotchHeight) var nonNotchHeight
    @Default(.nonNotchHeightMode) var nonNotchHeightMode
    @Default(.notchHeight) var notchHeight
    @Default(.notchHeightMode) var notchHeightMode
    @Default(.showOnAllDisplays) var showOnAllDisplays
    @Default(.automaticallySwitchDisplay) var automaticallySwitchDisplay
    @Default(.enableGestures) var enableGestures
    @Default(.openNotchOnHover) var openNotchOnHover
    @Default(.useCustomAccentColor) var useCustomAccentColor
    @Default(.customAccentColorData) var customAccentColorData

    @State private var customAccentColor: Color = .accentColor
    @State private var selectedPresetColor: PresetAccentColor? = nil

    // macOS accent colors
    enum PresetAccentColor: String, CaseIterable, Identifiable {
        case blue = "Blue"
        case purple = "Purple"
        case pink = "Pink"
        case red = "Red"
        case orange = "Orange"
        case yellow = "Yellow"
        case green = "Green"
        case graphite = "Graphite"

        var id: String { self.rawValue }

        var color: Color {
            switch self {
            case .blue: return Color(red: 0.0, green: 0.478, blue: 1.0)
            case .purple: return Color(red: 0.686, green: 0.322, blue: 0.871)
            case .pink: return Color(red: 1.0, green: 0.176, blue: 0.333)
            case .red: return Color(red: 1.0, green: 0.271, blue: 0.227)
            case .orange: return Color(red: 1.0, green: 0.584, blue: 0.0)
            case .yellow: return Color(red: 1.0, green: 0.8, blue: 0.0)
            case .green: return Color(red: 0.4, green: 0.824, blue: 0.176)
            case .graphite: return Color(red: 0.557, green: 0.557, blue: 0.576)
            }
        }
    }

    var body: some View {
        Form {
            // MARK: System
            Section {
                Toggle(isOn: Binding(
                    get: { Defaults[.menubarIcon] },
                    set: { Defaults[.menubarIcon] = $0 }
                )) {
                    Text("Show menu bar icon")
                }
                .tint(.effectiveAccent)
                LaunchAtLogin.Toggle("Launch at login")
                Defaults.Toggle(key: .showOnAllDisplays) {
                    Text("Show on all displays")
                }
                .onChange(of: showOnAllDisplays) {
                    NotificationCenter.default.post(
                        name: Notification.Name.showOnAllDisplaysChanged, object: nil)
                }
                Picker("Preferred display", selection: $coordinator.preferredScreenUUID) {
                    ForEach(screens, id: \.uuid) { screen in
                        Text(screen.name).tag(screen.uuid as String?)
                    }
                }
                .onChange(of: NSScreen.screens) {
                    screens = NSScreen.screens.compactMap { screen in
                        guard let uuid = screen.displayUUID else { return nil }
                        return (uuid, screen.localizedName)
                    }
                }
                .disabled(showOnAllDisplays)

                Defaults.Toggle(key: .automaticallySwitchDisplay) {
                    Text("Automatically switch displays")
                }
                    .onChange(of: automaticallySwitchDisplay) {
                        NotificationCenter.default.post(
                            name: Notification.Name.automaticallySwitchDisplayChanged, object: nil)
                    }
                    .disabled(showOnAllDisplays)
            } header: {
                Text("System")
            }

            // MARK: Notch Sizing
            Section {
                Picker(
                    selection: $notchHeightMode,
                    label:
                        Text("Notch height on notch displays")
                ) {
                    Text("Match real notch height")
                        .tag(WindowHeightMode.matchRealNotchSize)
                    Text("Match menu bar height")
                        .tag(WindowHeightMode.matchMenuBar)
                    Text("Custom height")
                        .tag(WindowHeightMode.custom)
                }
                .onChange(of: notchHeightMode) {
                    switch notchHeightMode {
                    case .matchRealNotchSize:
                        notchHeight = 38
                    case .matchMenuBar:
                        notchHeight = 44
                    case .custom:
                        notchHeight = 38
                    }
                    NotificationCenter.default.post(
                        name: Notification.Name.notchHeightChanged, object: nil)
                }
                if notchHeightMode == .custom {
                    Slider(value: $notchHeight, in: 15...45, step: 1) {
                        Text("Custom notch size - \(notchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: notchHeight) {
                        NotificationCenter.default.post(
                            name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
                Picker("Notch height on non-notch displays", selection: $nonNotchHeightMode) {
                    Text("Match menubar height")
                        .tag(WindowHeightMode.matchMenuBar)
                    Text("Match real notch height")
                        .tag(WindowHeightMode.matchRealNotchSize)
                    Text("Custom height")
                        .tag(WindowHeightMode.custom)
                }
                .onChange(of: nonNotchHeightMode) {
                    switch nonNotchHeightMode {
                    case .matchMenuBar:
                        nonNotchHeight = 24
                    case .matchRealNotchSize:
                        nonNotchHeight = 32
                    case .custom:
                        nonNotchHeight = 32
                    }
                    NotificationCenter.default.post(
                        name: Notification.Name.notchHeightChanged, object: nil)
                }
                if nonNotchHeightMode == .custom {
                    Slider(value: $nonNotchHeight, in: 0...40, step: 1) {
                        Text("Custom notch size - \(nonNotchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: nonNotchHeight) {
                        NotificationCenter.default.post(
                            name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
            } header: {
                Text("Notch sizing")
            }

            // MARK: Notch Behavior
            NotchBehaviour()

            // MARK: Gestures
            gestureControls()

            // MARK: Appearance
            accentColorSection()

            Section {
                Defaults.Toggle(key: .settingsIconInNotch) {
                    Text("Show settings icon in notch")
                }
                Defaults.Toggle(key: .enableShadow) {
                    Text("Enable window shadow")
                }
                Defaults.Toggle(key: .cornerRadiusScaling) {
                    Text("Corner radius scaling")
                }
            } header: {
                Text("Window Appearance")
            }

            // MARK: Window Behavior
            Section {
                Defaults.Toggle(key: .hideTitleBar) {
                    Text("Hide title bar")
                }
                Defaults.Toggle(key: .showOnLockScreen) {
                    Text("Show notch on lock screen")
                }
                Defaults.Toggle(key: .hideFromScreenRecording) {
                    Text("Hide from screen recording")
                }
            } header: {
                Text("Window Behavior")
            }

            // MARK: Keyboard Shortcuts
            Section {
                KeyboardShortcuts.Recorder("Toggle Notch Open:", name: .toggleNotchOpen)
            } header: {
                Text("Keyboard Shortcuts")
            }
        }
        .toolbar {
            Button("Quit app") {
                NSApp.terminate(self)
            }
            .controlSize(.extraLarge)
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("General")
        .onChange(of: openNotchOnHover) {
            if !openNotchOnHover {
                enableGestures = true
            }
        }
        .onAppear {
            initializeAccentColorState()
            loadCustomColor()
        }
    }

    @ViewBuilder
    func gestureControls() -> some View {
        Section {
            Defaults.Toggle(key: .enableGestures) {
                Text("Enable gestures")
            }
                .disabled(!openNotchOnHover)
            if enableGestures {
                Toggle("Change media with horizontal gestures", isOn: .constant(false))
                    .disabled(true)
                Defaults.Toggle(key: .closeGestureEnabled) {
                    Text("Close gesture")
                }
                Slider(value: $gestureSensitivity, in: 100...300, step: 100) {
                    HStack {
                        Text("Gesture sensitivity")
                        Spacer()
                        Text(
                            Defaults[.gestureSensitivity] == 100
                                ? "High" : Defaults[.gestureSensitivity] == 200 ? "Medium" : "Low"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            HStack {
                Text("Gesture control")
                customBadge(text: "Beta")
            }
        } footer: {
            Text(
                "Two-finger swipe up on notch to close, two-finger swipe down on notch to open when **Open notch on hover** option is disabled"
            )
            .multilineTextAlignment(.trailing)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
    }

    @ViewBuilder
    func NotchBehaviour() -> some View {
        Section {
            Defaults.Toggle(key: .openNotchOnHover) {
                Text("Open notch on hover")
            }
            Defaults.Toggle(key: .enableHaptics) {
                    Text("Enable haptic feedback")
            }
            if openNotchOnHover {
                Slider(value: $minimumHoverDuration, in: 0...1, step: 0.1) {
                    HStack {
                        Text("Hover delay")
                        Spacer()
                        Text("\(minimumHoverDuration, specifier: "%.1f")s")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: minimumHoverDuration) {
                    NotificationCenter.default.post(
                        name: Notification.Name.notchHeightChanged, object: nil)
                }
            }
        } header: {
            Text("Notch behavior")
        }
    }

    @ViewBuilder
    func accentColorSection() -> some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                // Toggle between system and custom
                Picker("Accent color", selection: $useCustomAccentColor) {
                    Text("System").tag(false)
                    Text("Custom").tag(true)
                }
                .pickerStyle(.segmented)

                if !useCustomAccentColor {
                    // System accent info
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            AccentCircleButton(
                                isSelected: true,
                                color: .accentColor,
                                isSystemDefault: true
                            ) {}

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Using System Accent")
                                    .font(.body)
                                Text("Your macOS system accent color")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                } else {
                    // Custom color options
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Color Presets")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            ForEach(PresetAccentColor.allCases) { preset in
                                AccentCircleButton(
                                    isSelected: selectedPresetColor == preset,
                                    color: preset.color,
                                    isMulticolor: false
                                ) {
                                    selectedPresetColor = preset
                                    customAccentColor = preset.color
                                    saveCustomColor(preset.color)
                                    forceUiUpdate()
                                }
                            }
                            Spacer()
                        }

                        Divider()
                            .padding(.vertical, 4)

                        // Custom color picker
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Pick a Color")
                                    .font(.body)
                                Text("Choose any color")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            ColorPicker(selection: Binding(
                                get: { customAccentColor },
                                set: { newColor in
                                    customAccentColor = newColor
                                    selectedPresetColor = nil
                                    saveCustomColor(newColor)
                                    forceUiUpdate()
                                }
                            ), supportsOpacity: false) {
                                ZStack {
                                    Circle()
                                        .fill(customAccentColor)
                                        .frame(width: 32, height: 32)

                                    if selectedPresetColor == nil {
                                        Circle()
                                            .strokeBorder(.primary.opacity(0.3), lineWidth: 2)
                                            .frame(width: 32, height: 32)
                                    }
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Accent color")
        }
    }

    private func forceUiUpdate() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("AccentColorChanged"), object: nil)
        }
    }

    private func saveCustomColor(_ color: Color) {
        let nsColor = NSColor(color)
        if let colorData = try? NSKeyedArchiver.archivedData(withRootObject: nsColor, requiringSecureCoding: false) {
            Defaults[.customAccentColorData] = colorData
            forceUiUpdate()
        }
    }

    private func loadCustomColor() {
        if let colorData = Defaults[.customAccentColorData],
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            customAccentColor = Color(nsColor: nsColor)

            // Check if loaded color matches a preset
            selectedPresetColor = nil
            for preset in PresetAccentColor.allCases {
                if colorsAreEqual(Color(nsColor: nsColor), preset.color) {
                    selectedPresetColor = preset
                    break
                }
            }
        }
    }

    private func colorsAreEqual(_ color1: Color, _ color2: Color) -> Bool {
        let nsColor1 = NSColor(color1).usingColorSpace(.sRGB) ?? NSColor(color1)
        let nsColor2 = NSColor(color2).usingColorSpace(.sRGB) ?? NSColor(color2)

        return abs(nsColor1.redComponent - nsColor2.redComponent) < 0.01 &&
               abs(nsColor1.greenComponent - nsColor2.greenComponent) < 0.01 &&
               abs(nsColor1.blueComponent - nsColor2.blueComponent) < 0.01
    }

    private func initializeAccentColorState() {
        if !useCustomAccentColor {
            selectedPresetColor = nil
        } else {
            loadCustomColor()
        }
    }
}

// Claude Settings view
struct ClaudeSettings: View {
    @Default(.showSessionUsage) var showSessionUsage
    @Default(.showWeeklyAllUsage) var showWeeklyAllUsage
    @Default(.showWeeklySonnetUsage) var showWeeklySonnetUsage
    @Default(.usageWarningThreshold) var usageWarningThreshold
    @Default(.usageCriticalThreshold) var usageCriticalThreshold

    @ObservedObject var usageService = ClaudeUsageService.shared
    @State private var isConnecting = false
    @State private var connectionError: String?

    var body: some View {
        Form {
            // OAuth API Connection
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(usageService.currentUsage.hasOAuthData ? Color.green : (usageService.hasOAuthData ? Color.yellow.opacity(0.8) : Color.gray.opacity(0.5)))
                                .frame(width: 8, height: 8)
                            Text(usageService.currentUsage.hasOAuthData ? "Connected via Claude Code" : (usageService.hasOAuthData ? "Connecting..." : "Not connected"))
                                .font(.system(size: 13, weight: .medium))
                        }
                        if usageService.currentUsage.hasOAuthData {
                            Text("Usage data refreshes every 120 seconds from Anthropic API")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Connect your Claude account for real-time usage percentages")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()

                    if usageService.currentUsage.hasOAuthData || usageService.hasOAuthData {
                        Button {
                            usageService.refresh()
                        } label: {
                            if usageService.isRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 60)
                            } else {
                                Text("Refresh")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(usageService.isRefreshing)
                    } else {
                        Button(isConnecting ? "Connecting..." : "Connect") {
                            connectClaudeAccount()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isConnecting)
                    }
                }

                if let error = connectionError ?? usageService.lastRefreshError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                if !usageService.currentUsage.hasOAuthData {
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
                            Text("Click \"Connect\" above after logging in")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
            } header: {
                HStack {
                    Text("Claude API Connection")
                    if usageService.currentUsage.hasOAuthData {
                        customBadge(text: "Active")
                    }
                }
            } footer: {
                Text("Reads OAuth tokens from Claude Code CLI to fetch real usage data directly from Anthropic's API. No browser extension needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .showSessionUsage) {
                    Text("Show session usage")
                }
                Defaults.Toggle(key: .showWeeklyAllUsage) {
                    Text("Show weekly all-models usage")
                }
                Defaults.Toggle(key: .showWeeklySonnetUsage) {
                    Text("Show weekly Sonnet usage")
                }
            } header: {
                Text("Usage Display")
            } footer: {
                Text("Choose which usage metrics to display in the notch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Warning threshold")
                    Spacer()
                    Text("\(usageWarningThreshold)%")
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(usageWarningThreshold) },
                    set: { usageWarningThreshold = Int($0) }
                ), in: 50...90, step: 5)
                .tint(.yellow)

                HStack {
                    Text("Critical threshold")
                    Spacer()
                    Text("\(usageCriticalThreshold)%")
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(usageCriticalThreshold) },
                    set: { usageCriticalThreshold = Int($0) }
                ), in: 70...99, step: 5)
                .tint(.red)
            } header: {
                Text("Thresholds")
            } footer: {
                Text("Colors change based on usage percentage: green → yellow → orange → red")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Claude")
    }

    private func connectClaudeAccount() {
        isConnecting = true
        connectionError = nil

        // Check if Claude CLI is installed
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["claude"]
        whichProcess.standardOutput = FileHandle.nullDevice
        whichProcess.standardError = FileHandle.nullDevice

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
        } catch {
            isConnecting = false
            connectionError = "Could not check for Claude CLI"
            return
        }

        if whichProcess.terminationStatus != 0 {
            isConnecting = false
            connectionError = "Claude Code CLI not found. Install it first, then run: claude /login"
            return
        }

        // Invalidate cache and try to read credentials
        ClaudeOAuthCredentialStore.shared.invalidateCache()

        if ClaudeOAuthCredentialStore.shared.hasCredentials {
            // Credentials found — start fetching
            usageService.connectOAuth()
            isConnecting = false
        } else {
            isConnecting = false
            connectionError = "No OAuth credentials found. Run `claude /login` in your terminal first."
        }
    }
}

func lighterColor(from nsColor: NSColor, amount: CGFloat = 0.14) -> Color {
    let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
    var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0,0,0,0)
    srgb.getRed(&r, green: &g, blue: &b, alpha: &a)

    func lighten(_ c: CGFloat) -> CGFloat {
        let increased = c + (1.0 - c) * amount
        return min(max(increased, 0), 1)
    }

    let nr = lighten(r)
    let ng = lighten(g)
    let nb = lighten(b)

    return Color(red: Double(nr), green: Double(ng), blue: Double(nb), opacity: Double(a))
}

struct About: View {
    @State private var showBuildNumber: Bool = false
    let updaterController: SPUStandardUpdaterController
    @Environment(\.openWindow) var openWindow
    var body: some View {
        VStack {
            Form {
                Section {
                    HStack {
                        Text("Release name")
                        Spacer()
                        Text(Defaults[.releaseName])
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        if showBuildNumber {
                            Text("(\(Bundle.main.buildVersionNumber ?? ""))")
                                .foregroundStyle(.secondary)
                        }
                        Text(Bundle.main.releaseVersionNumber ?? "unkown")
                            .foregroundStyle(.secondary)
                    }
                    .onTapGesture {
                        withAnimation {
                            showBuildNumber.toggle()
                        }
                    }
                } header: {
                    Text("Version info")
                }

                UpdaterSettingsView(updater: updaterController.updater)

                HStack(spacing: 30) {
                    Spacer(minLength: 0)
                    Button {
                        if let url = URL(string: "https://github.com/harrisonriehle/claude-notch") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image("Github")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 18)
                            Text("GitHub")
                        }
                        .contentShape(Rectangle())
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(PlainButtonStyle())
            }
            VStack(spacing: 0) {
                Divider()
                Text("ClaudeNotch - Claude AI usage in your notch")
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                    .padding(.bottom, 7)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .toolbar {
            CheckForUpdatesView(updater: updaterController.updater)
        }
        .navigationTitle("About")
    }
}

// MARK: - Accent Circle Button Component
struct AccentCircleButton: View {
    let isSelected: Bool
    let color: Color
    var isSystemDefault: Bool = false
    var isMulticolor: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Color circle
                Circle()
                    .fill(color)
                    .frame(width: 32, height: 32)

                // Subtle border
                Circle()
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    .frame(width: 32, height: 32)

                // Apple-style highlight ring around the middle when selected
                if isSelected {
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(0.5),
                            lineWidth: 2
                        )
                        .frame(width: 28, height: 28)
                }
            }
        }
        .buttonStyle(.plain)
        .help(isSystemDefault ? "Use your macOS system accent color" : "")
    }
}

// MARK: - Utility Views

func proFeatureBadge() -> some View {
    Text("Upgrade to Pro")
        .foregroundStyle(Color(red: 0.545, green: 0.196, blue: 0.98))
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4).stroke(
                Color(red: 0.545, green: 0.196, blue: 0.98), lineWidth: 1))
}

func comingSoonTag() -> some View {
    Text("Coming soon")
        .foregroundStyle(.secondary)
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color(nsColor: .secondarySystemFill))
        .clipShape(.capsule)
}

func customBadge(text: String) -> some View {
    Text(text)
        .foregroundStyle(.secondary)
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color(nsColor: .secondarySystemFill))
        .clipShape(.capsule)
}

func warningBadge(_ text: String, _ description: String) -> some View {
    Section {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading) {
                Text(text)
                    .font(.headline)
                Text(description)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
