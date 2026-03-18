# ClaudeNotch

Track your Claude API usage right from your MacBook's notch.

ClaudeNotch lives in your MacBook's notch and shows real-time Claude usage stats at a glance. Hover to expand and see detailed breakdowns, swipe for usage history, and get notified when you're approaching limits.


https://github.com/user-attachments/assets/4183afbe-8bb9-474a-8f8e-a541fd505d94


## Features


- **Live usage in the notch** — token count and reset countdown visible at all times
- **Expanded detail view** — hover to see per-model cost breakdown, daily/monthly spend
- **Usage history** — swipe to a GitHub-style contribution grid showing 13 weeks of token activity
- **Session stats** — lifetime sessions, messages, peak usage hours
- **OAuth login** — connect your Anthropic account directly
- **Usage notifications** — alerts when approaching spend limits
- **Launch at login** — always running in the background
- **Now with Extra Usage**- see the current Claude Extra Usage Promotion

## Installation

**Requirements:** macOS 14 Sonoma or later, Apple Silicon or Intel Mac

### Download

Download the latest DMG from the [Releases page](https://github.com/hpriehle/claude-notch/releases/latest).

> [!IMPORTANT]
> ClaudeNotch is not signed with an Apple Developer certificate. On first launch:
> 1. macOS will show a popup that the app is from an unidentified developer — click **OK**.
> 2. Open **System Settings** > **Privacy & Security**.
> 3. Scroll down and click **Open Anyway** next to the warning.
> 4. Confirm your choice if prompted.
>
> You only need to do this once.

### Build from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/hpriehle/claude-notch.git
   cd claude-notch
   ```

2. Open in Xcode:
   ```bash
   open claudeNotch.xcodeproj
   ```

3. Build and run (`Cmd + R`).

## Attribution

ClaudeNotch is built on [BoringNotch](https://github.com/TheBoredTeam/boring.notch) by [TheBoredTeam](https://github.com/TheBoredTeam). The original project provides the notch UI framework, window management, and gesture system that ClaudeNotch extends.

For third-party license details, see [THIRD_PARTY_LICENSES](./THIRD_PARTY_LICENSES).

## License

[GNU General Public License v3.0](./LICENSE)
