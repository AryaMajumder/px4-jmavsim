#!/usr/bin/env bash
# px4-shell.sh — attach an interactive shell to a running PX4 instance.
#
# Usage:
#   ./px4-shell.sh <instance>
#
# Examples:
#   ./px4-shell.sh 0    # attach to drone-00 (instance 0)
#   ./px4-shell.sh 1    # attach to drone-01 (instance 1)
#
# Each terminal gets an independent view — switching windows in one
# terminal does NOT affect the other terminal.
#
# Detach with: Ctrl-B then D  (standard tmux detach)
# This does NOT stop the PX4 instance — it keeps running.
#
set -euo pipefail

TMUX_SESSION="px4-fleet"

INSTANCE="${1:-}"
if [ -z "$INSTANCE" ] || ! [[ "$INSTANCE" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 <instance>"
  echo "  instance: 0-based index of the PX4 instance to attach to"
  echo ""
  echo "Running instances:"
  if tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
    tmux list-windows -t "${TMUX_SESSION}" | sed 's/^/  /'
  else
    echo "  (none — session '${TMUX_SESSION}' not found)"
  fi
  exit 1
fi

WINDOW_NAME="drone-$(printf '%02d' $INSTANCE)"
MAVLINK_PORT=$((14540 + INSTANCE))

# ------------------------------------------------------------------
# Check session exists
# ------------------------------------------------------------------
if ! tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
  echo "ERROR: tmux session '${TMUX_SESSION}' not found."
  echo "  Start the fleet first with: ./start-px4-fleet.sh <count>"
  exit 1
fi

# ------------------------------------------------------------------
# Check window exists
# ------------------------------------------------------------------
if ! tmux list-windows -t "${TMUX_SESSION}" | grep -q "${WINDOW_NAME}"; then
  echo "ERROR: instance ${INSTANCE} (window '${WINDOW_NAME}') not found in session '${TMUX_SESSION}'."
  echo ""
  echo "Available windows:"
  tmux list-windows -t "${TMUX_SESSION}" | sed 's/^/  /'
  exit 1
fi

echo "Attaching to PX4 instance ${INSTANCE} (${WINDOW_NAME})"
echo "  MAVLink port : udpin:0.0.0.0:${MAVLINK_PORT}"
echo "  Detach       : Ctrl-B then D"
echo "  This does NOT stop the instance."
echo ""
sleep 0.5

# Create a new grouped session pointed at the target window.
# Grouped sessions share the same windows but each client tracks
# its own active window independently — so two terminals can show
# drone-00 and drone-01 simultaneously without interfering.
GROUPED_SESSION="${TMUX_SESSION}-view-${INSTANCE}-$$"
tmux new-session -d -t "${TMUX_SESSION}" -s "${GROUPED_SESSION}"
tmux select-window -t "${GROUPED_SESSION}:${WINDOW_NAME}"
tmux attach-session -t "${GROUPED_SESSION}"
