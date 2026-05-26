#!/usr/bin/env bash

set -euo pipefail

ADDON_DIR="${ADDON_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DEFAULT_FS42_DIR="$(pwd)"
if [ ! -f "$DEFAULT_FS42_DIR/field_player.py" ]; then
    DEFAULT_FS42_DIR="$(cd "$ADDON_DIR/.." && pwd)/FieldStation42"
fi
FS42_DIR="${FS42_DIR:-$DEFAULT_FS42_DIR}"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"

BRIDGE_PORT="${BRIDGE_PORT:-8088}"
FS42_STATUS_URL="${FS42_STATUS_URL:-http://127.0.0.1:4242/player/status}"
HLS_DIR="${HLS_DIR:-/tmp/fs42-hls}"
CAPTURE_OFFSET="${CAPTURE_OFFSET:-0,0}"
CAPTURE_FRAMERATE="${CAPTURE_FRAMERATE:-24}"
FULL_FRAME_CAPTURE_SIZE="${FULL_FRAME_CAPTURE_SIZE:-}"
FULL_FRAME_CAPTURE_OFFSET="${FULL_FRAME_CAPTURE_OFFSET:-0,0}"
FULL_FRAME_CONTENT_TYPES="${FULL_FRAME_CONTENT_TYPES:-guide,web}"

ADDON_BRIDGE_SCRIPT="$ADDON_DIR/fs42-stream-bridge/hls_bridge.py"
FS42_BRIDGE_SCRIPT="$FS42_DIR/hls_bridge.py"
FS42_PYTHON="$FS42_DIR/env/bin/python3"
FS42_PLAYER="$FS42_DIR/field_player.py"

yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local answer
    local suffix

    if [[ "$default" =~ ^[Yy]$ ]]; then
        suffix="Y/n"
    else
        suffix="y/N"
    fi

    read -r -p "$prompt ($suffix): " answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

prompt_value() {
    local prompt="$1"
    local default="$2"
    local answer

    read -r -p "$prompt [$default]: " answer
    echo "${answer:-$default}"
}

require_file() {
    if [ ! -f "$1" ]; then
        echo "Missing required file: $1" >&2
        exit 1
    fi
}

refresh_fs42_paths() {
    FS42_BRIDGE_SCRIPT="$FS42_DIR/hls_bridge.py"
    FS42_PYTHON="$FS42_DIR/env/bin/python3"
    FS42_PLAYER="$FS42_DIR/field_player.py"
}

resolve_fs42_dir() {
    while [ ! -f "$FS42_DIR/field_player.py" ]; do
        echo ""
        echo "Could not find FieldStation42 at:"
        echo "  $FS42_DIR"
        echo ""
        echo "Enter the path to your existing FieldStation42 install."
        echo "For example: /home/pi/FieldStation42"
        FS42_DIR="$(prompt_value "FieldStation42 directory" "$FS42_DIR")"
        refresh_fs42_paths
    done
}

detect_display() {
    if [ -n "${DISPLAY:-}" ]; then
        echo "$DISPLAY"
        return
    fi

    if command -v xdpyinfo >/dev/null 2>&1 && xdpyinfo -display :0.0 >/dev/null 2>&1; then
        echo ":0.0"
        return
    fi

    echo ":0.0"
}

detect_capture_size() {
    local display_value="$1"

    if command -v xdpyinfo >/dev/null 2>&1; then
        local detected
        detected="$(xdpyinfo -display "$display_value" 2>/dev/null | awk '/dimensions:/ {print $2; exit}' || true)"
        if [ -n "$detected" ]; then
            echo "$detected"
            return
        fi
    fi

    echo "720x480"
}

detect_public_host() {
    local host
    host="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [ -n "$host" ]; then
        echo "$host"
    else
        echo "127.0.0.1"
    fi
}

