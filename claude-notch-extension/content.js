// content.js - Injected into claude.ai pages

(function() {
  'use strict';

  const SCRAPE_INTERVAL = 10000; // 10 seconds for faster updates
  let lastData = null;
  let lastSendTime = 0;
  const FORCE_SEND_INTERVAL = 30000; // Force send every 30 seconds even if unchanged

  function timestamp() {
    return new Date().toLocaleTimeString('en-US', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit', fractionalSecondDigits: 3 });
  }

  // Extract usage data from the page
  function scrapeUsageData() {
    const data = {
      sessionPercent: null,
      weeklyAllPercent: null,
      weeklySonnetPercent: null,
      sessionResetTime: null,
      weeklyAllResetTime: null,
      weeklySonnetResetTime: null,
      accountType: null
    };

    // Look for usage elements on the page
    // The claude.ai settings page has elements like:
    // - "45% used" for current session
    // - "27% used" for all models
    // - "0% used" for Sonnet only
    // - "Resets in 2 hr 12 min" or "Resets Tue 9:00 AM"

    // Find all text containing "% used"
    const allText = document.body.innerText;

    // Try to find the usage section
    const usageSection = document.querySelector('[data-testid="usage-limits"]')
      || findUsageSection();

    if (usageSection) {
      // Parse session usage
      const sessionMatch = parseUsageBlock(usageSection, 'session');
      if (sessionMatch) {
        data.sessionPercent = sessionMatch.percent;
        data.sessionResetTime = sessionMatch.resetTime;
      }

      // Parse weekly all models
      const weeklyAllMatch = parseUsageBlock(usageSection, 'all models');
      if (weeklyAllMatch) {
        data.weeklyAllPercent = weeklyAllMatch.percent;
        data.weeklyAllResetTime = weeklyAllMatch.resetTime;
      }

      // Parse weekly Sonnet
      const sonnetMatch = parseUsageBlock(usageSection, 'sonnet');
      if (sonnetMatch) {
        data.weeklySonnetPercent = sonnetMatch.percent;
        data.weeklySonnetResetTime = sonnetMatch.resetTime;
      }
    }

    // Fallback: regex the whole page
    if (data.sessionPercent === null) {
      const percentMatches = allText.match(/(\d+)%\s*used/gi);
      if (percentMatches && percentMatches.length >= 1) {
        // First match is usually session
        data.sessionPercent = parseInt(percentMatches[0]);
        if (percentMatches.length >= 2) {
          data.weeklyAllPercent = parseInt(percentMatches[1]);
        }
        if (percentMatches.length >= 3) {
          data.weeklySonnetPercent = parseInt(percentMatches[2]);
        }
      }
    }

    // Detect account type
    if (allText.includes('Max')) {
      data.accountType = 'Max';
    } else if (allText.includes('Pro')) {
      data.accountType = 'Pro';
    } else {
      data.accountType = 'Free';
    }

    return data;
  }

  function findUsageSection() {
    // Look for common patterns in the usage UI
    const headings = document.querySelectorAll('h1, h2, h3, h4');
    for (const h of headings) {
      if (h.textContent.toLowerCase().includes('usage')
          || h.textContent.toLowerCase().includes('limit')) {
        return h.closest('section') || h.parentElement;
      }
    }
    return null;
  }

  function parseUsageBlock(container, label) {
    const text = container.innerText.toLowerCase();
    const labelIndex = text.indexOf(label.toLowerCase());
    if (labelIndex === -1) return null;

    // Find percentage near this label
    const nearbyText = text.slice(labelIndex, labelIndex + 200);
    const percentMatch = nearbyText.match(/(\d+)%/);

    // Find reset time
    let resetTime = null;
    const resetMatch = nearbyText.match(/resets?\s+(?:in\s+)?(.+?)(?:\n|$)/i);
    if (resetMatch) {
      resetTime = parseResetTime(resetMatch[1]);
    }

    return {
      percent: percentMatch ? parseInt(percentMatch[1]) : null,
      resetTime: resetTime
    };
  }

  function parseResetTime(timeStr) {
    // Convert relative time strings to ISO-8601
    const now = new Date();

    // "2 hr 12 min" format
    const relativeMatch = timeStr.match(/(\d+)\s*hr?\s*(\d+)?\s*min?/i);
    if (relativeMatch) {
      const hours = parseInt(relativeMatch[1]) || 0;
      const minutes = parseInt(relativeMatch[2]) || 0;
      const reset = new Date(now.getTime() + (hours * 60 + minutes) * 60 * 1000);
      return reset.toISOString();
    }

    // "Tue 9:00 AM" format
    const dayMatch = timeStr.match(/(mon|tue|wed|thu|fri|sat|sun)\w*\s+(\d+):(\d+)\s*(am|pm)/i);
    if (dayMatch) {
      const dayNames = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
      const targetDay = dayNames.findIndex(d => dayMatch[1].toLowerCase().startsWith(d));
      let hours = parseInt(dayMatch[2]);
      const minutes = parseInt(dayMatch[3]);
      const isPM = dayMatch[4].toLowerCase() === 'pm';

      if (isPM && hours !== 12) hours += 12;
      if (!isPM && hours === 12) hours = 0;

      const reset = new Date(now);
      const currentDay = now.getDay();
      let daysUntil = targetDay - currentDay;
      if (daysUntil <= 0) daysUntil += 7;

      reset.setDate(reset.getDate() + daysUntil);
      reset.setHours(hours, minutes, 0, 0);
      return reset.toISOString();
    }

    return null;
  }

  // Send data to background script
  function sendData(data, force = false) {
    const now = Date.now();
    const dataChanged = JSON.stringify(data) !== JSON.stringify(lastData);
    const shouldForceSend = (now - lastSendTime) >= FORCE_SEND_INTERVAL;

    if (!dataChanged && !force && !shouldForceSend) {
      return; // No change and not time for force send
    }

    lastData = data;
    lastSendTime = now;

    chrome.runtime.sendMessage({
      type: 'USAGE_DATA',
      data: data
    });

    console.log(`[ClaudeNotch ${timestamp()}] Sent usage data:`, data, dataChanged ? '(changed)' : '(periodic)');
  }

  // Main loop
  function startScraping() {
    // Initial scrape
    const data = scrapeUsageData();
    if (data.sessionPercent !== null || data.weeklyAllPercent !== null) {
      sendData(data);
    }

    // Periodic scrape
    setInterval(() => {
      const data = scrapeUsageData();
      if (data.sessionPercent !== null || data.weeklyAllPercent !== null) {
        sendData(data);
      }
    }, SCRAPE_INTERVAL);

    // Also scrape on page visibility change
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) {
        setTimeout(() => {
          const data = scrapeUsageData();
          if (data.sessionPercent !== null || data.weeklyAllPercent !== null) {
            sendData(data);
          }
        }, 1000);
      }
    });
  }

  // Wait for page to fully load
  if (document.readyState === 'complete') {
    startScraping();
  } else {
    window.addEventListener('load', startScraping);
  }
})();
