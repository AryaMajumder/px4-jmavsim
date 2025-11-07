#!/usr/bin/env python3
"""
mav_to_mqtt.py

Simple MAVLink -> MQTT bridge for PX4 SITL.

Requirements:
    pip install paho-mqtt pymavlink

Usage examples:
  # publish to local broker (or SSH-forwarded local port)
  python3 mav_to_mqtt.py --mav udp:127.0.0.1:14550 --mqtt-host localhost --mqtt-port 1884

  # publish directly to cloud broker with username/password
  python3 mav_to_mqtt.py --mav udp:127.0.0.1:14550 --mqtt-host cloud.example.com --mqtt-port 1883 --mqtt-user drone --mqtt-pass-file ./secrets/mqtt_pass.txt

  # set lower publish rate (Hz)
  python3 mav_to_mqtt.py --rate 2

Notes:
- Do NOT commit credentials. Use files or env vars and .gitignore them.
- If using TLS, pass --tls-ca, --tls-cert, --tls-key.
"""

import argparse
import json
import time
import sys
import threading
import signal
from queue import Queue, Empty

import paho.mqtt.client as mqtt
from pymavlink import mavutil

# -----------------------
# Helper / defaults
# -----------------------
DEFAULT_MAV_URI = "udp:127.0.0.1:14550"
DEFAULT_MQTT_HOST = "localhost"
DEFAULT_MQTT_PORT = 1883
DEFAULT_TOPIC = "drone/telemetry"
DEFAULT_RATE = 5.0  # Hz (max publish rate)

# -----------------------
# MAVLink -> JSON builder
# -----------------------
def build_telemetry_from_msg(msg, seq):
    """Return dict or None if msg not relevant."""
    t = {"seq": seq, "timestamp": time.time()}
    mt = msg.get_type()
    if mt == "GLOBAL_POSITION_INT":
        # lat/lon are integers scaled by 1e7; alt in mm
        try:
            t.update({
                "lat": msg.lat / 1e7,
                "lon": msg.lon / 1e7,
                "alt": msg.alt / 1000.0,         # m
                "relative_alt": getattr(msg, "relative_alt", None) / 1000.0 if getattr(msg, "relative_alt", None) is not None else None,
                "vx": getattr(msg, "vx", None),  # cm/s
                "vy": getattr(msg, "vy", None),
                "vz": getattr(msg, "vz", None),
                "hdg": getattr(msg, "hdg", None) / 100.0 if getattr(msg, "hdg", None) is not None else None
            })
        except Exception:
            return None
    elif mt == "VFR_HUD":
        # alt in m, ground speed m/s, heading deg
        try:
            t.update({
                "velocity": getattr(msg, "vel", None),  # m/s
                "alt": getattr(msg, "alt", None),       # m
                "airspeed": getattr(msg, "airspeed", None),
                "groundspeed": getattr(msg, "groundspeed", None),
                "throttle": getattr(msg, "throttle", None)
            })
        except Exception:
            return None
    elif mt == "GPS_RAW_INT":
        try:
            t.update({
                "lat": msg.lat / 1e7,
                "lon": msg.lon / 1e7,
                "alt": msg.alt / 1000.0,
                "eph": getattr(msg, "eph", None),
                "epv": getattr(msg, "epv", None),
            })
        except Exception:
            return None
    else:
        return None
    # Normalize — remove None entries to keep JSON small
    return {k: v for k, v in t.items() if v is not None}

# -----------------------
# MQTT helper
# -----------------------
class MQTTClient:
    def __init__(self, host, port, username=None, password=None, tls_ca=None, tls_cert=None, tls_key=None, client_id="mav_to_mqtt"):
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.tls_ca = tls_ca
        self.tls_cert = tls_cert
        self.tls_key = tls_key
        self.client = mqtt.Client(client_id)
        if username:
            self.client.username_pw_set(username, password)
        if tls_ca:
            # If certs provided, set TLS
            self.client.tls_set(ca_certs=tls_ca, certfile=tls_cert, keyfile=tls_key)
        self.client.on_connect = self.on_connect
        self.client.on_disconnect = self.on_disconnect
        self._connected = threading.Event()
        self._stop = False

    def on_connect(self, client, userdata, flags, rc):
        if rc == 0:
            print("[mqtt] connected")
            self._connected.set()
        else:
            print(f"[mqtt] connect failed rc={rc}")

    def on_disconnect(self, client, userdata, rc):
        print("[mqtt] disconnected")
        self._connected.clear()

    def start(self):
        # run loop_start (background thread)
        try:
            self.client.connect(self.host, self.port, keepalive=60)
        except Exception as e:
            print(f"[mqtt] initial connect failed: {e}", file=sys.stderr)
        self.client.loop_start()

    def stop(self):
        self._stop = True
        try:
            self.client.loop_stop()
            self.client.disconnect()
        except Exception:
            pass

    def publish(self, topic, payload, qos=1):
        if not self._connected.is_set():
            # wait a small amount for connect
            if not self._connected.wait(timeout=2.0):
                # not connected -> still attempt publish (it will be queued locally)
                print("[mqtt] warning: not connected, publishing will queue locally")
        try:
            self.client.publish(topic, payload, qos=qos)
        except Exception as e:
            print(f"[mqtt] publish exception: {e}", file=sys.stderr)

