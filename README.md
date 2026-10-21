# Reachy Mini Lite on the Arduino UNO Q

Host a **Reachy Mini Lite** from an **Arduino UNO Q**: the board runs the upstream
`reachy-mini` daemon in a container and drives the robot over USB.

## Why this is tractable

The **Lite** has no onboard computer — it is a USB peripheral, so "transplanting" the Reachy
stack does not mean porting an OS image. It means running the daemon on a Debian host. That
removes every Pi-specific layer of the official CM4 image: no device tree, no libcamera/IMX708
CSI, no UART3 motor bus, no i²c IMU, no fan controller, no GPIO button.

The robot presents as three ordinary USB devices (all verified on the board with the Lite attached):

| Need   | Device                                    | On-board node / evidence                  |
|--------|-------------------------------------------|-------------------------------------------|
| Motors | USB serial `1a86:55d3`                    | `/dev/ttyACM0` (CDC-ACM), `find_serial_port()` |
| Camera | UVC `38FB:1002`, named `Reachy`           | udev by-id symlinks; current nodes `/dev/video2` + `/dev/video3` |
| Audio  | `38FB:1001` "Reachy Mini Audio"           | ALSA card 0; `device_detection.py`        |

`/dev/video2` and `/dev/video3` are the QRB2210's own venus decoder/encoder, **not** the robot.

## Status

| Step | State |
|------|-------|
| Container image builds (Debian 13 trixie, Python 3.12, `reachy-mini==1.10.0`) | ✅ |
| Daemon boots and serves the API (`GET /api/daemon/status` → 200) | ✅ |
| GStreamer typelibs present (`gi.require_version("Gst","1.0")`) | ✅ |
| WebRTC Rust plugins (`webrtcsink`, `webrtcsrc`, `rtpgccbwe`) | ✅ |
| **Motors** — control loop runs against real hardware, 0 errors | ✅ 49.1 Hz |
| **Camera** — detected as `camera_specs_name: "lite"`, real 1080p60 frames captured | ✅ |
| **Audio source** — robot mic enumerated via PulseAudio passthrough | ✅ |
| Robot awake and under control (`motor_control_mode: enabled`) | ✅ |
| App Lab custom Brick wrapper (`bricks/reachy_daemon/`) | ⚠️ written, **not yet run through App Lab** |
| WebRTC signaling port 8443 exposed | ✅ |
| WebRTC video streaming end to end | ⚠️ not yet verified (encoder budget, see below) |

Verified end to end with `0.5`: **0** hardware-detection warnings — motors, camera and audio are
all found, and the daemon drives the robot.

## Blockers and caveats

1. **The container needs the host udev database.** This is the single non-obvious requirement:
   GStreamer's v4l2 *device provider* enumerates cameras through udev, and a container has no udev
   database of its own. Without `-v /run/udev:/run/udev:ro` the daemon reports `No camera found`
   and serves no video — **even though `/dev/video0` is mounted and works**, as
   `gst-launch-1.0 v4l2src device=/dev/video0 ! videoconvert ! fakesink` proves.

2. **Audio needs the host's PipeWire/PulseAudio socket.** Without a pulse plugin the container sees
   the robot only as an `Audio/Sink`, never an `Audio/Source`: the daemon warns
   `No Reachy Mini Audio Source card found`, falls back to `autoaudiosrc` and then floods
   `Can't record audio fast enough` / `Dropped N samples`. Image `0.5` installs
   `gstreamer1.0-pulseaudio` and you pass the socket through (`-v /run/user/1000:/run/user/1000`
   plus `PULSE_SERVER=unix:/run/user/1000/pulse/native`), which is the same approach the official
   Reachy image takes. Use the **pulse** plugin rather than `gstreamer1.0-pipewire`: the SDK
   matches PulseAudio-style display names (`Reachy Mini Audio Analog Stereo`).

3. **Resolution is 1080p60 only.** `ReachyMiniLiteCamSpecs.available_resolutions` has no 720p
   mode and there is no CLI/env knob to change it. On 4× Cortex-A53 that is the CPU budget hog.
   (The wireless profile defaults to 720p30; the Lite does not.)

4. **H.264 encoding is software.** The official image's patched `v4l2h264enc` gives the Pi a
   hardware encoder. The UNO Q has no Pi hardware encoder, and that overlay is Pi-specific, so
   WebRTC encoding runs on the CPU. Streaming is expected to be the tightest resource.

5. **Docker Hub is unreachable from this board's network** (an intercepting proxy answers HTTP to
   HTTPS). `ghcr.io` works. Builds therefore use `python:3.12-slim-trixie` **only because it is
   cached locally** — do not expect to re-pull it. Anything new should come from ghcr.io.

## Gotchas that cost real time