detect_pulse_source() {
    if ! command -v pactl >/dev/null 2>&1; then
        echo "auto"
        return
    fi

    local sink
    sink="$(pactl get-default-sink 2>/dev/null || true)"
    if [ -n "$sink" ]; then
        echo "${sink}.monitor"
        return
    fi

    pactl list short sources 2>/dev/null | awk '$2 ~ /\.monitor$/ {print $2; exit}' || true
}

require_file "$ADDON_BRIDGE_SCRIPT"
resolve_fs42_dir

DETECTED_DISPLAY="$(detect_display)"
DETECTED_CAPTURE_SIZE="$(detect_capture_size "$DETECTED_DISPLAY")"
DETECTED_PUBLIC_HOST="$(detect_public_host)"
DETECTED_PULSE_SOURCE="$(detect_pulse_source)"
DETECTED_PULSE_SOURCE="${DETECTED_PULSE_SOURCE:-auto}"
if [ -n "$DETECTED_PULSE_SOURCE" ] && [ "$DETECTED_PULSE_SOURCE" != "auto" ]; then
    DETECTED_AUDIO_SOURCE="pulse"
else
    DETECTED_AUDIO_SOURCE="auto"
    DETECTED_PULSE_SOURCE="auto"
fi

DISPLAY_VALUE="${DISPLAY_VALUE:-${DISPLAY:-$DETECTED_DISPLAY}}"
CAPTURE_SIZE="${CAPTURE_SIZE:-$DETECTED_CAPTURE_SIZE}"
PUBLIC_HOST="${PUBLIC_HOST:-$DETECTED_PUBLIC_HOST}"
AUDIO_SOURCE="${AUDIO_SOURCE:-$DETECTED_AUDIO_SOURCE}"
PULSE_SOURCE="${PULSE_SOURCE:-$DETECTED_PULSE_SOURCE}"

echo ""
echo "FieldStation42 Roku add-on service installer"
echo ""
echo "Add-on repo:       $ADDON_DIR"
echo "FieldStation42:    $FS42_DIR"
echo "Systemd user dir:  $SYSTEMD_USER_DIR"
echo ""
echo "Detected defaults:"
echo "  DISPLAY=$DISPLAY_VALUE"
echo "  CAPTURE_SIZE=$CAPTURE_SIZE"
echo "  CAPTURE_OFFSET=$CAPTURE_OFFSET"
echo "  CAPTURE_FRAMERATE=$CAPTURE_FRAMERATE"
echo "  FULL_FRAME_CAPTURE_SIZE=${FULL_FRAME_CAPTURE_SIZE:-disabled}"
echo "  FULL_FRAME_CAPTURE_OFFSET=$FULL_FRAME_CAPTURE_OFFSET"
echo "  FULL_FRAME_CONTENT_TYPES=$FULL_FRAME_CONTENT_TYPES"
echo "  PUBLIC_HOST=$PUBLIC_HOST"
echo "  AUDIO_SOURCE=$AUDIO_SOURCE"
echo "  PULSE_SOURCE=$PULSE_SOURCE"
echo ""

DISPLAY_VALUE="$(prompt_value "X11 display to capture" "$DISPLAY_VALUE")"
echo "Capture size is the display area FFmpeg grabs before encoding."
echo "Use 720x480 when the Pi framebuffer is 720x480, including native composite or HDMI 480p."
echo "If the Pi renders at 720p/1080p before an external converter downscales, lower the Pi display mode for best CPU usage."
if yes_no "Enable 480p optimized capture mode?" "N"; then
    CAPTURE_SIZE="640x480"
    CAPTURE_OFFSET="40,0"
    FULL_FRAME_CAPTURE_SIZE="720x480"
    FULL_FRAME_CAPTURE_OFFSET="0,0"
    FULL_FRAME_CONTENT_TYPES="guide,web"
    echo "Capture framerate: 24 = lower CPU, good TV cadence; 30 = smoother motion, higher CPU."
    CAPTURE_FRAMERATE="$(prompt_value "Capture framerate" "$CAPTURE_FRAMERATE")"
    echo "Using 480p optimized mode:"
    echo "  video/default: $CAPTURE_SIZE at offset $CAPTURE_OFFSET"
    echo "  guide/web:     $FULL_FRAME_CAPTURE_SIZE at offset $FULL_FRAME_CAPTURE_OFFSET"
    echo "  framerate:     $CAPTURE_FRAMERATE fps"
