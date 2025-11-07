#!/usr/bin/env bash
# start_jmavsim_gui_fixed.sh  — minimal reliable launcher for jMAVSim GUI
set -euo pipefail

# config: adjust if your repo is elsewhere
PX4_ROOT="${HOME}/src/PX4-Autopilot"
JMAVSIM_DIR="${PX4_ROOT}/Tools/simulation/jmavsim/jMAVSim"
JMAVSIM_JAR_DEFAULT="out/production/jmavsim_run.jar"
JMAVSIM_LOG="${HOME}/jmavsim_run.txt"
SIM_PORT=14560
RATE=100

# 1) ensure DISPLAY points to windows
NS=$(grep -m1 nameserver /etc/resolv.conf | awk '{print $2}' || true)
if [ -z "$NS" ]; then
  echo "ERROR: cannot detect Windows host IP in /etc/resolv.conf. Start VcXsrv and set DISPLAY manually."
  exit 1
fi
export DISPLAY="${NS}:0.0"
echo "Using DISPLAY=${DISPLAY}"

# 2) cd to jmavsim dir
cd "${JMAVSIM_DIR}" || { echo "jmavsim dir not found: ${JMAVSIM_DIR}"; exit 1; }

# 3) locate jar
if [ -f "${JMAVSIM_JAR_DEFAULT}" ]; then
  JAR="${JMAVSIM_JAR_DEFAULT}"
else
  JAR=$(find . -maxdepth 4 -type f \( -iname '*jmav*run*.jar' -o -iname '*jmavsim*.jar' \) -print -quit || true)
  if [ -z "$JAR" ]; then
    echo "ERROR: jmavsim jar not found under $(pwd). Build jMAVSim (ant/gradle) first."
    exit 1
  fi
fi
echo "Will run jar: ${JAR}"

# 4) clean previous log & start jmavsim with explicit DISPLAY passed into env
: > "${JMAVSIM_LOG}"
echo "Starting jmavsim (log -> ${JMAVSIM_LOG}) ..."
# Try Java 17 flags first; if they fail, fallback to java -jar (java8)
env DISPLAY="${DISPLAY}" java \
  --add-exports=java.desktop/sun.awt=ALL-UNNAMED \
  --add-opens=java.desktop/sun.awt=ALL-UNNAMED \
  -jar "${JAR}" -udp "${SIM_PORT}" -r "${RATE}" -gui -automag > "${JMAVSIM_LOG}" 2>&1 &

sleep 1

# 5) verify process and show tail
JMAV_PID=$(pgrep -f "${JAR}" | head -n1 || true)
if [ -n "${JMAV_PID}" ]; then
  echo "jMAVSim started (pid ${JMAV_PID})."
  echo "Tail of ${JMAVSIM_LOG}:"
  sleep 0.5
  tail -n 80 "${JMAVSIM_LOG}"
  echo
  echo "If you don't see a window: check Windows (Alt+Tab), VcXsrv running, and firewall."
else
  echo "jMAVSim process not found. Showing log (${JMAVSIM_LOG}) for diagnosis:"
  tail -n 200 "${JMAVSIM_LOG}"
  echo "If log mentions module/access errors, try Java 8 fallback:"
  echo "  /usr/lib/jvm/java-8-openjdk-amd64/bin/java -jar \"${JAR}\" -udp ${SIM_PORT} -r ${RATE} -gui -automag"
  exit 1
fi