- **GStreamer plugins ≠ GStreamer typelibs.** Installing `gstreamer1.0-plugins-*` gives you the
  plugin `.so` files but *not* the GObject-Introspection typelibs. Without
  `gir1.2-gstreamer-1.0` + `gir1.2-gst-plugins-base-1.0`, `gi.require_version("Gst","1.0")` raises
  `ValueError: Namespace Gst not available` and the daemon dies on import
  (`reachy_mini.vision.face_tracking`).
- **Never install `reachy-mini[wireless-version]` or pass `--wireless-version`.** The flag switches
  `find_serial_port()` to the Pi UART `/dev/ttyAMA3` instead of the Lite's USB serial, so the
  motors are never found. The extra also drags in sdist-only `nmcli` and `pollen_BMI088_imu_library`.
- **The camera *node* working does not mean the camera is *detected*.** `v4l2src` can capture from
  `/dev/video0` while `Gst.DeviceMonitor` still reports zero video devices. Test data flow and
  enumeration separately — see blocker 1.
- **The entrypoint rebuilds `$@`**, so anything appended to `docker run` is discarded. Configure
  through `REACHY_*` environment variables instead.
- **The motor bridge is CDC-ACM**, so it is `/dev/ttyACM0`, not `/dev/ttyUSB0` — the obvious guess
  from "CH340/CH34x" is wrong here.

## Build

```bash
cd /home/arduino/reachy-mini-unoq
DOCKER_BUILDKIT=1 docker build -t reachy-mini-unoq:0.7 .
```

> **Do not build while the daemon is running.** On the 4 GB board the daemon's media server uses
> ~2 GB of anonymous RSS; a concurrent `docker build` pushed the board into global OOM and the
> daemon was killed (`Exited (137)`, `Out of memory: Killed process (python) ... anon-rss:2016368kB`).
> Stop the container first (`docker rm -f reachy`).

## Run with plain Docker (no robot required)

```bash
docker run --rm --name reachy-media \
  -e REACHY_SIM=mockup -e REACHY_SERIAL_DEV=/dev/null \
  -p 8000:8000 reachy-mini-unoq:0.5

# in another shell
curl -s localhost:8000/api/daemon/status
# then browse http://<board-ip>:8000/docs
```

With the robot attached, use host networking so WebRTC ICE can exchange its negotiated UDP media
ports. Publishing only TCP 8000 and 8443 allows signaling but not the video stream. The camera
nodes are discovered through udev by-id links because `/dev/videoN` numbering changes on reboot.
`REACHY_WAKE=0` avoids commanding the robot to move:

```bash
ROBOT_IP=$(ip -4 -o addr show dev wlan0 | awk '{split($4, a, "/"); print a[1]}')
CAMERA0=$(readlink -f /dev/v4l/by-id/*Reachy*video-index0)
CAMERA1=$(readlink -f /dev/v4l/by-id/*Reachy*video-index1)
test -c "$CAMERA0" && test -c "$CAMERA1" || { echo "Reachy camera not found"; exit 1; }
docker rm -f reachy 2>/dev/null || true
docker run -d --name reachy --restart unless-stopped --network host \
  -v /run/udev:/run/udev:ro \
  -v /run/user/1000:/run/user/1000 \
  -e PULSE_SERVER=unix:/run/user/1000/pulse/native \
  -e REACHY_SERIAL_PORT=/dev/ttyACM0 \
  -e REACHY_WAKE=0 \
  --device /dev/ttyACM0 --device "$CAMERA0" --device "$CAMERA1" --device /dev/snd \
  --group-add dialout --group-add video --group-add audio \
  reachy-mini-unoq:0.7
```

Drop `REACHY_WAKE=0` (or set it to `1`) to let the daemon wake the robot — that will make it move.

## App Lab Brick

`app-lab/` is a complete App Lab app whose only brick is a custom container brick wrapping the
daemon:

```text
app-lab/
├── app.yaml                         # declares the reachy_daemon brick + variables
├── python/main.py                   # waits for the daemon, then polls status
└── bricks/reachy_daemon/
    ├── brick_config.yaml            # id, required_devices, ports, variables
    ├── brick_compose.yaml           # runs the daemon container
    └── __init__.py                  # thin HTTP client used by main.py
```

The Brick uses host networking so negotiated WebRTC UDP traffic reaches the board's LAN
interface. Its image discovers the current `wlan0` address at startup; `REACHY_ADVERTISED_IP`
can override that when needed. The app-side client tries the Compose service name first, then the
Docker bridge gateway for the host-networked daemon. `brick_config.yaml` declares
`required_devices: [camera, microphone, speaker]` with `mount_devices_into_container: true`, so
the orchestrator mounts the robot's UVC/UAC devices automatically; the motor serial is mounted
explicitly since it has no device class.

Set `REACHY_IMAGE` to the registry/tag you push to — App Lab cannot pull private images.

### Smoke test without a robot

Set `REACHY_SIM=mockup` and `REACHY_SERIAL_DEV=/dev/null` in the app variables. The daemon then
runs its lightweight mockup backend, so the container, the app-to-daemon HTTP route, the Brick
and the App Lab lifecycle can all be validated with no hardware attached.
