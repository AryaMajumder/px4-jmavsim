#!/usr/bin/env bash
# start_px4_sitl.sh — stripped: only starts PX4 SITL (no jMAVSim)
# Usage: ./start_px4_sitl.sh
# Optional env:
#   CLOUD_IP and CLOUD_PORT to forward telemetry (UDP).
#   FOREGROUND_PX4=1 to run px4 in foreground (gives pxh> in this terminal).
#   DISABLE_ARMING_CHECKS=1 (note: script only prints a hint; update params interactively via pxh>).
set -euo pipefail

# -------------------
# Configurable bits
PX4_ROOT="${HOME}/src/PX4-Autopilot"
PX4_BUILD_LOG="${HOME}/px4_build_output.txt"
PX4_BIN="${PX4_ROOT}/build/px4_sitl_default/bin/px4"
SIM_PORT=14560    # PX4 <-> simulator UDP port
GCS_PORT=14550    # PX4 telemetry port (for GCS forwarding)
WAIT_TIMEOUT=120  # seconds to wait for PX4 / port binds
# -------------------

echo ">>> START SCRIPT: $(date)"

# 1) Optional: detect & export DISPLAY (harmless if jmavsim not used)
NS=$(grep -m1 nameserver /etc/resolv.conf | awk '{print $2}' || true)
if [ -n "$NS" ]; then
  export DISPLAY="${NS}:0.0"
  echo "DISPLAY set to ${DISPLAY} (no-op for PX4-only run)"
else
  echo "DISPLAY not auto-detected. This is fine for PX4-only runs."
fi

# 2) Kill previous PX4 processes (safe)
echo "Stopping previous PX4 processes (if any)..."
pkill -f "${PX4_BIN}" 2>/dev/null || true
sleep 1

# 3) Start or build PX4 SITL (foreground or background)
cd "$PX4_ROOT" || { echo "PX4 root not found at $PX4_ROOT"; exit 1; }

if [ "${FOREGROUND_PX4:-0}" = "1" ]; then
  echo "Starting PX4 in FOREGROUND (you will get pxh> prompt in this terminal)."
  echo "Build+run log -> ${PX4_BUILD_LOG}"
  make px4_sitl_default none 2>&1 | tee "${PX4_BUILD_LOG}"
  exit 0
else
  echo "Starting PX4 in background. Build+run log -> ${PX4_BUILD_LOG}"
  nohup make px4_sitl_default none > "${PX4_BUILD_LOG}" 2>&1 &
  PX4_MAKE_PID=$!
  echo "PX4 make started (PID ${PX4_MAKE_PID})."
fi

# 4) Wait for PX4 binary/process to exist and the simulator UDP port to be listening
echo "Waiting for PX4 binary and simulator UDP ${SIM_PORT} to be ready (timeout ${WAIT_TIMEOUT}s)..."
count=0
while [ $count -lt $WAIT_TIMEOUT ]; do
  if pgrep -f "${PX4_BIN}" >/dev/null 2>&1; then
    if ss -lupn 2>/dev/null | grep -q ":${SIM_PORT}"; then
      echo "PX4 SITL and simulator UDP port ${SIM_PORT} detected."
      break
    fi
  fi
  sleep 1
  ((count++))
done
if [ $count -ge $WAIT_TIMEOUT ]; then
  echo "WARNING: PX4 did not bind UDP ${SIM_PORT} within ${WAIT_TIMEOUT}s. Check ${PX4_BUILD_LOG}."
fi

# 5) Optional: forward telemetry to cloud (simple UDP forwarder using socat)
if [ -n "${CLOUD_IP:-}" ] && [ -n "${CLOUD_PORT:-}" ]; then
  echo "Starting UDP forwarder to ${CLOUD_IP}:${CLOUD_PORT} (forwarding from local ${GCS_PORT})"
  if ! command -v socat >/dev/null 2>&1; then
    echo "Installing socat..."
    sudo apt update && sudo apt install -y socat
  fi
  nohup socat -u UDP4-RECVFROM:${GCS_PORT},fork UDP4-SENDTO:${CLOUD_IP}:${CLOUD_PORT} > "${HOME}/socat_mavlink_forward.log" 2>&1 &
  echo "Forwarder started (log -> ${HOME}/socat_mavlink_forward.log)"
fi

# 6) Final status & logs
echo "---- STATUS ----"
ps aux | grep -E 'px4' | grep -v grep || true
echo "PX4 build log (tail):"
tail -n 40 "${PX4_BUILD_LOG}" || true

echo
echo "To open the interactive PX4 console (pxh>) run the PX4 binary in a separate terminal:"
echo "  cd ${PX4_ROOT}"
echo "  ${PX4_BIN}"
echo
echo "To disable arming checks (SITL-only) use pxh> and run commands like:"
echo "  param set COM_ARM_WO_GPS 1"
echo "  param set COM_ARM_IMU_ACC 0.0"
echo "  param set COM_ARM_IMU_GYR 0.0"
echo "  param set COM_ARM_MAG_STR 0"
echo "  param set COM_ARM_MAG_ANG 360"
echo "  param save"
echo
echo "To stop PX4:"
echo "  pkill -f ${PX4_BIN}"
echo
echo ">>> DONE ( $(date) )"
