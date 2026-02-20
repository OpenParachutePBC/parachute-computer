# Testing Guide: Supervisor Service & Model Picker

> Manual testing instructions for PR #71 (Phases 1-3)

---

## Prerequisites

**Environment:**
- macOS or Linux (tested on macOS)
- Python 3.11+
- Flutter 3.x
- Valid `ANTHROPIC_API_KEY` environment variable

**Setup:**
```bash
# Ensure API key is set (supervisor uses same key as main server)
export ANTHROPIC_API_KEY="sk-ant-..."

# Navigate to project root
cd /Volumes/ExternalSSD/Parachute/Projects/parachute-computer
```

**Note:** As of this PR, the supervisor is **automatically installed** by `./install.sh` and `parachute update`. You no longer need to manually run `parachute supervisor install`.

---

## Phase 1: Supervisor Service (Backend)

### 1.1 Install or Update (Auto-installs Supervisor)

**Option A: Fresh install**
```bash
cd computer
./install.sh
```

**Option B: Update existing installation**
```bash
parachute update --local
```

**Expected output:**
```
Installing main server daemon...
  Main server daemon installed.
  Main server daemon started.
  Server running on port 3333

Installing supervisor daemon...
  Supervisor daemon installed.
  Supervisor daemon started.
  Supervisor running on port 3334

Done! Use 'parachute server status' to check the daemon.
Use 'parachute supervisor status' to check the supervisor.
```

**Verify both are running:**
```bash
parachute server status
parachute supervisor status
```

**Expected:**
```
Server Status: ● Running (PID: 12345)
Supervisor Status: ● Running (PID: 12346)
```

**Verify launchd plists exist (macOS):**
```bash
ls ~/Library/LaunchAgents/io.openparachute.parachute.plist
ls ~/Library/LaunchAgents/io.openparachute.supervisor.plist
```

### 1.2 Check Supervisor Health

```bash
curl -s http://localhost:3334/supervisor/status | jq
```

**Expected JSON:**
```json
{
  "supervisor_uptime_seconds": 10,
  "supervisor_version": "0.7.0",
  "main_server_healthy": true,
  "main_server_status": "running",
  "config_loaded": true
}
```

### 1.3 Test Server Control Endpoints

**Restart main server:**
```bash
curl -X POST http://localhost:3334/supervisor/server/restart
```

**Expected:**
```json
{"message": "Server restart initiated"}
```

**Check main server came back up:**
```bash
curl http://localhost:3333/api/health
```

**Expected:**
```json
{"status": "healthy", "version": "0.7.0"}
```

### 1.4 Test Log Streaming

```bash
curl -N http://localhost:3334/supervisor/logs
```

**Expected:** SSE stream with log lines, API keys/tokens redacted:
```
data: {"timestamp": "2026-02-18T10:30:00", "level": "info", "message": "Server started on port 3333"}
data: {"timestamp": "2026-02-18T10:30:01", "level": "info", "message": "API key: [REDACTED]"}
```

Press `Ctrl+C` to stop stream.

### 1.5 Test Config Endpoint

**Read config:**
```bash
curl -s http://localhost:3334/supervisor/config | jq
```

**Expected:** Config with secrets redacted:
```json
{
  "server": {
    "port": 3333,
    "host": "127.0.0.1"
  },
  "api_key": "[REDACTED]",
  "anthropic_api_key": "[REDACTED]"
}
```

---

## Phase 2: Models API

### 2.1 Test Models Endpoint (Latest Only)

```bash
curl -s "http://localhost:3334/supervisor/models" | jq
```

**Expected:** List of latest Claude models per family:
```json
{
  "models": [
    {
      "id": "claude-opus-4-6",
      "display_name": "Claude Opus 4.6",
      "created_at": "2025-01-15T00:00:00Z",
      "family": "opus",
      "is_latest": true
    },
    {
      "id": "claude-sonnet-4-5-20250929",
      "display_name": "Claude Sonnet 4.5",
      "created_at": "2024-09-29T00:00:00Z",
      "family": "sonnet",
      "is_latest": true
    },
    {
      "id": "claude-haiku-4-5-20251001",
      "display_name": "Claude Haiku 4.5",
      "created_at": "2024-10-01T00:00:00Z",
      "family": "haiku",
      "is_latest": true
    }
  ],
  "current_model": null,
  "cache_metadata": {
    "cached_at": "2026-02-18T10:30:00Z",
    "is_stale": false
  }
}
```