else
    CAPTURE_SIZE="$(prompt_value "Capture size" "$CAPTURE_SIZE")"
    CAPTURE_OFFSET="$(prompt_value "Capture offset" "$CAPTURE_OFFSET")"
    CAPTURE_FRAMERATE="$(prompt_value "Capture framerate" "$CAPTURE_FRAMERATE")"
    echo "Optional: use a full-frame capture profile for guide/web channels."
    echo "Example: default capture 640x480 with offset 40,0, full-frame capture 720x480 with offset 0,0."
    FULL_FRAME_CAPTURE_SIZE="$(prompt_value "Full-frame capture size for guide/web, blank disables" "$FULL_FRAME_CAPTURE_SIZE")"
    if [ -n "$FULL_FRAME_CAPTURE_SIZE" ]; then
        FULL_FRAME_CAPTURE_OFFSET="$(prompt_value "Full-frame capture offset" "$FULL_FRAME_CAPTURE_OFFSET")"
        FULL_FRAME_CONTENT_TYPES="$(prompt_value "Full-frame content types" "$FULL_FRAME_CONTENT_TYPES")"
    fi
fi
PUBLIC_HOST="$(prompt_value "Host/IP Roku should use for the bridge" "$PUBLIC_HOST")"
AUDIO_SOURCE="$(prompt_value "Bridge audio source mode: auto, pulse, or silent" "$AUDIO_SOURCE")"
if [ "$AUDIO_SOURCE" = "pulse" ]; then
    PULSE_SOURCE="$(prompt_value "PulseAudio source" "$PULSE_SOURCE")"
else
    PULSE_SOURCE="${PULSE_SOURCE:-auto}"
fi

INSTALL_BRIDGE=false
INSTALL_PLAYER_SERVICE=false
INSTALL_BRIDGE_SERVICE=false
ENABLE_SELECTED=false
ENABLE_LINGER=false

if yes_no "Install/update hls_bridge.py into FieldStation42?" "Y"; then
    INSTALL_BRIDGE=true
fi

if yes_no "Install fs42-player.service?" "Y"; then
    INSTALL_PLAYER_SERVICE=true
fi

if yes_no "Install fs42-hls-bridge.service?" "Y"; then
    INSTALL_BRIDGE_SERVICE=true
fi

if [ "$INSTALL_PLAYER_SERVICE" = true ] || [ "$INSTALL_BRIDGE_SERVICE" = true ]; then
    if yes_no "Enable and start selected services now?" "Y"; then
        ENABLE_SELECTED=true
    fi

    if yes_no "Enable user lingering so services can run before login?" "N"; then
        ENABLE_LINGER=true
    fi
fi

if [ "$INSTALL_BRIDGE" = true ]; then
    echo "Installing hls_bridge.py into FieldStation42:"
    echo "  source: $ADDON_BRIDGE_SCRIPT"
    echo "  target: $FS42_BRIDGE_SCRIPT"
    cp "$ADDON_BRIDGE_SCRIPT" "$FS42_BRIDGE_SCRIPT"
    chmod +x "$FS42_BRIDGE_SCRIPT"
fi

INSTALLED_SERVICES=()
BRIDGE_CAPTURE_PROFILE_ARGS=""
if [ -n "$FULL_FRAME_CAPTURE_SIZE" ]; then
    BRIDGE_CAPTURE_PROFILE_ARGS=" --full-frame-capture-size $FULL_FRAME_CAPTURE_SIZE --full-frame-capture-offset $FULL_FRAME_CAPTURE_OFFSET --full-frame-content-types $FULL_FRAME_CONTENT_TYPES"
