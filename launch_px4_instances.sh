#!/usr/bin/env bash
# start-px4-fleet.sh — start N PX4 SITL instances.
#
# Usage:
#   ./start-px4-fleet.sh <count>
#
# Examples:
#   ./start-px4-fleet.sh 1    # single drone
#   ./start-px4-fleet.sh 2    # two drones
#   ./start-px4-fleet.sh 3    # three drones
#
# Port layout per instance (i = instance number):
#   MAVLink listen : 14540 + i
#   MAVLink output : 14550 + i
#   Sim port       : 14560 + i  (auto-offset by -i flag)
#
set -euo pipefail

# -------------------
PX4_ROOT="${HOME}/src/PX4-Autopilot"
PX4_BIN="${PX4_ROOT}/build/px4_sitl_default/bin/px4"
PX4_RCS="${PX4_ROOT}/ROMFS/px4fmu_common/init.d-posix/rcS"
TMUX_SESSION="px4-fleet"
WAIT_TIMEOUT=60
# -------------------

COUNT="${1:-}"
if [ -z "$COUNT" ] || ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
  echo "Usage: $0 <count>"
  echo "  count: number of PX4 instances to start (1 or more)"
  exit 1
fi

# ------------------------------------------------------------------
# 1) Check dependencies
# ------------------------------------------------------------------
if ! command -v tmux &>/dev/null; then
  echo "ERROR: tmux is required. Install with: apt-get install tmux"
  exit 1
fi

# ------------------------------------------------------------------
# 2) Build if binary missing
# ------------------------------------------------------------------
cd "$PX4_ROOT" || { echo "ERROR: PX4 root not found at $PX4_ROOT"; exit 1; }

if [ ! -x "${PX4_BIN}" ]; then
  echo "Binary not found — building now..."
  if ! make px4_sitl_default none; then
    echo "ERROR: build failed."
    exit 1
  fi
else
  echo "Binary already built — skipping build step."
fi

if [ ! -f "${PX4_RCS}" ]; then
  echo "ERROR: startup script not found at ${PX4_RCS}"
  exit 1
fi

# ------------------------------------------------------------------
# 3) Kill any existing fleet session cleanly
# ------------------------------------------------------------------
if tmux has-session -t "${TMUX_SESSION}" 2>/dev/null; then
  echo "Killing existing tmux session '${TMUX_SESSION}'..."
  tmux kill-session -t "${TMUX_SESSION}"
  sleep 1
fi

pkill -f "${PX4_BIN}" 2>/dev/null || true
sleep 1

# ------------------------------------------------------------------
# 4) Start each instance in its own tmux window
# ------------------------------------------------------------------
echo "Starting ${COUNT} PX4 instance(s) in tmux session '${TMUX_SESSION}'..."
echo ""

for i in $(seq 0 $((COUNT - 1))); do
  WORK_DIR="${PX4_ROOT}/build/px4_sitl_default/rootfs_instance${i}"
  WINDOW_NAME="drone-$(printf '%02d' $i)"

  # Create isolated working dir with etc symlink
  mkdir -p "${WORK_DIR}"
  if [ ! -e "${WORK_DIR}/etc" ]; then
    ln -s "${PX4_ROOT}/ROMFS/px4fmu_common" "${WORK_DIR}/etc"
  fi

  PX4_CMD="${PX4_BIN} -i ${i} -w ${WORK_DIR} -s ${PX4_RCS}"

  if [ "$i" -eq 0 ]; then
    tmux new-session -d -s "${TMUX_SESSION}" -n "${WINDOW_NAME}"
    tmux send-keys -t "${TMUX_SESSION}:${WINDOW_NAME}" "${PX4_CMD}" Enter
  else
    tmux new-window -t "${TMUX_SESSION}" -n "${WINDOW_NAME}"
    tmux send-keys -t "${TMUX_SESSION}:${WINDOW_NAME}" "${PX4_CMD}" Enter
  fi

  echo "  Instance ${i} → tmux window '${WINDOW_NAME}' | MAVLink port $((14540 + i))"
done

echo ""
echo "Waiting for instances to become ready..."

# ------------------------------------------------------------------
# 5) Wait for ready, then inject mavlink start commands
# ------------------------------------------------------------------
ALL_READY=true

for i in $(seq 0 $((COUNT - 1))); do
  WINDOW_NAME="drone-$(printf '%02d' $i)"
  MAVLINK_LISTEN=$((14540 + i))
  MAVLINK_OUTPUT=$((14550 + i))

  echo -n "  Waiting for instance ${i}..."
  count=0
  ready=false

  while [ $count -lt $WAIT_TIMEOUT ]; do
    PANE_TEXT=$(tmux capture-pane -t "${TMUX_SESSION}:${WINDOW_NAME}" -p 2>/dev/null || true)

    if echo "${PANE_TEXT}" | grep -q "Ready for takeoff\|home set"; then
      echo " ready."
      ready=true
      break
    fi

    if echo "${PANE_TEXT}" | grep -q "Startup script returned with return value\|PX4 Exiting"; then
      echo " FAILED."
      ALL_READY=false
      break
    fi

    sleep 1
    ((count++))
    echo -n "."
  done

  if [ "$ready" = false ]; then
    [ "$ALL_READY" = true ] && echo " timeout."
    ALL_READY=false
    continue
  fi

  # ------------------------------------------------------------------
  # Inject mavlink start commands directly into the pxh> prompt.
  # Ports are offset per instance so each drone has its own channel.
  # ------------------------------------------------------------------
  echo "  Configuring MAVLink for instance ${i}..."
  sleep 0.5

  # Primary MAVLink link (agent connects here)
  tmux send-keys -t "${TMUX_SESSION}:${WINDOW_NAME}" \
    "mavlink start -x -u ${MAVLINK_LISTEN} -o ${MAVLINK_OUTPUT} -t 127.0.0.1 -r 4000000" Enter
  sleep 0.3

  # Second stream for GCS / debugging (offset by 10 to avoid collision)
  GCS_LISTEN=$((14560 + i))
  GCS_OUTPUT=$((14570 + i))
  tmux send-keys -t "${TMUX_SESSION}:${WINDOW_NAME}" \
    "mavlink start -x -u ${GCS_LISTEN} -o ${GCS_OUTPUT} -t 127.0.0.1 -r 4000000" Enter
  sleep 0.3

  echo "  Instance ${i} MAVLink configured: listen=${MAVLINK_LISTEN} output=${MAVLINK_OUTPUT}"
done

echo ""
# ------------------------------------------------------------------
# 6) Summary
# ------------------------------------------------------------------
echo "========================================"
echo "  PX4 Fleet Status"
echo "========================================"
for i in $(seq 0 $((COUNT - 1))); do
  echo "  drone-$(printf '%02d' $i)  →  agent: udpin:0.0.0.0:$((14540 + i))  |  GCS: $((14560 + i))"
done
echo ""
echo "  tmux session : ${TMUX_SESSION}"
echo "  attach shell : ./px4-shell.sh <instance>"
echo "  attach all   : tmux attach -t ${TMUX_SESSION}"
echo "========================================"

if [ "$ALL_READY" = false ]; then
  echo ""
  echo "WARNING: One or more instances failed or timed out."
  echo "Inspect with: tmux attach -t ${TMUX_SESSION}"
  exit 1
fi
