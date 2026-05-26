#!/usr/bin/env python3

import argparse
import json
import os
import shutil
import signal
import subprocess
import threading
import time
import urllib.request
from datetime import datetime
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


DEFAULT_STATUS_URL = "http://127.0.0.1:4242/player/status"
DEFAULT_HLS_DIR = "/tmp/fs42-hls"
DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8088
POLL_SECONDS = 0.5

OUTPUT_WIDTH = 640
OUTPUT_HEIGHT = 480
CAPTURE_SIZE = "auto"
CAPTURE_SIZE_FALLBACK = "720x480"
CAPTURE_FRAMERATE = 30
HLS_TIME = 2
HLS_LIST_SIZE = 10


class BridgeState:
    def __init__(self):
        self.lock = threading.Lock()
        self.generation = 0
        self.mode = "starting"
        self.message = "Bridge is starting."
        self.channel_number = None
        self.file_path = None
        self.last_fs42_status = None
        self.updated_at = None

    def update(self, **values):
        with self.lock:
            for key, value in values.items():
                setattr(self, key, value)
            self.updated_at = datetime.now().isoformat(timespec="seconds")

    def bump_generation(self, **values):
        with self.lock:
            self.generation += 1
            for key, value in values.items():
                setattr(self, key, value)
            self.updated_at = datetime.now().isoformat(timespec="seconds")

    def snapshot(self):
        with self.lock:
            return {
                "stream_generation": self.generation,
                "mode": self.mode,
                "message": self.message,
                "channel_number": self.channel_number,
                "file_path": self.file_path,
                "last_fs42_status": self.last_fs42_status,
                "updated_at": self.updated_at,
            }


class BridgeHttpHandler(SimpleHTTPRequestHandler):
    bridge_state = None

    def do_GET(self):
        if self.path in ("/status", "/status.json", "/health"):
            self.send_json(self.bridge_state.snapshot())
            return

        super().do_GET()

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        super().end_headers()

    def send_json(self, payload):
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def parse_hms(value):
    if not value or value == "n/a":
        return 0

    try:
        parts = [int(float(part)) for part in value.strip().split(":")]

        if len(parts) == 3:
            hours, minutes, seconds = parts
            return hours * 3600 + minutes * 60 + seconds

        if len(parts) == 2:
            minutes, seconds = parts
            return minutes * 60 + seconds

        if len(parts) == 1:
            return parts[0]
    except Exception:
        return 0

    return 0


def get_seek_seconds(status):
    base_seek = 0

    duration = status.get("duration")
    if duration and "/" in duration:
        base_seek = parse_hms(duration.split("/")[0])

    timestamp = status.get("timestamp")
    if timestamp:
        try:
            started_at = datetime.fromisoformat(timestamp)
            now = datetime.now(started_at.tzinfo)
            elapsed = max(0, int((now - started_at).total_seconds()))
            return base_seek + elapsed
        except Exception:
            pass

    return base_seek


def read_status_file(status_file):
    if not status_file:
        return None

    try:
        with open(status_file, "r", encoding="utf-8") as status_fp:
            status_text = status_fp.read().strip()
    except FileNotFoundError:
        return None
    except Exception as exc:
        print(f"Could not read FS42 status file {status_file}: {exc}")
        return None

    if not status_text:
        return None

    try:
        return json.loads(status_text)
    except Exception as exc:
        print(f"Could not parse FS42 status file {status_file}: {exc}")
        return None


def fetch_status(status_url, status_file=None):
    try:
        with urllib.request.urlopen(status_url, timeout=2) as response:
            status = json.loads(response.read().decode("utf-8"))
            if "error" not in status:
                return status

            print(f"FS42 status API returned an error: {status['error']}")
    except Exception as exc:
        print(f"Could not read FS42 status from {status_url}: {exc}")

    status = read_status_file(status_file)
    if status:
        return status

    return None


def clear_hls_dir(hls_dir):
    os.makedirs(hls_dir, exist_ok=True)

    for name in os.listdir(hls_dir):
        path = os.path.join(hls_dir, name)

        try:
            if os.path.isfile(path) or os.path.islink(path):
                os.remove(path)
            elif os.path.isdir(path):
                shutil.rmtree(path)
        except Exception as exc:
            print(f"Could not remove {path}: {exc}")


def stop_ffmpeg(proc):
    if proc and proc.poll() is None:
        print("Stopping FFmpeg process...")
        proc.send_signal(signal.SIGTERM)

        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            print("FFmpeg did not stop cleanly; killing it.")
            proc.kill()
            proc.wait(timeout=3)