fi

if [ "$INSTALL_PLAYER_SERVICE" = true ] || [ "$INSTALL_BRIDGE_SERVICE" = true ]; then
    mkdir -p "$SYSTEMD_USER_DIR"
fi

if [ "$INSTALL_PLAYER_SERVICE" = true ]; then
    require_file "$FS42_PLAYER"
    if [ ! -x "$FS42_PYTHON" ]; then
        echo "Missing FieldStation42 virtualenv Python: $FS42_PYTHON" >&2
        echo "Run the upstream FieldStation42 installer first or skip fs42-player.service." >&2
        exit 1
    fi

    cat > "$SYSTEMD_USER_DIR/fs42-player.service" <<SERVICE
[Unit]
Description=FieldStation42 Player
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
WorkingDirectory=$FS42_DIR
Environment=DISPLAY=$DISPLAY_VALUE
ExecStartPre=/bin/bash -lc 'sleep 5'
ExecStart=$FS42_PYTHON $FS42_PLAYER
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SERVICE
    INSTALLED_SERVICES+=("fs42-player.service")
fi

if [ "$INSTALL_BRIDGE_SERVICE" = true ]; then
    if [ ! -f "$FS42_BRIDGE_SCRIPT" ]; then
        echo "Bridge service needs $FS42_BRIDGE_SCRIPT, but it was not found." >&2
        echo "Install/update the bridge first or rerun and answer yes to bridge installation." >&2
        exit 1
    fi

    cat > "$SYSTEMD_USER_DIR/fs42-hls-bridge.service" <<SERVICE
[Unit]
Description=FieldStation42 Roku HLS Bridge
After=fs42-player.service graphical-session.target
Wants=fs42-player.service graphical-session.target

[Service]
Type=simple
WorkingDirectory=$FS42_DIR
Environment=DISPLAY=$DISPLAY_VALUE
ExecStart=/usr/bin/env python3 $FS42_BRIDGE_SCRIPT --status-url $FS42_STATUS_URL --hls-dir $HLS_DIR --public-host $PUBLIC_HOST --port $BRIDGE_PORT --display $DISPLAY_VALUE --capture-size $CAPTURE_SIZE --capture-offset $CAPTURE_OFFSET --capture-framerate $CAPTURE_FRAMERATE$BRIDGE_CAPTURE_PROFILE_ARGS --audio-source $AUDIO_SOURCE --pulse-source $PULSE_SOURCE
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SERVICE
    INSTALLED_SERVICES+=("fs42-hls-bridge.service")
fi

if [ "${#INSTALLED_SERVICES[@]}" -gt 0 ]; then
    systemctl --user daemon-reload

    if [ "$ENABLE_SELECTED" = true ]; then
        for service in "${INSTALLED_SERVICES[@]}"; do
            systemctl --user enable "$service"
            systemctl --user restart "$service"
        done
    fi
fi

if [ "$ENABLE_LINGER" = true ]; then
    loginctl enable-linger "$USER"
fi

echo ""
echo "Done."
echo ""

if [ "$INSTALL_BRIDGE" = true ]; then
    echo "Installed hls_bridge.py into:"
    echo "  $FS42_BRIDGE_SCRIPT"
fi

if [ "${#INSTALLED_SERVICES[@]}" -gt 0 ]; then
    echo ""
    echo "Installed systemd user services:"
    for service in "${INSTALLED_SERVICES[@]}"; do
        echo "  $SYSTEMD_USER_DIR/$service"
    done
    echo ""
    echo "Useful commands:"
    echo "  systemctl --user enable --now fs42-player.service"
    echo "  systemctl --user enable --now fs42-hls-bridge.service"
    echo "  systemctl --user restart fs42-hls-bridge.service"
    echo "  systemctl --user status fs42-player.service"
    echo "  systemctl --user status fs42-hls-bridge.service"
    echo "  journalctl --user -u fs42-hls-bridge.service -f"
fi