**Verify:**
- Only latest models shown (3-4 models total)
- `is_latest: true` for all
- Cache metadata present

### 2.2 Test Models Endpoint (Show All)

```bash
curl -s "http://localhost:3334/supervisor/models?show_all=true" | jq '.models | length'
```

**Expected:** More models (10-15), including dated versions:
```
12
```

**Verify:**
```bash
curl -s "http://localhost:3334/supervisor/models?show_all=true" | jq '.models[] | select(.is_latest == false) | .id' | head -3
```

**Expected:** Older model versions shown:
```
"claude-opus-3-5"
"claude-sonnet-3-5-20240620"
"claude-haiku-3-5-20241022"
```

### 2.3 Test Cache Behavior

**First request (fresh):**
```bash
curl -s "http://localhost:3334/supervisor/models" | jq '.cache_metadata.is_stale'
```
**Expected:** `false`

**Wait 5 seconds, request again (still cached):**
```bash
sleep 5
curl -s "http://localhost:3334/supervisor/models" | jq '.cache_metadata.is_stale'
```
**Expected:** Still `false` (cache TTL is 1 hour)

---

## Phase 3: Flutter UI

### 3.1 Start Flutter App

```bash
cd ../app
flutter run -d macos
```

**Expected:** App launches on macOS desktop.

### 3.2 Navigate to Settings

1. Click the **Settings** tab in the bottom navigation bar
2. Scroll down to the **Model** section

**Expected:** You should see the **ModelPickerDropdown** widget (not the old static dropdown).

**Identifying the dynamic picker:**
- Has a **refresh icon button** in the header (top right)
- Shows model names from Anthropic API (e.g., "Claude Opus 4.6")
- Has a **"Show all model versions"** checkbox below the dropdown
- May show a loading spinner briefly on first load

### 3.3 Test Model List Loading

**Expected state on first load:**
- Loading spinner appears briefly (< 1 second)
- Dropdown populates with latest models (3-4 options)
- Each model shows:
  - Display name (e.g., "Claude Sonnet 4.5")
  - "Latest" badge (green, small)
  - Family label (e.g., "Balanced", "Most capable", "Fastest")

**Verify dropdown items:**
- Claude Opus → "Most capable"
- Claude Sonnet → "Balanced"
- Claude Haiku → "Fastest"

### 3.4 Test "Show All" Toggle

1. Check the **"Show all model versions"** checkbox
2. Wait for dropdown to reload (brief spinner)

**Expected:**
- Dropdown now shows 10-15 models
- Older versions appear (e.g., "Claude Opus 3.5", "Claude Sonnet 3.5 20240620")
- Only latest models have the "Latest" badge
- Can scroll through all options

3. Uncheck the box

**Expected:**
- Dropdown filters back to 3-4 latest models

### 3.5 Test Model Selection

1. Open the dropdown
2. Select a different model (e.g., switch from Sonnet to Haiku)
3. Click to select

**Expected:**
- Snackbar appears: "Model updated to Claude Haiku 4.5"
- Dropdown updates to show selected model
- Behind the scenes:
  - PUT request sent to `/supervisor/config`
  - Config file updated atomically
  - Main server restarted (may cause brief reconnect)

**Verify config was updated:**
```bash
# In terminal
curl -s http://localhost:3334/supervisor/config | jq '.default_model'
```
**Expected:** New model ID (e.g., `"claude-haiku-4-5-20251001"`)

### 3.6 Test Refresh Button

1. Click the **refresh icon** in the Model section header
2. Watch for brief loading state

