# AGENTS.md

## Project: FieldStation42 Roku Client

This repository/workspace is for building a Roku client for FieldStation42. The goal is **not** to replace FieldStation42. FieldStation42 remains the backend scheduler/player. The Roku app acts as a living-room client that plays a remote HLS stream and displays a nostalgic TV/console interface.

## High-level architecture

```text
FieldStation42
  ↓
mpv local playback / status API
  ↓
fs42-stream-bridge.py
  ↓
FFmpeg transcode / HLS segment generation
  ↓
/tmp/fs42-hls
  ↓
HTTP server on port 8088
  ↓
Roku SceneGraph client
```

There are two playback paths:

```text
Local display path:
FieldStation42 → mpv → physical local display

Remote Roku path:
FieldStation42 status/API → stream bridge → FFmpeg → HLS → Roku/VLC/mpv client
```

The local display path must continue working. Remote viewing is additive.

## Expected workspace layout

```text
fs42-roku/
├── fieldstation42/        # Upstream FieldStation42 repo. Treat as reference/runtime.
├── fs42-stream-bridge/    # Python + FFmpeg bridge that creates Roku-playable HLS.
├── roku-channel/          # Roku SceneGraph/BrightScript or BrighterScript client.
└── AGENTS.md              # This file.
```

## Core design principle

Keep the responsibilities separate:

| Component | Responsibility |
|---|---|
| FieldStation42 | Catalog scanning, fake channels, scheduling, bumps/commercials, station logic, playback state |
| mpv | Local playback engine used by FieldStation42 |
| fs42-stream-bridge | Watches FieldStation42 status, starts/restarts FFmpeg, generates HLS stream |
| Roku app | Plays HLS, draws overlay, handles remote input, sends channel commands |

Do **not** rewrite FieldStation42 inside the Roku app.

Do **not** import FieldStation42 internals into the stream bridge unless there is no cleaner option.

Prefer controlling/observing FieldStation42 through its local HTTP/status API.

## Network assumptions

Do not assume a fixed LAN IP. Treat the FieldStation42 host address as user/environment-specific.

Use placeholders in docs and examples:

```text
<host-ip>
```

Common URLs:

```text
http://<host-ip>:8088/stream.m3u8
http://<host-ip>:8088/status
```

FieldStation42 player/status API may be reachable at either:

```text
http://127.0.0.1:4242/player/status
http://<host-ip>:4242/player/status
```

Use `127.0.0.1` from the same machine when possible. Use the host's LAN IP when testing from Roku or another device.

## FieldStation42 control API

FieldStation42 already exposes useful channel endpoints. The Roku app can call these directly at first.

Examples:

```text
http://<host-ip>:4242/player/channels/up
http://<host-ip>:4242/player/channels/down
http://<host-ip>:4242/player/channels/66
```

Avoid creating a separate control bridge until there is a clear need. A control bridge may be useful later for authentication, API cleanup, retry logic, combined status, or hiding FieldStation42 internals from the Roku app.

## Stream bridge responsibilities

The stream bridge is correctly named. It bridges FieldStation42 playback state to a Roku-playable HLS stream.

The stream bridge should:

- Poll FieldStation42 player/status API.
- Detect channel/file changes.
- Start or restart FFmpeg when the current media changes.
- Generate HLS files in `/tmp/fs42-hls`.
- Use stable Roku-friendly output settings.
- Avoid modifying FieldStation42 source code.
- Avoid depending on FieldStation42's Python virtual environment unless strictly necessary.

The HLS folder is currently served by:

```bash
python3 -m http.server 8088 --directory /tmp/fs42-hls
```

This may later be replaced with nginx or another simple HTTP server.

## HLS behavior and channel changes

Do not try to make one endless HLS stream survive every channel switch yet.

Treat a channel change as a stream reload event:

1. User presses Channel Up/Down on the Roku remote.
2. Roku immediately shows channel overlay, static, black screen, or transition.
3. Roku sends the channel command to FieldStation42.
4. FieldStation42 changes current channel/file.
5. Stream bridge detects the change.
6. Stream bridge restarts FFmpeg.
7. Roku stops and reloads the same HLS URL.
8. Playback resumes.

This is acceptable and currently preferred because it avoids waiting for old HLS buffers to drain.

## Current stable HLS direction

Initial `ffmpeg -c copy` remux mode was low CPU but unstable. It could play briefly and then freeze due to keyframe/timestamp issues.

Prefer transcode mode:

- H.264 video
- AAC audio
- 48 kHz audio
- 640x480 4:3 output
- 2-second HLS segments
- forced keyframes every 2 seconds
- independent HLS segments
- timestamp cleanup options

