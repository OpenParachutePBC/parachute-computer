#!/bin/bash
#
# Parachute Server Management Script
#
# Usage:
#   ./parachute.sh start     - Start the server (direct, no supervisor)
#   ./parachute.sh stop      - Stop the server
#   ./parachute.sh restart   - Restart the server
#   ./parachute.sh status    - Check server status
#   ./parachute.sh logs      - Tail server logs
#   ./parachute.sh supervisor - Start with supervisor (includes web UI)
#   ./parachute.sh setup     - Set up virtual environment and dependencies
#   ./parachute.sh help      - Show this help
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration - resolve symlinks to get actual script directory
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_SOURCE" ]; do
    SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    [[ $SCRIPT_SOURCE != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
VAULT_PATH="${VAULT_PATH:-$HOME/Parachute}"
SERVER_PORT="${SERVER_PORT:-3333}"
SUPERVISOR_PORT="${SUPERVISOR_PORT:-3330}"
PID_FILE="/tmp/parachute-server.pid"
LOG_FILE="/tmp/parachute-server.log"

# Test server configuration (separate from main server)
TEST_SERVER_PORT="${TEST_SERVER_PORT:-3334}"
TEST_VAULT_PATH="${TEST_VAULT_PATH:-/tmp/parachute-test}"
TEST_PID_FILE="/tmp/parachute-test-server.pid"
TEST_LOG_FILE="/tmp/parachute-test-server.log"

# Print banner
banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║              🪂 Parachute Server Manager                      ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Check if server is running
is_running() {
    if lsof -ti:$SERVER_PORT > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Get server PID
get_pid() {
    lsof -ti:$SERVER_PORT 2>/dev/null || echo ""
}

# Check if supervisor is running
is_supervisor_running() {
    if lsof -ti:$SUPERVISOR_PORT > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Check if venv exists
has_venv() {
    [[ -f "$SCRIPT_DIR/venv/bin/activate" ]]
}

# Check if existing venv has compatible Python version (3.10-3.13)
# Returns 0 if compatible, 1 if not
venv_python_compatible() {
    if ! has_venv; then
        return 1
    fi

    local venv_python="$SCRIPT_DIR/venv/bin/python"
    if [[ ! -x "$venv_python" ]]; then
        return 1
    fi

    local version=$("$venv_python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
    if [[ -z "$version" ]]; then
        return 1
    fi

    local major=$(echo "$version" | cut -d. -f1)
    local minor=$(echo "$version" | cut -d. -f2)

    if [[ "$major" == "3" ]] && [[ "$minor" -ge 10 ]] && [[ "$minor" -le 13 ]]; then
        return 0
    fi

    return 1
}

# Set up virtual environment and install dependencies
cmd_setup() {
    echo -e "${BLUE}Setting up Parachute server...${NC}"
    cd "$SCRIPT_DIR"

    # Use PYTHON_PATH if provided (from Flutter app's validated path)
    # Otherwise find best Python version (prefer newest compatible: 3.10-3.13)
    local PYTHON=""
    if [[ -n "$PYTHON_PATH" ]] && [[ -x "$PYTHON_PATH" ]]; then
        PYTHON="$PYTHON_PATH"
        echo -e "  Using Python from PYTHON_PATH: $PYTHON"
    else
        for py in python3.13 python3.12 python3.11 python3.10; do
            if command -v $py &> /dev/null; then
                PYTHON=$py
                break
            fi
        done

        # Fall back to python3 if no specific version found
        if [[ -z "$PYTHON" ]]; then
            if command -v python3 &> /dev/null; then
                PYTHON=python3
            else
                echo -e "${RED}Error: Python 3.10-3.13 not found. Please install Python via Homebrew:${NC}"
                echo -e "  brew install python@3.13"
                exit 1
            fi
        fi
    fi

    # Verify Python version is compatible (3.10-3.13)
    local python_version=$($PYTHON -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    local major=$(echo $python_version | cut -d. -f1)
    local minor=$(echo $python_version | cut -d. -f2)

    if [[ "$major" != "3" ]] || [[ "$minor" -lt 10 ]] || [[ "$minor" -gt 13 ]]; then
        echo -e "${RED}Error: Python $python_version is not compatible.${NC}"
        echo -e "  Parachute requires Python 3.10-3.13 (3.14+ is too new)."
        echo -e "  Install a compatible version: brew install python@3.13"
        exit 1
    fi

    local python_version=$($PYTHON -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    echo -e "  Python: $PYTHON (version $python_version)"

    # Create venv if needed, or recreate if Python version is incompatible
    if has_venv; then
        if venv_python_compatible; then
            echo -e "${YELLOW}  Virtual environment already exists (Python compatible)${NC}"
        else
            local old_version=$("$SCRIPT_DIR/venv/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "unknown")
            echo -e "${YELLOW}  Existing venv has incompatible Python ($old_version), recreating...${NC}"
            rm -rf "$SCRIPT_DIR/venv"
            echo -e "  Creating virtual environment with $PYTHON..."
            $PYTHON -m venv "$SCRIPT_DIR/venv"
            echo -e "${GREEN}  ✓ Virtual environment recreated${NC}"
        fi
    else
        echo -e "  Creating virtual environment..."
        $PYTHON -m venv "$SCRIPT_DIR/venv"
        echo -e "${GREEN}  ✓ Virtual environment created${NC}"
    fi

    # Activate and install dependencies
    source "$SCRIPT_DIR/venv/bin/activate"

    echo -e "  Installing dependencies..."
    pip install --quiet --upgrade pip
    pip install --quiet -r "$SCRIPT_DIR/requirements.txt"

    echo -e "${GREEN}✓ Setup complete!${NC}"
    echo ""
    echo -e "Run ${CYAN}./parachute.sh start${NC} to start the server"
}

# Ensure venv exists, set it up if not
ensure_venv() {
    if ! has_venv; then
        echo -e "${YELLOW}Virtual environment not found. Setting up...${NC}"
        cmd_setup
    fi

    # Activate venv if not already
    if [[ -z "$VIRTUAL_ENV" ]]; then
        source "$SCRIPT_DIR/venv/bin/activate"
    fi
}

# Start server (direct mode)
cmd_start() {
    echo -e "${BLUE}Starting Parachute server...${NC}"

    if is_running; then
        local pid=$(get_pid)
        echo -e "${YELLOW}Server already running (PID: $pid)${NC}"
        echo -e "  Port: $SERVER_PORT"
        echo -e "  URL:  http://localhost:$SERVER_PORT"
        return 0
    fi

    # Ensure venv is set up
    ensure_venv

    # Start server in background
    cd "$SCRIPT_DIR"
    VAULT_PATH="$VAULT_PATH" nohup "$SCRIPT_DIR/venv/bin/python" -m parachute.server > "$LOG_FILE" 2>&1 &
    local pid=$!
    echo $pid > "$PID_FILE"

    # Wait for server to start (context watch scanning can take 30+ seconds)
    echo -n "Waiting for server"
    for i in {1..60}; do
        if is_running; then
            echo ""
            echo -e "${GREEN}✓ Server started successfully${NC}"
            echo -e "  PID:   $(get_pid)"
            echo -e "  Port:  $SERVER_PORT"
            echo -e "  Vault: $VAULT_PATH"
            echo -e "  URL:   ${CYAN}http://localhost:$SERVER_PORT${NC}"
            echo -e "  Logs:  $LOG_FILE"
            return 0
        fi
        echo -n "."
        sleep 0.5
    done

    echo ""
    echo -e "${RED}✗ Failed to start server${NC}"
    echo "Check logs: tail -f $LOG_FILE"
    return 1
}

# Run server in foreground (for launchd/systemd)
cmd_run() {
    # Ensure venv is set up
    ensure_venv

    cd "$SCRIPT_DIR"
    # Use explicit path to venv python (needed for launchd)
    exec "$SCRIPT_DIR/venv/bin/python" -m parachute.server
}

# Stop server
cmd_stop() {
    echo -e "${BLUE}Stopping Parachute server...${NC}"

    if ! is_running; then
        echo -e "${YELLOW}Server is not running${NC}"
        return 0
    fi

    local pid=$(get_pid)
    echo "Stopping process $pid..."

    # Try graceful shutdown first
    kill $pid 2>/dev/null || true

    # Wait for it to stop
    for i in {1..10}; do
        if ! is_running; then
            echo -e "${GREEN}✓ Server stopped${NC}"
            rm -f "$PID_FILE"
            return 0
        fi
        sleep 0.5
    done

    # Force kill if still running
    echo "Force killing..."
    kill -9 $pid 2>/dev/null || true
    lsof -ti:$SERVER_PORT | xargs kill -9 2>/dev/null || true

    rm -f "$PID_FILE"
    echo -e "${GREEN}✓ Server stopped${NC}"
}

# Restart server
cmd_restart() {
    echo -e "${BLUE}Restarting Parachute server...${NC}"
    cmd_stop
    sleep 1
    cmd_start
}

# Check status
cmd_status() {
    echo -e "${BLUE}Parachute Server Status${NC}"
    echo "────────────────────────────────────────"

    if is_running; then
        local pid=$(get_pid)
        echo -e "  Server:     ${GREEN}● Running${NC}"
        echo -e "  PID:        $pid"
        echo -e "  Port:       $SERVER_PORT"
        echo -e "  URL:        http://localhost:$SERVER_PORT"

        # Try to get health info
        if command -v curl &> /dev/null; then
            local health=$(curl -s "http://localhost:$SERVER_PORT/api/health" 2>/dev/null || echo "")
            if [[ -n "$health" ]]; then
                echo -e "  Health:     ${GREEN}OK${NC}"
            fi
        fi
    else
        echo -e "  Server:     ${RED}○ Stopped${NC}"
    fi

    echo ""

    if is_supervisor_running; then
        echo -e "  Supervisor: ${GREEN}● Running${NC}"
        echo -e "  UI:         http://localhost:$SUPERVISOR_PORT"
    else
        echo -e "  Supervisor: ${YELLOW}○ Not running${NC}"
    fi

    echo ""
    echo -e "  Vault:      $VAULT_PATH"
    echo -e "  Logs:       $LOG_FILE"

    # Show venv status
    if has_venv; then
        echo -e "  Venv:       ${GREEN}✓ Installed${NC}"
    else
        echo -e "  Venv:       ${YELLOW}○ Not set up${NC} (run ./parachute.sh setup)"
    fi

    echo "────────────────────────────────────────"
}

# View logs
cmd_logs() {
    if [[ -f "$LOG_FILE" ]]; then
        echo -e "${BLUE}Tailing server logs (Ctrl+C to exit)...${NC}"
        tail -f "$LOG_FILE"
    else
        echo -e "${YELLOW}No log file found at $LOG_FILE${NC}"
        echo "Start the server first: ./parachute.sh start"
    fi
}

# Start with supervisor (foreground)
cmd_supervisor() {
    _start_supervisor false
}

# Start with supervisor (background)
cmd_supervisor_bg() {
    _start_supervisor true
}

# Internal: start supervisor
_start_supervisor() {
    local background="${1:-false}"

    echo -e "${BLUE}Starting Parachute with Supervisor...${NC}"

    if is_supervisor_running; then
        echo -e "${YELLOW}Supervisor already running on port $SUPERVISOR_PORT${NC}"
        echo -e "  Web UI: http://localhost:$SUPERVISOR_PORT"
        return 0
    fi

    # Stop any existing server first (supervisor will manage its own)
    if is_running; then
        echo -e "${YELLOW}Stopping existing server (supervisor will manage it)...${NC}"
        cmd_stop
    fi

    # Ensure venv is set up
    ensure_venv

    cd "$SCRIPT_DIR"
    echo -e "${GREEN}Starting supervisor...${NC}"
    echo -e "  Server Port:     $SERVER_PORT"
    echo -e "  Supervisor Port: $SUPERVISOR_PORT"
    echo -e "  Vault:           $VAULT_PATH"
    echo ""
    echo -e "  Web UI: ${CYAN}http://localhost:$SUPERVISOR_PORT${NC}"
    echo ""

    if [[ "$background" == "true" ]]; then
        VAULT_PATH="$VAULT_PATH" \
        SERVER_PORT="$SERVER_PORT" \
        SUPERVISOR_PORT="$SUPERVISOR_PORT" \
        nohup python -m supervisor.main > /tmp/parachute-supervisor.log 2>&1 &

        # Wait for supervisor to start
        echo -n "Waiting for supervisor"
        for i in {1..20}; do
            if is_supervisor_running; then
                echo ""
                echo -e "${GREEN}✓ Supervisor started in background${NC}"
                echo -e "  Logs: /tmp/parachute-supervisor.log"
                return 0
            fi
            echo -n "."
            sleep 0.5
        done
        echo ""
        echo -e "${RED}✗ Failed to start supervisor${NC}"
        return 1
    else
        VAULT_PATH="$VAULT_PATH" \
        SERVER_PORT="$SERVER_PORT" \
        SUPERVISOR_PORT="$SUPERVISOR_PORT" \
        python -m supervisor.main
    fi
}

# Stop supervisor
cmd_supervisor_stop() {
    echo -e "${BLUE}Stopping Supervisor...${NC}"

    if is_supervisor_running; then
        lsof -ti:$SUPERVISOR_PORT | xargs kill -9 2>/dev/null || true
        echo -e "${GREEN}✓ Supervisor stopped${NC}"
    else
        echo -e "${YELLOW}Supervisor is not running${NC}"
    fi

    # Also stop server if running
    if is_running; then
        cmd_stop
    fi
}

# Service management (for development - uses launchctl directly)
PLIST_PATH="$HOME/Library/LaunchAgents/homebrew.mxcl.parachute.plist"

# Detect Homebrew prefix (Apple Silicon vs Intel)
if [[ -d "/opt/homebrew" ]]; then
    BREW_PREFIX="/opt/homebrew"
elif [[ -d "/usr/local/Homebrew" ]]; then
    BREW_PREFIX="/usr/local"
else
    BREW_PREFIX="/opt/homebrew"  # Default fallback
fi
LOG_PATH="$BREW_PREFIX/var/log/parachute.log"

DEV_PLIST_CONTENT='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOST</key>
        <string>0.0.0.0</string>
        <key>PORT</key>
        <string>3333</string>
        <key>VAULT_PATH</key>
        <string>'"$HOME"'/Parachute</string>
    </dict>
    <key>KeepAlive</key>
    <true/>
    <key>Label</key>
    <string>homebrew.mxcl.parachute</string>
    <key>LimitLoadToSessionType</key>
    <array>
        <string>Aqua</string>
        <string>Background</string>
        <string>LoginWindow</string>
        <string>StandardIO</string>
        <string>System</string>
    </array>
    <key>ProgramArguments</key>
    <array>
        <string>'"$SCRIPT_DIR"'/parachute.sh</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>'"$LOG_PATH"'</string>
    <key>StandardOutPath</key>
    <string>'"$LOG_PATH"'</string>
    <key>WorkingDirectory</key>
    <string>'"$SCRIPT_DIR"'</string>
</dict>
</plist>'

cmd_service_install() {
    echo -e "${BLUE}Installing Parachute as a service (dev mode)...${NC}"

    # Stop existing service if running
    launchctl unload "$PLIST_PATH" 2>/dev/null || true

    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_PATH")"

    # Write dev plist
    echo "$DEV_PLIST_CONTENT" > "$PLIST_PATH"

    # Load the service
    launchctl load "$PLIST_PATH"

    echo -e "${GREEN}✓ Service installed and started${NC}"
    echo -e "  Running from: $SCRIPT_DIR"
    echo -e "  Logs: /opt/homebrew/var/log/parachute.log"
    echo ""
    echo -e "Use ${CYAN}parachute service-restart${NC} to restart after code changes"
}

cmd_service_restart() {
    echo -e "${BLUE}Restarting Parachute service...${NC}"

    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    sleep 1
    launchctl load "$PLIST_PATH"

    # Wait for it to start
    sleep 2
    if is_running; then
        echo -e "${GREEN}✓ Service restarted${NC}"
        echo -e "  PID: $(get_pid)"
    else
        echo -e "${RED}✗ Service failed to start${NC}"
        echo "Check logs: tail /opt/homebrew/var/log/parachute.log"
    fi
}

cmd_service_stop() {
    echo -e "${BLUE}Stopping Parachute service...${NC}"
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    echo -e "${GREEN}✓ Service stopped${NC}"
}

# =========================================================================
# Test Server Commands (isolated instance for automated testing)
# =========================================================================

# Check if test server is running
is_test_running() {
    if lsof -ti:$TEST_SERVER_PORT > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Get test server PID
get_test_pid() {
    lsof -ti:$TEST_SERVER_PORT 2>/dev/null || echo ""
}

# Start test server (isolated vault, different port)
cmd_test_start() {
    echo -e "${BLUE}Starting Parachute TEST server...${NC}"

    if is_test_running; then
        local pid=$(get_test_pid)
        echo -e "${YELLOW}Test server already running (PID: $pid)${NC}"
        echo -e "  Port: $TEST_SERVER_PORT"
        echo -e "  URL:  http://localhost:$TEST_SERVER_PORT"
        return 0
    fi

    # Ensure venv is set up
    ensure_venv

    # Create test vault directory
    mkdir -p "$TEST_VAULT_PATH"
    mkdir -p "$TEST_VAULT_PATH/.parachute"
    mkdir -p "$TEST_VAULT_PATH/Chat/contexts"

    # Start test server in background with isolated config
    cd "$SCRIPT_DIR"
    VAULT_PATH="$TEST_VAULT_PATH" \
    PORT="$TEST_SERVER_PORT" \
    nohup "$SCRIPT_DIR/venv/bin/python" -m parachute.server > "$TEST_LOG_FILE" 2>&1 &
    local pid=$!
    echo $pid > "$TEST_PID_FILE"

    # Wait for test server to start
    echo -n "Waiting for test server"
    for i in {1..30}; do
        if is_test_running; then
            echo ""
            echo -e "${GREEN}✓ Test server started successfully${NC}"
            echo -e "  PID:   $(get_test_pid)"
            echo -e "  Port:  ${CYAN}$TEST_SERVER_PORT${NC}"
            echo -e "  Vault: $TEST_VAULT_PATH"
            echo -e "  URL:   ${CYAN}http://localhost:$TEST_SERVER_PORT${NC}"
            echo -e "  Logs:  $TEST_LOG_FILE"
            echo ""
            echo -e "  ${YELLOW}Note: Test server uses isolated vault - data won't affect your main vault${NC}"
            return 0
        fi
        echo -n "."
        sleep 0.5
    done

    echo ""
    echo -e "${RED}✗ Failed to start test server${NC}"
    echo "Check logs: tail -f $TEST_LOG_FILE"
    return 1
}

# Stop test server
cmd_test_stop() {
    echo -e "${BLUE}Stopping Parachute TEST server...${NC}"

    if ! is_test_running; then
        echo -e "${YELLOW}Test server is not running${NC}"
        return 0
    fi

    local pid=$(get_test_pid)
    echo "Stopping process $pid..."

    # Try graceful shutdown first
    kill $pid 2>/dev/null || true

    # Wait for it to stop
    for i in {1..10}; do
        if ! is_test_running; then
            echo -e "${GREEN}✓ Test server stopped${NC}"
            rm -f "$TEST_PID_FILE"
            return 0
        fi
        sleep 0.5
    done

    # Force kill if still running
    echo "Force killing..."
    kill -9 $pid 2>/dev/null || true
    lsof -ti:$TEST_SERVER_PORT | xargs kill -9 2>/dev/null || true

    rm -f "$TEST_PID_FILE"
    echo -e "${GREEN}✓ Test server stopped${NC}"
}

# Restart test server
cmd_test_restart() {
    echo -e "${BLUE}Restarting Parachute TEST server...${NC}"
    cmd_test_stop
    sleep 1
    cmd_test_start
}

# Test server status
cmd_test_status() {
    echo -e "${BLUE}Parachute Test Server Status${NC}"
    echo "────────────────────────────────────────"

    if is_test_running; then
        local pid=$(get_test_pid)
        echo -e "  Test Server: ${GREEN}● Running${NC}"
        echo -e "  PID:         $pid"
        echo -e "  Port:        $TEST_SERVER_PORT"
        echo -e "  URL:         http://localhost:$TEST_SERVER_PORT"
        echo -e "  Vault:       $TEST_VAULT_PATH"

        # Try to get health info
        if command -v curl &> /dev/null; then
            local health=$(curl -s "http://localhost:$TEST_SERVER_PORT/api/health" 2>/dev/null || echo "")
            if [[ -n "$health" ]]; then
                echo -e "  Health:      ${GREEN}OK${NC}"
            fi
        fi
    else
        echo -e "  Test Server: ${RED}○ Stopped${NC}"
    fi

    echo ""
    echo -e "  Logs:        $TEST_LOG_FILE"
    echo "────────────────────────────────────────"
}

# View test server logs
cmd_test_logs() {
    if [[ -f "$TEST_LOG_FILE" ]]; then
        echo -e "${BLUE}Tailing test server logs (Ctrl+C to exit)...${NC}"
        tail -f "$TEST_LOG_FILE"
    else
        echo -e "${YELLOW}No test log file found at $TEST_LOG_FILE${NC}"
        echo "Start the test server first: ./parachute.sh test-start"
    fi
}

# Clean test vault (remove all test data)
cmd_test_clean() {
    echo -e "${BLUE}Cleaning test vault...${NC}"

    # Stop test server if running
    if is_test_running; then
        cmd_test_stop
    fi

    # Remove test vault
    if [[ -d "$TEST_VAULT_PATH" ]]; then
        rm -rf "$TEST_VAULT_PATH"
        echo -e "${GREEN}✓ Test vault cleaned${NC}"
    else
        echo -e "${YELLOW}Test vault doesn't exist${NC}"
    fi

    # Remove test logs
    rm -f "$TEST_LOG_FILE"
    rm -f "$TEST_PID_FILE"
}

# Show help
cmd_help() {
    banner
    echo "Usage: ./parachute.sh <command>"
    echo ""
    echo "Commands:"
    echo "  start         Start the server (background, no supervisor)"
    echo "  run           Run server in foreground (for launchd/systemd)"
    echo "  stop          Stop the server"
    echo "  restart       Restart the server"
    echo "  status        Show server and supervisor status"
    echo "  logs          Tail server logs"
    echo "  supervisor    Start with supervisor (foreground, web UI at :3330)"
    echo "  supervisor-bg Start with supervisor in background"
    echo "  sup-stop      Stop supervisor and server"
    echo "  setup         Set up virtual environment and install dependencies"
    echo ""
    echo "Test Server Commands (isolated instance for development/testing):"
    echo "  test-start    Start test server (port 3334, isolated vault)"
    echo "  test-stop     Stop test server"
    echo "  test-restart  Restart test server"
    echo "  test-status   Show test server status"
    echo "  test-logs     Tail test server logs"
    echo "  test-clean    Stop and remove all test data"
    echo ""
    echo "Service Commands (for development - uses launchctl):"
    echo "  service-install  Install as launchd service running local dev code"
    echo "  service-restart  Restart service (use after code changes)"
    echo "  service-stop     Stop the launchd service"
    echo ""
    echo "  help          Show this help"
    echo ""
    echo "Environment Variables:"
    echo "  VAULT_PATH         Path to vault (default: ~/Parachute)"
    echo "  SERVER_PORT        Server port (default: 3333)"
    echo "  SUPERVISOR_PORT    Supervisor port (default: 3330)"
    echo "  TEST_SERVER_PORT   Test server port (default: 3334)"
    echo "  TEST_VAULT_PATH    Test vault path (default: /tmp/parachute-test)"
    echo ""
    echo "Examples:"
    echo "  ./parachute.sh setup                    # First-time setup"
    echo "  ./parachute.sh start                    # Start server"
    echo "  ./parachute.sh status                   # Check status"
    echo "  ./parachute.sh test-start               # Start isolated test server"
    echo "  VAULT_PATH=/my/vault ./parachute.sh start  # Custom vault"
    echo ""
}

# Main
main() {
    case "${1:-help}" in
        start)
            cmd_start
            ;;
        run)
            cmd_run
            ;;
        stop)
            cmd_stop
            ;;
        restart)
            cmd_restart
            ;;
        status)
            cmd_status
            ;;
        logs)
            cmd_logs
            ;;
        supervisor|sup)
            cmd_supervisor
            ;;
        supervisor-bg|sup-bg)
            cmd_supervisor_bg
            ;;
        sup-stop)
            cmd_supervisor_stop
            ;;
        service-install)
            cmd_service_install
            ;;
        service-restart)
            cmd_service_restart
            ;;
        service-stop)
            cmd_service_stop
            ;;
        test-start)
            cmd_test_start
            ;;
        test-stop)
            cmd_test_stop
            ;;
        test-restart)
            cmd_test_restart
            ;;
        test-status)
            cmd_test_status
            ;;
        test-logs)
            cmd_test_logs
            ;;
        test-clean)
            cmd_test_clean
            ;;
        setup|install)
            cmd_setup
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            echo -e "${RED}Unknown command: $1${NC}"
            echo "Run './parachute.sh help' for usage"
            exit 1
            ;;
    esac
}

main "$@"
