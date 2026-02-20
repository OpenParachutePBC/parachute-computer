# UI Testing Guide: Model Picker & Supervisor

Quick guide for testing the new dynamic model picker in the Parachute app.

---

## Prerequisites

**Ensure supervisor is running:**
```bash
parachute supervisor status
# If not running:
parachute supervisor start
```

**Get latest code on computer:**
```bash
cd /Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer
parachute update
```

**Deploy to Android (if testing mobile):**
```bash
cd ../app
export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
bash scripts/deploy.sh --connect 100.114.25.16:43291
```

---

## Test 1: Model Picker Appears

**Steps:**
1. Open Parachute app
2. Navigate to **Settings** tab
3. Scroll to **Model** section

**Expected:**
- Section header shows "Model" with smart_toy icon
- **Refresh button (↻)** appears in top-right of section
- Dropdown shows current model
- **"Show all model versions" checkbox** appears below dropdown

**If you see this → dynamic picker is working ✓**

**If you see static dropdown (just Opus/Sonnet/Haiku with no refresh button):**
- Supervisor isn't running or not responding
- Check: `curl http://localhost:3334/supervisor/status`

---

## Test 2: Model List Loads

**Steps:**
1. Open the model dropdown

**Expected:**
- Shows 3-4 models (latest per family):
  - Claude Opus 4.6 — "Most capable" — **Latest** badge
  - Claude Sonnet 4.5 — "Balanced" — **Latest** badge
  - Claude Haiku 4.5 — "Fastest" — **Latest** badge
- Each model has display name, family label, and green "Latest" badge

**Loading state:**
- Brief spinner when first opening Settings
- If slow network, shows loading spinner in dropdown area

---

## Test 3: Show All Models Toggle

**Steps:**
1. Check the **"Show all model versions"** checkbox
2. Wait for dropdown to reload (~1s)
3. Open dropdown again

**Expected:**
- Now shows 10-15+ models including older versions
- Dated models appear (e.g., "Claude Sonnet 3.5 20240620")
- Only latest models have "Latest" badge
- Can scroll through full list

**Uncheck the box:**
- Filters back to 3-4 latest models

---

## Test 4: Select a Model

**Steps:**
1. Open dropdown
2. Select a different model (e.g., Claude Haiku 4.5)
3. Tap to confirm

**Expected:**
1. Dropdown closes and shows new selection
2. Snackbar appears: **"Model updated to Claude Haiku 4.5"**
3. Main server restarts in background (~2-3s)
4. Model selection persists after app restart

**Verify it worked:**
```bash
curl http://localhost:3334/supervisor/config | jq '.default_model'
# Should show: "claude-haiku-4-5-20251001"
```

---

## Test 5: Refresh Button

**Steps:**
1. Click the **↻ refresh icon** in Model section header
2. Watch dropdown

**Expected:**
- Brief loading state
- Models reload from Anthropic API
- List repopulates (should be same unless Anthropic released new models)

**When it's useful:**
- After Anthropic releases a new model
- If list seems stale (cache is 1 hour)

---

## Test 6: Auto-Refresh Status

**Steps:**
1. Keep Settings screen open
2. Wait 5+ seconds

**Expected:**
- Supervisor status auto-refreshes every 5s
- No visible change (unless something breaks)

**Test the fallback:**
```bash
# Stop supervisor
parachute supervisor stop
```

**In app (within 5s):**
- Model section switches to **static picker**
- No more refresh button
- Just hardcoded Opus/Sonnet/Haiku options

```bash
# Restart supervisor
parachute supervisor start
```

**In app (within 5s):**
- Switches back to **dynamic picker**
- Refresh button reappears
- Models load from API

---

## Test 7: Error Handling

**Simulate network error:**
```bash
# Kill supervisor
parachute supervisor stop
```

**In app:**
- Should fall back to static picker gracefully
- No crash, no blank screen

**Simulate API failure:**
```bash
# Unset API key temporarily
mv ~/.parachute/.token ~/.parachute/.token.bak
parachute supervisor restart
```

**In app:**
- Dropdown shows error state: "⚠️ Failed to load models: [error]"
- Doesn't crash

**Restore:**
```bash
mv ~/.parachute/.token.bak ~/.parachute/.token
parachute supervisor restart
```

---

## Test 8: Model Selection Actually Works

**Steps:**
1. Note current model in dropdown
2. Select Haiku
3. Wait for snackbar confirmation
4. Start a new chat
5. Ask a simple question

**Expected:**
- Chat uses Haiku (faster, shorter responses)
- No errors

**Verify in logs:**
```bash
parachute logs | grep -i "model"
```

Should show: `Using model: claude-haiku-4-5-20251001`

---

## Common Issues

### Dropdown shows error "Failed to load models"
**Cause:** No ANTHROPIC_API_KEY or API error
**Fix:**
```bash
export ANTHROPIC_API_KEY="sk-ant-..."
parachute supervisor restart
```

### Static picker shows instead of dynamic
**Cause:** Supervisor not running
**Fix:**
```bash
parachute supervisor status
parachute supervisor start
```

### Model selection doesn't persist
**Cause:** Config not saving or server not restarting
**Check:**
```bash
curl http://localhost:3334/supervisor/config | jq '.default_model'
parachute status
```

### Snackbar doesn't appear
**Cause:** Flutter UI issue (not critical)
**Impact:** Model still updates in background, just no visual confirmation

---

## Success Criteria

✅ Dynamic picker appears when supervisor is running
✅ Shows latest models from Anthropic API
✅ "Show all" toggle works
✅ Refresh button reloads from API
✅ Model selection updates config and restarts server
✅ Snackbar confirms selection
✅ Falls back to static picker when supervisor unavailable
✅ No crashes on errors
✅ Status auto-refreshes every 5s

---

## Commands Reference

```bash
# Supervisor management
parachute supervisor status
parachute supervisor start
parachute supervisor stop
parachute supervisor restart

# Server management
parachute server restart
parachute status

# Check supervisor API
curl http://localhost:3334/supervisor/status
curl http://localhost:3334/supervisor/models

# Deploy to Android
cd app
export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
bash scripts/deploy.sh --connect <ip:port>
```

---

## Next Steps After Testing

If everything works:
1. Test on macOS desktop (`flutter run -d macos`)
2. Test on iOS (if available)
3. Verify model changes actually affect chat responses
4. Check that supervisor survives across app restarts
5. Merge PR #71

If issues found:
- Report in PR with screenshots
- Include logs: `parachute logs`
- Include supervisor status: `parachute supervisor status`
