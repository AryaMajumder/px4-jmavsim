#!/bin/bash
# setup-px4-persistent-mavlink.sh
# Configure PX4 to automatically start with dual MAVLink ports on every boot

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}✓${NC} $1"; }
log_fail() { echo -e "${RED}✗${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }

echo "=========================================="
echo "Setup Persistent Dual MAVLink in PX4"
echo "=========================================="
echo ""

PX4_DIR="${HOME}/src/PX4-Autopilot"

if [ ! -d "$PX4_DIR" ]; then
    log_fail "PX4 directory not found: $PX4_DIR"
    echo ""
    echo "Update PX4_DIR in this script to match your installation"
    exit 1
fi

log_pass "Found PX4 directory: $PX4_DIR"
echo ""

# Find the rcS startup script
RCS_FILE="$PX4_DIR/ROMFS/px4fmu_common/init.d-posix/rcS"

if [ ! -f "$RCS_FILE" ]; then
    log_fail "Startup script not found: $RCS_FILE"
    echo ""
    log_info "Your PX4 version might have a different structure"
    echo "Look for rcS in: $PX4_DIR/ROMFS/"
    exit 1
fi

log_pass "Found startup script: $RCS_FILE"
echo ""

# Backup the original
BACKUP_FILE="${RCS_FILE}.backup.$(date +%s)"
cp "$RCS_FILE" "$BACKUP_FILE"
log_info "Backed up original: $BACKUP_FILE"
echo ""

# Check if already modified
if grep -q "# DUAL MAVLINK CUSTOM CONFIG" "$RCS_FILE" 2>/dev/null; then
    log_warn "Startup script already modified for dual MAVLink"
    echo ""
    echo "To re-apply, first restore backup:"
    echo "  cp $BACKUP_FILE $RCS_FILE"
    echo "  ./setup-px4-persistent-mavlink.sh"
    exit 0
fi

# Add dual MAVLink configuration
log_info "Adding dual MAVLink configuration to startup script..."
echo ""

# Find where to insert (after mavlink starts, usually near the end)
# We'll add it before the last "exit" or at the very end

cat >> "$RCS_FILE" <<'EOF'

# DUAL MAVLINK CUSTOM CONFIG - Added by setup-px4-persistent-mavlink.sh
# Stop default MAVLink and start dual instances for telemetry pipeline

# Stop any existing MAVLink instances
mavlink stop-all

# MAVLink instance 1: Port 14550 for mav_to_mqtt (telemetry pipeline)
mavlink start -x -u 14550 -r 4000000

# MAVLink instance 2: Port 14551 for px4_agent (command interface)
mavlink start -x -u 14551 -r 4000000

# END DUAL MAVLINK CUSTOM CONFIG
EOF

log_pass "Configuration added to startup script"
echo ""

# Rebuild PX4 to apply changes
log_info "Rebuilding PX4 to apply changes..."
echo ""
echo "This will take a few minutes..."
echo ""

cd "$PX4_DIR"

if make px4_sitl_default > /tmp/px4_rebuild.log 2>&1; then
    log_pass "PX4 rebuilt successfully"
else
    log_fail "Build failed! Check /tmp/px4_rebuild.log"
    echo ""
    echo "To restore original:"
    echo "  cp $BACKUP_FILE $RCS_FILE"
    exit 1
fi

echo ""
echo "=========================================="
echo "Configuration Complete!"
echo "=========================================="
echo ""
echo "Changes made:"
echo "  ✓ Modified: $RCS_FILE"
echo "  ✓ Backup: $BACKUP_FILE"
echo "  ✓ Rebuilt PX4 SITL"
echo ""
echo "From now on, PX4 will AUTOMATICALLY start with:"
echo "  • Port 14550 - for mav_to_mqtt (telemetry)"
echo "  • Port 14551 - for px4_agent (commands)"
echo ""
echo "To test:"
echo "  1. cd $PX4_DIR"
echo "  2. make px4_sitl jmavsim"
echo "  3. Wait for pxh> prompt"
echo "  4. Type: mavlink status"
echo ""
echo "You should see TWO MAVLink instances running!"
echo ""
echo "To restore original configuration:"
echo "  cp $BACKUP_FILE $RCS_FILE"
echo "  cd $PX4_DIR && make px4_sitl_default"
echo ""