def status_key(status):
    return (
        status.get("channel_number"),
        status.get("file_path"),
        status.get("timestamp"),
    )


def hls_common_args(hls_dir, playlist):
    segment_pattern = os.path.join(hls_dir, "segment_%010d.ts")

    return [
        "-start_at_zero",
        "-avoid_negative_ts",
        "make_zero",
        "-muxdelay",
        "0",
        "-muxpreload",
        "0",
        "-f",
        "hls",
        "-hls_time",
        str(HLS_TIME),
        "-hls_list_size",
        str(HLS_LIST_SIZE),
        "-hls_start_number_source",
        "epoch",
        "-hls_flags",
        "delete_segments+independent_segments+program_date_time+omit_endlist+discont_start",
        "-hls_segment_filename",
        segment_pattern,
        playlist,
    ]


def build_video_filter():
    return f"scale={OUTPUT_WIDTH}:{OUTPUT_HEIGHT},setsar=1"


def build_screen_input(display, capture_offset):
    display_input = display
    if capture_offset:
        display_input = f"{display_input}+{capture_offset}"
    return display_input


def detect_display_size(display):
    display_name = display.split("+", 1)[0]

    try:
        output = subprocess.check_output(
            ["xdpyinfo", "-display", display_name],
            stderr=subprocess.STDOUT,
            text=True,
            timeout=3,
        )
    except FileNotFoundError:
        print("Could not auto-detect display size because xdpyinfo is not installed.")
        return None
    except Exception as exc:
        print(f"Could not auto-detect display size for {display_name}: {exc}")
        return None

    for line in output.splitlines():
        line = line.strip()
        if line.startswith("dimensions:"):
            parts = line.split()
            if len(parts) >= 2 and "x" in parts[1]:
                return parts[1]

    print(f"Could not find display dimensions in xdpyinfo output for {display_name}.")
    return None


def resolve_capture_size(args):
    if args.capture_size.lower() != "auto":
        return args.capture_size

    detected_size = detect_display_size(args.display)
    if detected_size:
        return detected_size

    print(f"Falling back to capture size {CAPTURE_SIZE_FALLBACK}.")
    return CAPTURE_SIZE_FALLBACK


def detect_pulse_monitor_source():
    try:
        default_sink = subprocess.check_output(
            ["pactl", "get-default-sink"],
            stderr=subprocess.STDOUT,
            text=True,
            timeout=3,
        ).strip()
        if default_sink:
            return f"{default_sink}.monitor"
    except FileNotFoundError:
        print("Could not auto-detect PulseAudio monitor because pactl is not installed.")
        return None
    except Exception as exc:
        print(f"Could not read default PulseAudio sink: {exc}")

    try:
        output = subprocess.check_output(
            ["pactl", "list", "short", "sources"],
            stderr=subprocess.STDOUT,
            text=True,
            timeout=3,
        )
    except Exception as exc:
        print(f"Could not list PulseAudio sources: {exc}")
        return None

    for line in output.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].endswith(".monitor"):
            return parts[1]

    print("Could not find a PulseAudio monitor source.")
    return None


def resolve_audio_input(args):
    if args.audio_source == "silent":
        return "silent", None

    if args.audio_source == "pulse" and args.pulse_source != "auto":
        return "pulse", args.pulse_source

    monitor_source = detect_pulse_monitor_source()
    if monitor_source:
        return "pulse", monitor_source

    if args.audio_source == "pulse":
        print("Falling back to PulseAudio source 'default'.")
        return "pulse", "default"

    print("Falling back to silent audio.")
    return "silent", None


def build_screen_command(args, playlist, capture_size, audio_mode, audio_source):
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "info",
        "-thread_queue_size",
        "1024",
        "-f",
        "x11grab",
        "-draw_mouse",
        "0",
        "-framerate",
        str(args.capture_framerate),
        "-video_size",
        capture_size,
        "-i",
        build_screen_input(args.display, args.capture_offset),
    ]

    if audio_mode == "pulse":
        cmd.extend(["-thread_queue_size", "1024", "-f", "pulse", "-i", audio_source])
    else:
        cmd.extend(
            [
                "-thread_queue_size",
                "1024",
                "-f",
                "lavfi",
                "-i",
                "anullsrc=channel_layout=stereo:sample_rate=48000",
            ]
        )

    return [
        *cmd,
        "-map",
        "0:v:0",
        "-map",
        "1:a:0",
        "-vf",
        build_video_filter(),
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-tune",
        "zerolatency",
        "-crf",
        "25",
        "-pix_fmt",
        "yuv420p",
        "-g",
        str(args.capture_framerate * HLS_TIME),
        "-keyint_min",
        str(args.capture_framerate * HLS_TIME),
        "-sc_threshold",
        "0",
        "-force_key_frames",
        f"expr:gte(t,n_forced*{HLS_TIME})",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-ac",
        "2",
        "-ar",
        "48000",
        *hls_common_args(args.hls_dir, playlist),
    ]