# -----------------------
# Main bridge
# -----------------------
def bridge_loop(mav_uri, mqtt_cfg, topic, rate_hz, queue_size=100):
    # Setup MAVLink connection (auto-reconnect)
    print(f"[mav] connecting to {mav_uri} ...")
    mav = mavutil.mavlink_connection(mav_uri, autoreconnect=True, source_system=255)
    print("[mav] waiting for first heartbeat (5s timeout)...")
    try:
        hb = mav.wait_heartbeat(timeout=5)
        if hb:
            print("[mav] heartbeat received")
        else:
            print("[mav] no heartbeat yet -- bridge will still attempt to read")
    except Exception as e:
        print(f"[mav] heartbeat wait error: {e}")

    mqttc = MQTTClient(**mqtt_cfg)
    mqttc.start()

    seq = 0
    last_pub = 0.0
    publish_interval = 1.0 / max(0.1, rate_hz)  # avoid division by zero
    out_queue = Queue(maxsize=queue_size)

    def reader():
        nonlocal seq
        while True:
            try:
                msg = mav.recv_match(blocking=True, timeout=2)
                if msg is None:
                    continue
                # Build telemetry
                seq += 1
                telemetry = build_telemetry_from_msg(msg, seq)
                if telemetry:
                    # Compute a simple velocity fallback if not present and vx/vy available
                    if "velocity" not in telemetry and ("vx" in telemetry or "vy" in telemetry):
                        try:
                            vx = telemetry.get("vx", 0) / 100.0  # cm/s -> m/s
                            vy = telemetry.get("vy", 0) / 100.0
                            telemetry["velocity"] = (vx*vx + vy*vy) ** 0.5
                            # remove vx/vy to keep payload small
                            telemetry.pop("vx", None); telemetry.pop("vy", None)
                        except Exception:
                            pass
                    # push to queue (drop if full)
                    try:
                        out_queue.put_nowait(telemetry)
                    except Exception:
                        # queue full: drop oldest then push
                        try:
                            out_queue.get_nowait()
                            out_queue.put_nowait(telemetry)
                        except Exception:
                            pass
            except Exception as e:
                print(f"[mav reader] error: {e}", file=sys.stderr)
                time.sleep(1)

    reader_thread = threading.Thread(target=reader, daemon=True)
    reader_thread.start()

    print("[bridge] entering publish loop")
    try:
        while True:
            try:
                telemetry = out_queue.get(timeout=1.0)
            except Empty:
                # allow graceful shutdown
                time.sleep(0.01)
                continue

            now = time.time()
            if now - last_pub < publish_interval:
                # rate limiting: if too soon, drop/skip this sample
                # optionally we could re-queue; here we skip to keep latency low
                continue

            payload = json.dumps(telemetry, separators=(",", ":"), sort_keys=True)
            mqttc.publish(topic, payload)
            last_pub = now
            # tiny status print
            print(f"[bridge] published seq={telemetry.get('seq')} t={telemetry.get('timestamp'):.3f}")
    except KeyboardInterrupt:
        print("[bridge] interrupted by user")
    finally:
        mqttc.stop()
        print("[bridge] stopped")

# -----------------------
# CLI
# -----------------------
def parse_args():
    p = argparse.ArgumentParser(prog="mav_to_mqtt", description="MAVLink -> MQTT bridge")
    p.add_argument("--mav", default=DEFAULT_MAV_URI, help="MAVLink connection URI (e.g. udp:127.0.0.1:14550)")
    p.add_argument("--mqtt-host", default=DEFAULT_MQTT_HOST)
    p.add_argument("--mqtt-port", default=DEFAULT_MQTT_PORT, type=int)
    p.add_argument("--mqtt-user", default=None)
    p.add_argument("--mqtt-pass-file", default=None, help="Path to file containing MQTT password (preferred over passing password on CLI)")
    p.add_argument("--tls-ca", default=None, help="Path to CA file for TLS")
    p.add_argument("--tls-cert", default=None, help="Path to client cert (optional)")
    p.add_argument("--tls-key", default=None, help="Path to client key (optional)")
    p.add_argument("--topic", default=DEFAULT_TOPIC)
    p.add_argument("--rate", default=DEFAULT_RATE, type=float, help="Maximum publish rate (Hz)")
    p.add_argument("--queue-size", default=200, type=int, help="Telemetry queue size")
    return p.parse_args()

def read_password(file_path):
    if not file_path:
        return None
    try:
        with open(file_path, "r") as f:
            return f.read().strip()
    except Exception as e:
        print(f"[args] failed reading password file: {e}", file=sys.stderr)
        return None

def main():
    args = parse_args()
    mqtt_password = read_password(args.mqtt_pass_file)

    mqtt_cfg = {
        "host": args.mqtt_host,
        "port": args.mqtt_port,
        "username": args.mqtt_user,
        "password": mqtt_password,
        "tls_ca": args.tls_ca,
        "tls_cert": args.tls_cert,
        "tls_key": args.tls_key,
    }

    try:
        bridge_loop(args.mav, mqtt_cfg, args.topic, args.rate, queue_size=args.queue_size)
    except Exception as e:
        print(f"[main] fatal error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
