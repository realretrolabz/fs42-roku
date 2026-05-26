# FieldStation42 HLS Bridge

The main setup guide now lives in the repository root:

```text
../README.md
```

Use that README for the full FieldStation42 host setup, HLS bridge setup, systemd installer, and Roku sideloading instructions.

Bridge quick facts:

- Script: `hls_bridge.py`
- Default status URL: `http://127.0.0.1:4242/player/status`
- HLS playlist: `http://<host-ip>:8088/stream.m3u8`
- Bridge status: `http://<host-ip>:8088/status`

Run:

```bash
./hls_bridge.py --help
```

Common examples:

```bash
./hls_bridge.py --status-url http://127.0.0.1:4242/player/status
./hls_bridge.py --public-host <host-ip> --port 8088
./hls_bridge.py --display :0.0 --capture-size 720x480
./hls_bridge.py --audio-source pulse --pulse-source auto
```
