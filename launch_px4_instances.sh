#!/usr/bin/env bash
# launch.sh — start a headless PX4 + JMAVSim instance
# Usage:
#   ./launch.sh 0   (instance 0 — uses make, same as before)
#   ./launch.sh 1   (instance 1)
#   ./launch.sh 2   (instance 2)
#   etc.
#
# Each instance gets its own terminal. PX4 runs in the foreground
# so you see its logs. JMAVSim runs in the background (it's just a sim).
# To get a shell into any running instance:
#   ./launch.sh shell 0
#   ./launch.sh shell 1

set -e

PX4_ROOT="$(cd "$(dirname "$0")" && pwd)"
JMAVSIM="${PX4_ROOT}/Tools/simulation/jmavsim/jmavsim_run.sh"
PX4_BIN="${PX4_ROOT}/build/px4_sitl_default/bin/px4"
PX4_ETC="${PX4_ROOT}/build/px4_sitl_default/etc"

# ── helpers ──────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

check_build() {
  [ -f "${PX4_BIN}" ] || die "PX4 not built yet. Run: HEADLESS=1 make px4_sitl_default first."
  [ -f "${PX4_ETC}/init.d-posix/rcS" ] || die "Build artifacts missing. Run: HEADLESS=1 make px4_sitl_default first."
}

open_shell() {
  local INSTANCE=$1
  local PORT=$((14540 + INSTANCE))
  SHELL_SCRIPT=$(find "${PX4_ROOT}/Tools" -name "mavlink_shell.py" 2>/dev/null | head -1)
  [ -z "${SHELL_SCRIPT}" ] && die "mavlink_shell.py not found in Tools/"
  echo "Opening MAVLink shell for instance ${INSTANCE} on port ${PORT}..."
  python3 "${SHELL_SCRIPT}" "0.0.0.0:${PORT}"
  exit 0
}

# ── argument parsing ──────────────────────────────────────────────────────────

if [ "$1" = "shell" ]; then
  [ -z "$2" ] && die "Usage: $0 shell <instance_number>"
  open_shell "$2"
fi

INSTANCE=$1
[ -z "${INSTANCE}" ] && die "Usage: $0 <instance_number>  (e.g. $0 0, $0 1, $0 2)"
[[ "${INSTANCE}" =~ ^[0-9]+$ ]] || die "Instance must be a number, got: ${INSTANCE}"

SIM_PORT=$((4560 + INSTANCE))
MAVLINK_PORT=$((14540 + INSTANCE))
WORK_DIR="/tmp/sitl_iris_${INSTANCE}"
JMAVSIM_PID_FILE="/tmp/jmavsim_${INSTANCE}.pid"

echo "======================================================="
echo "  PX4 SITL — Instance ${INSTANCE}"
echo "  MAVLink API port : ${MAVLINK_PORT}"
echo "  Simulator port   : ${SIM_PORT}"
echo "  Work dir         : ${WORK_DIR}"
echo "  To open a shell  : ./launch.sh shell ${INSTANCE}"
echo "======================================================="
echo ""

# ── instance 0 — use make (handles everything automatically) ─────────────────

if [ "${INSTANCE}" -eq 0 ]; then
  echo "Instance 0: using make..."
  cd "${PX4_ROOT}"
  HEADLESS=1 make px4_sitl_default jmavsim
  exit 0
fi

# ── instance 1+ — direct binary launch ───────────────────────────────────────

check_build

# Clean up any previous run for this instance
if [ -f "${JMAVSIM_PID_FILE}" ]; then
  OLD_PID=$(cat "${JMAVSIM_PID_FILE}")
  kill "${OLD_PID}" 2>/dev/null && echo "Killed previous JMAVSim (PID ${OLD_PID})" || true
  rm -f "${JMAVSIM_PID_FILE}"
fi

# Set up working directory
mkdir -p "${WORK_DIR}"
if [ ! -L "${WORK_DIR}/etc" ]; then
  ln -s "${PX4_ETC}" "${WORK_DIR}/etc"
  echo "Linked etc -> ${WORK_DIR}/etc"
fi

# Add init scripts to PATH so rcS can source helper files
export PATH="${PATH}:${PX4_ETC}/init.d-posix"

# Step 1: Start JMAVSim in background (it will wait for PX4 to connect)
echo "Starting JMAVSim on port ${SIM_PORT}..."
HEADLESS=1 "${JMAVSIM}" -p "${SIM_PORT}" -l > "/tmp/jmavsim_${INSTANCE}.log" 2>&1 &
JMAVSIM_PID=$!
echo "${JMAVSIM_PID}" > "${JMAVSIM_PID_FILE}"
echo "JMAVSim PID: ${JMAVSIM_PID} (log: /tmp/jmavsim_${INSTANCE}.log)"

# Step 2: Start PX4 in the foreground — this terminal becomes the PX4 console
echo "Starting PX4 instance ${INSTANCE}..."
echo ""

cd "${WORK_DIR}"

exec env \
  PX4_INSTANCE="${INSTANCE}" \
  PX4_SIM_MODEL=jmavsim_iris \
  "${PX4_BIN}" \
    -i "${INSTANCE}" \
    -d "${PX4_ETC}" \
    -w "${WORK_DIR}" \
    -s "${PX4_ETC}/init.d-posix/rcS"