def build_media_command(file_path, seek_seconds, hls_dir, playlist, use_copy_mode):
    common_hls = hls_common_args(hls_dir, playlist)

    if use_copy_mode:
        return [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "info",
            "-re",
            "-ss",
            str(seek_seconds),
            "-fflags",
            "+genpts",
            "-i",
            file_path,
            "-map",
            "0:v:0",
            "-map",
            "0:a:0?",
            "-c",
            "copy",
            *common_hls,
        ]

    return [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "info",
        "-re",
        "-ss",
        str(seek_seconds),
        "-i",
        file_path,
        "-map",
        "0:v:0",
        "-map",
        "0:a:0?",
        "-vf",
        build_video_filter(),
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "23",
        "-pix_fmt",
        "yuv420p",
        "-g",
        "60",
        "-keyint_min",
        "60",
        "-sc_threshold",
        "0",
        "-force_key_frames",
        f"expr:gte(t,n_forced*{HLS_TIME})",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-ac",
        "2",
        "-ar",
        "48000",
        "-af",
        "aresample=async=1:first_pts=0",
        *common_hls,
    ]


def build_filler_command(hls_dir, playlist):
    return [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "info",
        "-re",
        "-f",
        "lavfi",
        "-i",
        f"color=c=black:s={OUTPUT_WIDTH}x{OUTPUT_HEIGHT}:r=30",
        "-f",
        "lavfi",
        "-i",
        "anullsrc=channel_layout=stereo:sample_rate=48000",
        "-map",
        "0:v:0",
        "-map",
        "1:a:0",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "28",
        "-pix_fmt",
        "yuv420p",
        "-g",
        "60",
        "-keyint_min",
        "60",
        "-sc_threshold",
        "0",
        "-force_key_frames",
        f"expr:gte(t,n_forced*{HLS_TIME})",
        "-c:a",
        "aac",
        "-b:a",
        "96k",
        "-ac",
        "2",
        "-ar",
        "48000",
        *hls_common_args(hls_dir, playlist),
    ]


def playlist_ready(playlist, timeout_seconds=8):
    deadline = time.time() + timeout_seconds

    while time.time() < deadline:
        try:
            with open(playlist, "r", encoding="utf-8") as playlist_fp:
                for line in playlist_fp:
                    segment_name = line.strip()
                    if segment_name and not segment_name.startswith("#"):
                        segment_path = os.path.join(os.path.dirname(playlist), segment_name)
                        if os.path.exists(segment_path):
                            return True
        except FileNotFoundError:
            pass
        except Exception as exc:
            print(f"Could not inspect HLS playlist {playlist}: {exc}")
            return False

        time.sleep(0.1)

    return False


def start_process(cmd, hls_dir, clear_existing=True):
    if clear_existing:
        clear_hls_dir(hls_dir)

    return subprocess.Popen(cmd)


def start_media(
    file_path,
    seek_seconds,
    args,
    state,
    publish_generation=True,
    clear_existing=True,
):
    playlist = os.path.join(args.hls_dir, "stream.m3u8")
    cmd = build_media_command(file_path, seek_seconds, args.hls_dir, playlist, args.copy)

    print("")
    print("Starting FFmpeg media HLS:")
    print(f"  file:       {file_path}")
    print(f"  seek:       {seek_seconds}s")
    print(f"  playlist:   {playlist}")
    print(f"  mode:       {'copy/remux' if args.copy else 'transcode'}")
    print(f"  publish:    {'yes' if publish_generation else 'no'}")
    print("")

    proc = start_process(cmd, args.hls_dir, clear_existing)
    if not playlist_ready(playlist):
        print("Warning: media HLS playlist was not ready before timeout.")

    state_values = {
        "mode": "media",
        "message": "Streaming FieldStation42 media.",
        "file_path": file_path,
    }
    if publish_generation:
        state.bump_generation(**state_values)
    else:
        state.update(**state_values)

    return proc


def start_filler(args, state, message, publish_generation=True, clear_existing=True):
    playlist = os.path.join(args.hls_dir, "stream.m3u8")
    cmd = build_filler_command(args.hls_dir, playlist)

    print("")
    print("Starting FFmpeg filler HLS:")
    print(f"  reason:    {message}")
    print(f"  playlist:  {playlist}")
    print(f"  publish:   {'yes' if publish_generation else 'no'}")
    print("")

    proc = start_process(cmd, args.hls_dir, clear_existing)
    if not playlist_ready(playlist):
        print("Warning: filler HLS playlist was not ready before timeout.")

    state_values = {"mode": "filler", "message": message, "file_path": None}
    if publish_generation:
        state.bump_generation(**state_values)
    else:
        state.update(**state_values)

    return proc


