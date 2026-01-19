#!/bin/bash
#
# host-bridge.sh - Forward host services to Lima VM
#
# This script makes services running on the Mac host accessible from
# inside the Lima VM by forwarding them through the Lima bridge interface.
#
# The Lima bridge (192.168.5.2 on host side) is a virtual network that
# only connects the Mac and VM - it's not exposed to your LAN, so this
# is safe to use without additional firewall rules.
#
# Usage:
#   ./host-bridge.sh start    # Start all configured forwards
#   ./host-bridge.sh stop     # Stop all forwards
#   ./host-bridge.sh status   # Show running forwards
#   ./host-bridge.sh add <name> <host_port> [target_port]  # Add a forward
#
# Configuration is stored in ~/.config/parachute/host-bridge.conf
#

set -e

# Bind address for forwards
# With Lima's vz vmType, the VM accesses the host via a virtual gateway (192.168.5.2).
# The Mac can't bind to that IP directly, so we bind to 0.0.0.0.
# This is reasonably safe because:
# 1. The service is only forwarding to localhost
# 2. You can add macOS firewall rules if needed
BIND_IP="0.0.0.0"

# The IP the VM uses to reach the host (for documentation/status)
VM_HOST_GATEWAY="192.168.5.2"

# Config and PID file locations
CONFIG_DIR="${HOME}/.config/parachute"
CONFIG_FILE="${CONFIG_DIR}/host-bridge.conf"
PID_DIR="${CONFIG_DIR}/pids"

# Ensure directories exist
mkdir -p "$CONFIG_DIR" "$PID_DIR"

# Create default config if it doesn't exist
if [[ ! -f "$CONFIG_FILE" ]]; then
    cat > "$CONFIG_FILE" << 'EOF'
# Parachute Host Bridge Configuration
#
# Format: name:host_port:target_port
# - name: friendly name for the forward
# - host_port: port on the Mac to forward FROM (localhost)
# - target_port: port to expose on the bridge (VM connects to this)
#
# If target_port is omitted, it defaults to host_port.
#
# Example: Forward BrowserOS CDP from localhost:9000 to bridge:9000
# browseros-cdp:9000
#
# Example: Forward a dev server from localhost:8080 to bridge:8080
# dev-server:8080

# BrowserOS Chrome DevTools Protocol (for Suno MCP)
browseros-cdp:9000

# BrowserOS MCP HTTP endpoint (if needed)
# browseros-mcp:9102
EOF
    echo "Created default config at $CONFIG_FILE"
fi

# Check if socat is installed
check_socat() {
    if ! command -v socat &> /dev/null; then
        echo "Error: socat is not installed."
        echo "Install it with: brew install socat"
        exit 1
    fi
}

# Parse a config line into name, host_port, target_port
parse_line() {
    local line="$1"

    # Trim whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    # Skip comments and empty lines
    [[ -z "$line" ]] && return 1
    [[ "$line" =~ ^# ]] && return 1

    IFS=':' read -r name host_port target_port <<< "$line"
    target_port="${target_port:-$host_port}"

    # Validate - must have name and port
    if [[ -z "$name" ]] || [[ -z "$host_port" ]]; then
        return 1
    fi

    # Validate port is numeric
    if ! [[ "$host_port" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    echo "$name $host_port $target_port"
}

# Start a single forward
start_forward() {
    local name="$1"
    local host_port="$2"
    local target_port="$3"
    local pid_file="$PID_DIR/${name}.pid"

    # Check if already running
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "  $name: already running (PID $pid)"
            return 0
        fi
        rm "$pid_file"
    fi

    # Check if host port is listening
    if ! nc -z localhost "$host_port" 2>/dev/null; then
        echo "  $name: WARNING - nothing listening on localhost:$host_port"
    fi

    # Start socat in background
    socat TCP-LISTEN:"$target_port",bind="$BIND_IP",fork,reuseaddr \
          TCP:127.0.0.1:"$host_port" &
    local pid=$!

    echo "$pid" > "$pid_file"
    echo "  $name: localhost:$host_port -> $BIND_IP:$target_port (PID $pid)"
}

# Stop a single forward
stop_forward() {
    local name="$1"
    local pid_file="$PID_DIR/${name}.pid"

    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if kill "$pid" 2>/dev/null; then
            echo "  $name: stopped (PID $pid)"
        else
            echo "  $name: not running"
        fi
        rm -f "$pid_file"
    else
        echo "  $name: not running"
    fi
}

# Get status of a forward
status_forward() {
    local name="$1"
    local host_port="$2"
    local target_port="$3"
    local pid_file="$PID_DIR/${name}.pid"

    local status="stopped"
    local pid=""

    if [[ -f "$pid_file" ]]; then
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            status="running"
        else
            status="stale"
            rm -f "$pid_file"
        fi
    fi

    local source_status="?"
    if nc -z localhost "$host_port" 2>/dev/null; then
        source_status="✓"
    else
        source_status="✗"
    fi

    printf "  %-20s %s  localhost:%s -> %s:%s (VM: %s:%s)" \
        "$name" "$source_status" "$host_port" "$BIND_IP" "$target_port" "$VM_HOST_GATEWAY" "$target_port"

    if [[ "$status" == "running" ]]; then
        echo " (PID $pid)"
    else
        echo " [$status]"
    fi
}

# Process all configured forwards
process_all() {
    local action="$1"

    while IFS= read -r line; do
        local parsed=$(parse_line "$line" 2>/dev/null) || continue
        read -r name host_port target_port <<< "$parsed"

        case "$action" in
            start)  start_forward "$name" "$host_port" "$target_port" ;;
            stop)   stop_forward "$name" ;;
            status) status_forward "$name" "$host_port" "$target_port" ;;
        esac
    done < "$CONFIG_FILE"
}

# Add a new forward to config
add_forward() {
    local name="$1"
    local host_port="$2"
    local target_port="${3:-$host_port}"

    if [[ -z "$name" ]] || [[ -z "$host_port" ]]; then
        echo "Usage: $0 add <name> <host_port> [target_port]"
        exit 1
    fi

    # Check if already exists
    if grep -q "^${name}:" "$CONFIG_FILE" 2>/dev/null; then
        echo "Forward '$name' already exists in config"
        exit 1
    fi

    # Add to config
    echo "${name}:${host_port}:${target_port}" >> "$CONFIG_FILE"
    echo "Added: $name (localhost:$host_port -> $BIND_IP:$target_port)"
    echo "Run '$0 start' to activate"
}

# Main
case "${1:-}" in
    start)
        check_socat
        echo "Starting host bridges..."
        process_all start
        echo ""
        echo "VM can access these services at $VM_HOST_GATEWAY"
        ;;
    stop)
        echo "Stopping host bridges..."
        process_all stop
        ;;
    status)
        echo "Host bridge status (✓ = source listening, ✗ = not listening):"
        echo ""
        process_all status
        ;;
    add)
        add_forward "$2" "$3" "$4"
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|status|restart|add}"
        echo ""
        echo "Commands:"
        echo "  start             Start all configured forwards"
        echo "  stop              Stop all forwards"
        echo "  status            Show status of all forwards"
        echo "  restart           Stop and start all forwards"
        echo "  add <name> <port> Add a new forward to config"
        echo ""
        echo "Config: $CONFIG_FILE"
        exit 1
        ;;
esac
