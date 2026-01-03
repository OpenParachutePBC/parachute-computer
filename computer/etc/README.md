# Parachute Service Installation

This directory contains service configuration files for running Parachute Base Server as a system service on macOS, Linux, and Windows.

## Quick Start (Current)

Before we have Homebrew/package manager support, use the CLI script:

```bash
cd base
./parachute.sh supervisor-bg   # Start with supervisor in background
./parachute.sh status          # Check status
./parachute.sh sup-stop        # Stop everything
```

---

## macOS

### Option 1: Homebrew (Future)

Once published to Homebrew:

```bash
brew install parachute
brew services start parachute
```

### Option 2: Manual launchd Setup (Now)

1. **Copy the plist file:**
   ```bash
   cp etc/macos-launchd/com.parachute.server.plist ~/Library/LaunchAgents/
   ```

2. **Edit paths** in the plist to match your installation:
   ```bash
   # Update ProgramArguments to point to your parachute installation
   # Update VAULT_PATH if not using ~/Parachute
   nano ~/Library/LaunchAgents/com.parachute.server.plist
   ```

3. **Load the service:**
   ```bash
   launchctl load ~/Library/LaunchAgents/com.parachute.server.plist
   ```

4. **Management commands:**
   ```bash
   # Start
   launchctl start com.parachute.server

   # Stop
   launchctl stop com.parachute.server

   # Unload (disable)
   launchctl unload ~/Library/LaunchAgents/com.parachute.server.plist

   # Check status
   launchctl list | grep parachute
   ```

---

## Linux (systemd)

### User Service (starts on login)

1. **Copy the service file:**
   ```bash
   mkdir -p ~/.config/systemd/user
   cp etc/linux-systemd/user/parachute.service ~/.config/systemd/user/
   ```

2. **Edit the service file** if needed (vault path, port, etc.):
   ```bash
   nano ~/.config/systemd/user/parachute.service
   ```

3. **Enable and start:**
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable parachute
   systemctl --user start parachute
   ```

4. **Management commands:**
   ```bash
   systemctl --user status parachute
   systemctl --user stop parachute
   systemctl --user restart parachute
   journalctl --user -u parachute -f   # View logs
   ```

### System Service (starts on boot, for servers)

1. **Copy the service file** (requires root):
   ```bash
   sudo cp etc/linux-systemd/system/parachute@.service /etc/systemd/system/
   ```

2. **Enable for a user:**
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable parachute@myusername
   sudo systemctl start parachute@myusername
   ```

---

## Windows

### Option 1: Task Scheduler

1. Open Task Scheduler (`taskschd.msc`)
2. Create Basic Task → Name: "Parachute Server"
3. Trigger: "At startup" or "At log on"
4. Action: Start a program
   - Program: `python`
   - Arguments: `-m parachute.server`
   - Start in: `C:\path\to\parachute\base`
5. Finish, then edit properties:
   - Check "Run whether user is logged on or not"
   - Uncheck "Stop task if it runs longer than"

### Option 2: NSSM (Non-Sucking Service Manager)

For server deployments:

```powershell
# Install NSSM
choco install nssm

# Install Parachute as a service
nssm install ParachuteServer "C:\Python313\python.exe" "-m parachute.server"
nssm set ParachuteServer AppDirectory "C:\path\to\parachute\base"
nssm set ParachuteServer AppEnvironmentExtra "VAULT_PATH=C:\Users\You\Parachute"

# Start the service
nssm start ParachuteServer
```

---

## Environment Variables

All platforms support these environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `VAULT_PATH` | `~/Parachute` | Path to knowledge vault |
| `PORT` | `3333` | Server port |
| `HOST` | `0.0.0.0` | Bind address |
| `LOG_LEVEL` | `INFO` | Logging verbosity |

---

## Supervisor vs Direct

**Direct mode** (`parachute-server`):
- Simpler, fewer moving parts
- Use with system service managers (launchd, systemd)
- They handle restarts

**Supervisor mode** (`parachute-supervisor`):
- Web UI at port 3330
- In-app control from Flutter app
- Use for development or when you want the web UI

For production, we recommend using the platform's native service manager with direct mode.

---

## Roadmap

- [ ] Publish Homebrew formula to tap
- [ ] Submit to homebrew-core
- [ ] Create Debian/Ubuntu package
- [ ] Create Arch Linux AUR package
- [ ] Windows installer with service option
- [ ] Flatpak/Snap for Linux desktop