def start_screen_capture(args, state, publish_generation=True, clear_existing=True):
    playlist = os.path.join(args.hls_dir, "stream.m3u8")
    capture_size = resolve_capture_size(args)
    audio_mode, audio_source = resolve_audio_input(args)
    cmd = build_screen_command(args, playlist, capture_size, audio_mode, audio_source)

    print("")
    print("Starting FFmpeg screen-capture HLS:")
    print(f"  display:   {build_screen_input(args.display, args.capture_offset)}")
    print(f"  size:      {capture_size} @ {args.capture_framerate} fps")
    if audio_source:
        print(f"  audio:     {audio_mode} ({audio_source})")
    else:
        print(f"  audio:     {audio_mode}")
    print(f"  playlist:  {playlist}")
    print(f"  publish:   {'yes' if publish_generation else 'no'}")
    print("")

    proc = start_process(cmd, args.hls_dir, clear_existing)
    if not playlist_ready(playlist):
        print("Warning: screen-capture HLS playlist was not ready before timeout.")

    state_values = {
        "mode": "screen",
        "message": "Streaming captured FieldStation42 screen.",
        "file_path": None,
    }
    if publish_generation:
        state.bump_generation(**state_values)
    else:
        state.update(**state_values)

    return proc


def get_playable_file(status):
    current_status = status.get("status")
    if current_status and current_status != "playing":
        return None, f"FS42 status is {current_status}."

    file_path = status.get("file_path")
    if not file_path:
        return None, "FS42 status does not include a file_path."

    if file_path.startswith(("http://", "https://")):
        return None, f"URL streams are not mirrored yet: {file_path}"

    if not os.path.exists(file_path):
        return None, f"File is not accessible from this machine: {file_path}"

    return file_path, None


def run_http_server(args, state):
    BridgeHttpHandler.bridge_state = state
    handler = partial(BridgeHttpHandler, directory=args.hls_dir)
    server = ThreadingHTTPServer((args.host, args.port), handler)
    print(f"Serving HLS at http://{args.public_host}:{args.port}/stream.m3u8")
    print(f"Serving bridge status at http://{args.public_host}:{args.port}/status")
    server.serve_forever()


def run_bridge(args, state):
    if args.source == "screen":
        run_screen_bridge(args, state)
        return

    ffmpeg_proc = None
    last_key = None
    last_channel = None
    current_mode = None

    os.makedirs(args.hls_dir, exist_ok=True)

    try:
        while True:
            status = fetch_status(args.status_url, args.status_file)

            if not status:
                state.update(last_fs42_status=None)
                if current_mode != "filler":
                    stop_ffmpeg(ffmpeg_proc)
                    ffmpeg_proc = start_filler(args, state, "Waiting for FieldStation42 status.")
                    current_mode = "filler"
                    last_key = None
                    last_channel = None
                time.sleep(args.poll_seconds)
                continue

            channel_number = status.get("channel_number")
            state.update(
                last_fs42_status=status.get("status"),
                channel_number=channel_number,
            )

            file_path, unplayable_reason = get_playable_file(status)

            if unplayable_reason:
                if current_mode != "filler":
                    publish_generation = channel_number != last_channel or current_mode != "filler"
                    stop_ffmpeg(ffmpeg_proc)
                    ffmpeg_proc = start_filler(
                        args,
                        state,
                        unplayable_reason,
                        publish_generation=publish_generation,
                        clear_existing=publish_generation,
                    )
                    current_mode = "filler"
                    last_key = None
                    last_channel = channel_number
                else:
                    state.update(message=unplayable_reason)

                time.sleep(args.poll_seconds)
                continue

            new_key = status_key(status)
            if current_mode != "media" or new_key != last_key:
                publish_generation = current_mode != "media" or channel_number != last_channel
                stop_ffmpeg(ffmpeg_proc)
                ffmpeg_proc = start_media(
                    file_path,
                    get_seek_seconds(status),
                    args,
                    state,
                    publish_generation=publish_generation,
                    clear_existing=publish_generation,
                )
                current_mode = "media"
                last_key = new_key
                last_channel = channel_number

            if ffmpeg_proc and ffmpeg_proc.poll() is not None:
                exit_code = ffmpeg_proc.poll()
                print(f"FFmpeg exited with code {exit_code}.")

                if current_mode == "media":
                    fresh_status = fetch_status(args.status_url, args.status_file) or status
                    fresh_file, reason = get_playable_file(fresh_status)

                    if fresh_file:
                        last_key = status_key(fresh_status)
                        last_channel = fresh_status.get("channel_number")
                        ffmpeg_proc = start_media(
                            fresh_file,
                            get_seek_seconds(fresh_status),
                            args,
                            state,
                        )
                    else:
                        ffmpeg_proc = start_filler(args, state, reason or "Media ended.")
                        current_mode = "filler"
                        last_key = None
                        last_channel = fresh_status.get("channel_number")
                else:
                    ffmpeg_proc = start_filler(args, state, "Restarting filler stream.")

            time.sleep(args.poll_seconds)

    except KeyboardInterrupt:
        print("")
        print("Stopping bridge...")
    finally:
        stop_ffmpeg(ffmpeg_proc)
        print("Bridge stopped.")


