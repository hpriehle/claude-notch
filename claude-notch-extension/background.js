// background.js - Service worker

const WS_URL = 'ws://localhost:8765';
let ws = null;
let reconnectTimer = null;
let lastUsageData = null;

function timestamp() {
  return new Date().toLocaleTimeString('en-US', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit', fractionalSecondDigits: 3 });
}

// Connect to ClaudeNotch app
function connect() {
  if (ws && ws.readyState === WebSocket.OPEN) {
    return;
  }

  try {
    ws = new WebSocket(WS_URL);

    ws.onopen = () => {
      console.log(`[ClaudeNotch ${timestamp()}] Connected to app`);
      clearReconnectTimer();

      // NOTE: Do NOT send cached lastUsageData on reconnect.
      // This can cause stale data to overwrite fresh data.
      // The content script will send fresh data on its next scrape interval.

      // Update popup status
      chrome.storage.local.set({ connected: true });
    };

    ws.onclose = () => {
      console.log(`[ClaudeNotch ${timestamp()}] Disconnected from app`);
      ws = null;
      chrome.storage.local.set({ connected: false });
      scheduleReconnect();
    };

    ws.onerror = (error) => {
      console.log(`[ClaudeNotch ${timestamp()}] WebSocket error:`, error);
      chrome.storage.local.set({ connected: false });
    };

    ws.onmessage = async (event) => {
      console.log(`[ClaudeNotch ${timestamp()}] Received:`, event.data);

      // Handle commands from Mac app
      try {
        const msg = JSON.parse(event.data);
        if (msg.type === 'REFRESH') {
          console.log(`[ClaudeNotch ${timestamp()}] Refresh requested by app`);
          await refreshClaudeTabs();
        }
      } catch (e) {
        // Not JSON or no type field, ignore
      }
    };

  } catch (error) {
    console.log(`[ClaudeNotch ${timestamp()}] Failed to connect:`, error);
    scheduleReconnect();
  }
}

function scheduleReconnect() {
  clearReconnectTimer();
  reconnectTimer = setTimeout(() => {
    connect();
  }, 5000); // Retry every 5 seconds
}

function clearReconnectTimer() {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
}

// Send data to ClaudeNotch app
function sendToApp(data) {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    console.log(`[ClaudeNotch ${timestamp()}] Not connected, queuing data`);
    lastUsageData = data;
    connect();
    return;
  }

  // Ensure all required fields are present
  const payload = {
    sessionPercent: data.sessionPercent ?? 0,
    weeklyAllPercent: data.weeklyAllPercent ?? 0,
    weeklySonnetPercent: data.weeklySonnetPercent ?? 0,
    sessionResetTime: data.sessionResetTime ?? new Date().toISOString(),
    weeklyAllResetTime: data.weeklyAllResetTime ?? new Date().toISOString(),
    weeklySonnetResetTime: data.weeklySonnetResetTime ?? new Date().toISOString(),
    accountType: data.accountType ?? 'Pro'
  };

  try {
    ws.send(JSON.stringify(payload));
    console.log(`[ClaudeNotch ${timestamp()}] Sent to app:`, payload);
    lastUsageData = data;
    chrome.storage.local.set({ lastSent: new Date().toISOString() });
  } catch (error) {
    console.log(`[ClaudeNotch ${timestamp()}] Send error:`, error);
  }
}

// Listen for messages from content script
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'USAGE_DATA') {
    sendToApp(message.data);
    sendResponse({ status: 'ok' });
  }
  return true;
});

// Connect on startup
connect();

// Keep alive
setInterval(() => {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    connect();
  }
}, 30000);

// ===========================================
// Tab Refresh for Usage Data
// ===========================================

const REFRESH_ALARM_NAME = 'refreshUsageData';
const DEFAULT_REFRESH_MINUTES = 5;

// Create alarm on startup for periodic refresh
chrome.alarms.create(REFRESH_ALARM_NAME, {
  periodInMinutes: DEFAULT_REFRESH_MINUTES
});

console.log(`[ClaudeNotch ${timestamp()}] Created refresh alarm (every ${DEFAULT_REFRESH_MINUTES} minutes)`);

// Handle alarm - refresh claude.ai tabs
chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name === REFRESH_ALARM_NAME) {
    console.log(`[ClaudeNotch ${timestamp()}] Alarm triggered - refreshing claude.ai tabs`);
    await refreshClaudeTabs();
  }
});

// Refresh claude.ai tabs so content script can scrape fresh data
async function refreshClaudeTabs() {
  try {
    const tabs = await chrome.tabs.query({ url: 'https://claude.ai/*' });

    if (tabs.length === 0) {
      console.log(`[ClaudeNotch ${timestamp()}] No claude.ai tabs to refresh`);
      return;
    }

    // Prefer usage page if open
    let targetTab = tabs.find(t => t.url.includes('/settings/usage'));
    if (!targetTab) {
      targetTab = tabs[0];
    }

    await chrome.tabs.reload(targetTab.id);
    console.log(`[ClaudeNotch ${timestamp()}] Reloaded tab: ${targetTab.url}`);
  } catch (error) {
    console.error(`[ClaudeNotch ${timestamp()}] Error refreshing tabs:`, error);
  }
}
