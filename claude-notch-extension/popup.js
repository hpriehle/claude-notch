// popup.js

function updateStatus() {
  chrome.storage.local.get(['connected', 'lastSent'], (result) => {
    const dot = document.getElementById('statusDot');
    const text = document.getElementById('statusText');
    const lastSent = document.getElementById('lastSent');

    if (result.connected) {
      dot.className = 'dot connected';
      text.textContent = 'Connected to ClaudeNotch';
    } else {
      dot.className = 'dot disconnected';
      text.textContent = 'Not connected';
    }

    if (result.lastSent) {
      const date = new Date(result.lastSent);
      lastSent.textContent = `Last update: ${date.toLocaleTimeString()}`;
    } else {
      lastSent.textContent = 'No data sent yet';
    }
  });
}

updateStatus();
setInterval(updateStatus, 1000);