def run_screen_bridge(args, state):
    ffmpeg_proc = None
    last_channel = None

    os.makedirs(args.hls_dir, exist_ok=True)

    try:
        ffmpeg_proc = start_screen_capture(args, state)

        while True:
            status = fetch_status(args.status_url, args.status_file)

            if status:
                channel_number = status.get("channel_number")
                if last_channel is not None and channel_number != last_channel:
                    print(f"Detected channel change from {last_channel} to {channel_number}; restarting screen HLS.")
                    stop_ffmpeg(ffmpeg_proc)
                    ffmpeg_proc = start_screen_capture(args, state)

                state.update(
                    last_fs42_status=status.get("status"),
                    channel_number=channel_number,
                )
                last_channel = channel_number
            else:
                state.update(
                    last_fs42_status=None,
                    channel_number=last_channel,
                    message="Streaming captured screen; waiting for FieldStation42 status.",
                )

            if ffmpeg_proc and ffmpeg_proc.poll() is not None:
                exit_code = ffmpeg_proc.poll()
                print(f"FFmpeg screen capture exited with code {exit_code}; restarting.")
                ffmpeg_proc = start_screen_capture(args, state)

            time.sleep(args.poll_seconds)

    except KeyboardInterrupt:
        print("")
        print("Stopping bridge...")
    finally:
        stop_ffmpeg(ffmpeg_proc)
        print("Bridge stopped.")


def parse_args():
    parser = argparse.ArgumentParser(description="FieldStation42 HLS bridge for Roku clients.")
    parser.add_argument("--status-url", default=DEFAULT_STATUS_URL)
    parser.add_argument(
        "--status-file",
        default=os.environ.get("FS42_STATUS_FILE"),
        help="Optional fallback FieldStation42 play_status.socket path.",
    )
    parser.add_argument("--hls-dir", default=DEFAULT_HLS_DIR)
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--public-host", default="127.0.0.1")
    parser.add_argument("--poll-seconds", type=float, default=POLL_SECONDS)
    parser.add_argument(
        "--source",
        choices=("screen", "media"),
        default="screen",
        help="Use screen capture or the legacy per-media-file mirror.",
    )
    parser.add_argument(
        "--display",
        default=os.environ.get("DISPLAY", ":0.0"),
        help="X11 display to capture in screen mode.",
    )
    parser.add_argument(
        "--capture-size",
        default=CAPTURE_SIZE,
        help="X11 capture size, for example 720x480. Use auto to detect the display size.",
    )
    parser.add_argument("--capture-offset", default="0,0")
    parser.add_argument("--capture-framerate", type=int, default=CAPTURE_FRAMERATE)
    parser.add_argument(
        "--audio-source",
        choices=("auto", "silent", "pulse"),
        default="auto",
        help="Use automatic PulseAudio monitor capture, silent audio, or a PulseAudio source in screen mode.",
    )
    parser.add_argument(
        "--pulse-source",
        default="auto",
        help="PulseAudio source for screen mode. Use auto to capture the default sink monitor.",
    )
    parser.add_argument("--copy", action="store_true", help="Use FFmpeg copy/remux mode.")
    return parser.parse_args()


def main():
    args = parse_args()
    state = BridgeState()

    print("FieldStation42 HLS bridge starting...")
    print(f"Watching FS42 status: {args.status_url}")
    print(f"Fallback status file: {args.status_file}")
    print(f"Source mode:          {args.source}")
    print(f"Writing HLS files:    {args.hls_dir}")
    print("")

    http_thread = threading.Thread(target=run_http_server, args=(args, state), daemon=True)
    http_thread.start()

    run_bridge(args, state)


if __name__ == "__main__":
    main()