Stability is more important than ultra-low latency. On constrained hardware such as a Raspberry Pi 4B, avoid overly aggressive 0.5-second HLS segments unless testing proves it is stable.

## Useful test commands

Serve HLS folder:

```bash
python3 -m http.server 8088 --directory /tmp/fs42-hls
```

Run stream bridge:

```bash
./hls_bridge.py
```

Watch HLS files update:

```bash
watch -n 1 'ls -lh /tmp/fs42-hls'
```

Test stream with mpv:

```bash
mpv --hwdec=no http://<host-ip>:8088/stream.m3u8
```

Test stream with VLC software decode:

```bash
vlc --avcodec-hw=none http://<host-ip>:8088/stream.m3u8
```

Check FieldStation42 status:

```bash
curl http://127.0.0.1:4242/player/status
curl http://<host-ip>:4242/player/status
```

## Roku app responsibilities

The Roku app should:

- Play `http://<host-ip>:8088/stream.m3u8`.
- Display a full-screen 16:9 UI.
- Keep the video viewing area 4:3.
- Display a nostalgic TV/console-style bezel overlay.
- Show current channel number on the bezel.
- Poll FieldStation42 status or stream bridge status for current channel number.
- Send channel up/down/direct channel commands to FieldStation42.
- Force-reload the `Video` node after channel changes.
- Optionally show black/static/no-signal transition during reload.

## Roku visual design

Target canvas:

```text
1920x1080, 16:9
```

Inner video area:

```text
4:3
```

The visual goal is a nostalgic local-display or woodgrain console-TV interface. The Roku app should act like a fake cable box/front-end, not like a modern streaming app.

Possible UI elements:

- 4:3 video cutout
- woodgrain TV bezel
- channel number display
- static/black transition during reload
- old TV-style power/channel/volume indicators
- optional scanline overlay if performance allows

## Roku development stack

Use BrighterScript if practical.

BrighterScript is preferred because this project may grow enough to benefit from:

- imports
- classes/namespaces
- stronger static checking
- better VS Code workflow
- cleaner organization

The final Roku package still runs as normal Roku BrightScript/SceneGraph.

SceneGraph is Roku's XML-like UI framework. It is not HTML and not a browser.

## Development milestones

### Milestone 1: Minimal Roku HLS player

Create the smallest valid Roku app that plays:

```text
http://<host-ip>:8088/stream.m3u8
```

No bezel yet. No advanced UI. Confirm Roku playback first.

### Milestone 2: Remote key handling

Detect Roku remote buttons:

- Up
- Down
- Left
- Right
- OK
- Back
- Options, if available

Log or display the detected keypresses.

### Milestone 3: Channel commands

Wire Roku remote actions to FieldStation42 channel endpoints:

```text
/player/channels/up
/player/channels/down
/player/channels/{number}
```

After sending a channel command, reload the HLS stream.

### Milestone 4: Overlay and bezel

Add the 1920x1080 visual frame and 4:3 video window.

Add channel number display and transition behavior.

### Milestone 5: Polish

Add:

- status polling
- reconnect logic
- configurable host/IP
- error/no-signal screen
- guide/channel list
- optional scanlines

## Agent rules

When working in this project:

1. Do not modify `fieldstation42/` unless explicitly instructed.
2. Prefer adding code under `fs42-stream-bridge/` or `roku-channel/`.
3. Keep FieldStation42 as the backend authority for channels and schedules.
4. Keep the Roku app as the frontend/client only.
5. Do not make the Roku app responsible for catalog scanning or scheduling.
6. Treat HLS reload after channel change as expected behavior.
7. Prefer stable playback over lower latency.
8. Avoid unnecessary dependencies.
9. Keep configuration values such as IPs, ports, and stream URLs easy to change.
10. Add comments where Roku/BrightScript behavior is non-obvious.
11. Assume the user is newer to VS Code and Roku development, but technically capable.
12. Prefer practical, testable steps over large speculative rewrites.

## Current known-good client test

`mpv` has been more reliable than VLC for testing the HLS stream:

```bash
mpv --hwdec=no http://<host-ip>:8088/stream.m3u8
```

VLC on Linux may show VAAPI/VDPAU/video-output errors. VLC errors are not always proof that the HLS stream itself is broken.

## Summary

This project should remain modular:

```text
FieldStation42 = backend cable headend
fs42-stream-bridge = converts current playback state into HLS
Roku app = living-room cable box interface
```

Keep the split clean. Build the smallest working Roku HLS player first, then layer channel control and visual polish on top.
