#!/bin/sh
# OpenIDEA container entrypoint.
#   MODE=web (default) virtual display + VNC + noVNC, IDE renders in a browser
#   MODE=x11           use a mounted host X11 / WSLg socket, no VNC stack
set -eu

MODE="${MODE:-web}"
XVFB_DISPLAY="${XVFB_DISPLAY:-:1}"
XVFB_GEOMETRY="${XVFB_GEOMETRY:-1440x900x24}"
NOVNC_PORT="${NOVNC_PORT:-4190}"

log() { echo "[openidea] $*"; }

# IDE binary overridable for debugging; CMD args win when given.
IDE_BIN="${OPENIDEA_BIN:-openidea}"

start_web_mode() {
  export DISPLAY="$XVFB_DISPLAY"

  # Clear stale lock files from a previous run in a reused container.
  rm -f "/tmp/.X${XVFB_DISPLAY#:}-lock" "/tmp/.X11-unix/X${XVFB_DISPLAY#:}" 2>/dev/null || true

  log "starting Xvfb on ${XVFB_DISPLAY} (${XVFB_GEOMETRY})"
  Xvfb "$XVFB_DISPLAY" -screen 0 "$XVFB_GEOMETRY" -nolisten tcp &
  XVFB_PID=$!

  # Wait for the X socket instead of sleeping a fixed time.
  i=0
  while [ ! -e "/tmp/.X11-unix/X${XVFB_DISPLAY#:}" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done

  log "starting openbox"
  openbox --sm-disable >>/tmp/openbox.log 2>&1 &
  OPENBOX_PID=$!

  # -nopw: no VNC password. Safe only because the compose port is loopback
  # bound; anyone who can reach the port gets the desktop. Add -rfbauth for
  # anything exposed beyond localhost.
  log "starting x11vnc on ${XVFB_DISPLAY}"
  x11vnc -display "$XVFB_DISPLAY" -forever -shared -nopw -quiet \
    -rfbport 5900 -listen 127.0.0.1 >>/tmp/x11vnc.log 2>&1 &
  VNC_PID=$!

  log "starting noVNC on 0.0.0.0:${NOVNC_PORT}"
  websockify --web /usr/share/novnc "0.0.0.0:${NOVNC_PORT}" 127.0.0.1:5900 \
    >>/tmp/websockify.log 2>&1 &
  WS_PID=$!

  trap 'log "shutting down"; kill '"$WS_PID"' '"$VNC_PID"' '"$OPENBOX_PID"' '"$XVFB_PID"' 2>/dev/null || true' INT TERM

  log "web UI: http://127.0.0.1:${NOVNC_PORT}/vnc.html"
  log "launching $IDE_BIN"
  # exec: the IDE owns the process and receives signals directly.
  exec "$IDE_BIN" "$@"
}

start_x11_mode() {
  # Image ENV sets DISPLAY=:1 for web mode. When the operator mounted a socket
  # without overriding DISPLAY, that default is wrong; a real DISPLAY wins.
  if [ "${DISPLAY:-}" = ":1" ] && [ ! -S "/tmp/.X11-unix/X1" ]; then
    export DISPLAY=":0"
  fi
  export DISPLAY="${DISPLAY:-:0}"
  if [ ! -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; then
    log "WARN: no X socket at /tmp/.X11-unix/X${DISPLAY#:}"
    log "WARN: mount /tmp/.X11-unix (and /mnt/wslg for WSLg) and set DISPLAY"
  fi
  log "x11 mode on DISPLAY=${DISPLAY}; launching $IDE_BIN"
  exec "$IDE_BIN" "$@"
}

case "$MODE" in
  web) start_web_mode "$@" ;;
  x11) start_x11_mode "$@" ;;
  *)
    log "ERROR: unknown MODE='$MODE' (expected web or x11)"
    exit 2
    ;;
esac