**Expected:**
- Dropdown shows loading spinner
- Models reload from API (cache refreshed)
- Dropdown repopulates with same models (if no upstream changes)

### 3.7 Test Supervisor Status Auto-Refresh

1. Keep Settings screen open
2. Watch the supervisor status in the Model section

**Expected:**
- Status auto-refreshes every 5 seconds
- No user action needed
- If you stop/start the supervisor in terminal, UI reflects this within 5s

**Manual test:**
```bash
# In terminal
parachute supervisor stop
```

**Expected in app (within 5s):**
- Model picker switches back to static `ModelSelectionSection`
- Static dropdown shows hardcoded models (Opus, Sonnet, Haiku)

**Restart supervisor:**
```bash
parachute supervisor start
```

**Expected in app (within 5s):**
- Switches back to dynamic `ModelPickerDropdown`
- Shows models from API again

### 3.8 Test Error States

**Simulate network error (disconnect WiFi or firewall block port 3334):**

**Expected:**
- Dropdown shows error state:
  ```
  ⚠️ Failed to load models: [error message]
  ```
- App doesn't crash
- Static fallback doesn't activate (error is within dynamic picker)

**Reconnect network:**
- Click refresh button
- Models load successfully

---

## Verification Checklist

### Backend (Phase 1 & 2)
- [ ] Supervisor daemon installs and starts
- [ ] Supervisor status endpoint works
- [ ] Server control (start/stop/restart) works
- [ ] Log streaming works with redaction
- [ ] Config endpoint redacts secrets
- [ ] Models endpoint returns latest models
- [ ] `show_all=true` returns all models
- [ ] Cache behavior (1-hour TTL, stale fallback)

### Frontend (Phase 3)
- [ ] Model picker appears in Settings
- [ ] Refresh button works
- [ ] "Show all" toggle works
- [ ] Model selection updates config
- [ ] Snackbar confirmation appears
- [ ] Status auto-refreshes every 5s
- [ ] Falls back to static picker when supervisor down
- [ ] Error states handled gracefully

---

## Known Issues / Limitations

1. **Supervisor must be running for dynamic picker**
   - If supervisor is down, static picker is shown
   - This is expected behavior (graceful degradation)

2. **Model selection restarts main server**
   - Brief reconnect delay (1-2 seconds)
   - Chat conversations should resume automatically

3. **Cache TTL is 1 hour**
   - Models list refreshes hourly
   - Manual refresh available via button
   - Stale cache used if API fails

---

## Cleanup (After Testing)

```bash
# Stop supervisor
parachute supervisor stop

# Uninstall daemon (optional)
parachute supervisor uninstall

# Remove test config changes (optional)
git checkout computer/.parachute/config.yaml
```

---

## Troubleshooting

### Supervisor won't start
```bash
# Check logs
parachute logs supervisor

# Check if port 3334 is in use
lsof -i :3334

# Kill existing process
kill -9 <PID>

# Restart
parachute supervisor restart
```

### Models API returns empty list
```bash
# Verify API key is set
echo $ANTHROPIC_API_KEY

# Test Anthropic API directly
curl -H "x-api-key: $ANTHROPIC_API_KEY" \
     -H "anthropic-version: 2023-06-01" \
     https://api.anthropic.com/v1/models
```

### Flutter app doesn't show dynamic picker
```bash
# Verify supervisor is running
curl http://localhost:3334/supervisor/status

# Check Flutter console for errors
# Look for Dio connection errors or provider errors

# Rebuild with latest code
cd app
flutter clean
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run -d macos
```

---

## Success Criteria

✅ **Phase 1 complete** when:
- Supervisor runs as daemon on port 3334
- Can control main server lifecycle
- Logs stream with redaction
- Config updates work atomically

✅ **Phase 2 complete** when:
- Models endpoint returns Claude model list
- Latest-only filtering works
- Show-all mode works
- Cache reduces API calls (verify with logs)

✅ **Phase 3 complete** when:
- Model picker appears in Settings
- Dropdown populates from API
- Model selection updates config & restarts server
- Graceful fallback when supervisor unavailable
