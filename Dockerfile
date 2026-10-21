# Reachy Mini Lite daemon on Arduino UNO Q
#
# Base: the official Debian 13 (trixie) Python image.  Chosen because
#   1. it ships Python 3.12 in /usr/local -- inside reachy-mini's supported 3.10-3.12 range,
#      so no side-loaded interpreter has to be installed and managed;
#   2. it is trixie, the same userland as the board, and provides GStreamer 1.26.x -- the
#      version the official Reachy Mini image's patched v4l2h264enc overlay targets;
#   3. it matches upstream, so the image is reproducible from the public registry.
# It is a plain runtime base, though: no C toolchain, no GStreamer plugins -- those are
# installed explicitly below (the App Lab base used to carry them).
FROM python:3.12-slim-trixie

# root is the default user of this base, and apt needs it anyway.
USER root

# PyGObject has no PyPI wheels, so it is compiled from source -- this is the same build-dependency
# set the official image carries (reachy-mini-os stage2/01-sys-tweaks/00-packages-nr), plus the
# toolchain (build-essential / meson / ninja-build) that a slim base does not include.
# Python 3.12 headers ship in /usr/local/include/python3.12, so Debian's python3-dev (3.13!) is
# deliberately NOT installed -- it would only shadow the interpreter we build against.
#
# NOTE the three families are NOT interchangeable -- you need all of them:
#   * gstreamer1.0-plugins-*   -> the plugin .so objects (the actual elements/pipelines)
#   * gir1.2-gstreamer-1.0 / gir1.2-gst-plugins-base-1.0 -> the GObject-Introspection typelibs
#   * gstreamer1.0-pulseaudio  -> the PulseAudio device provider used to enumerate the robot's
#                                 microphone. Without it the daemon reports
#                                 "No Reachy Mini Audio Source card found": the board's ALSA
#                                 provider lists the robot as a *sink* only, and never a source.
# Without the gir1.2-* packages `gi.require_version("Gst", "1.0")` raises
# "Namespace Gst not available" and the daemon dies on import (reachy_mini.vision.face_tracking).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential git meson ninja-build pkg-config \
      libgirepository1.0-dev libcairo2-dev libglib2.0-dev libffi-dev \
      gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
      gstreamer1.0-plugins-bad gstreamer1.0-alsa gstreamer1.0-nice \
      gstreamer1.0-pulseaudio \
      gir1.2-glib-2.0 gir1.2-gstreamer-1.0 gir1.2-gst-plugins-base-1.0 \
     libportaudio2 alsa-utils usbutils v4l-utils curl ca-certificates patch \
 && rm -rf /var/lib/apt/lists/*

ENV UV_LINK_MODE=copy \
    UV_CACHE_DIR=/tmp/uvcache \
    MALLOC_ARENA_MAX=2 \
    VIRTUAL_ENV=/opt/reachy/venv \
    HOME=/home/app \
    PATH=/opt/reachy/venv/bin:$PATH

# The base interpreter *is* 3.12, so the venv is created directly from it; uv is only kept
# for its fast, low-backtracking resolution of reachy-mini's large dependency tree.
RUN pip install --no-cache-dir uv \
 && python -m venv "${VIRTUAL_ENV}"

# PLAIN reachy-mini, deliberately NOT reachy-mini[wireless-version]:
#   * the extra only pulls Pi-only machinery (nmcli, pollen_BMI088_imu_library, lgpio), and the
#     wireless routers are gated behind --wireless-version anyway;
#   * more importantly, --wireless-version switches find_serial_port() to the Pi UART
#     (/dev/ttyAMA3) instead of the Lite's USB serial (VID:PID 1a86:55d3) -> motors never found.
RUN uv pip install "reachy-mini==1.10.0" \
 && rm -rf "${UV_CACHE_DIR}"

# Lite mode normally leaves wlan_ip unset because upstream expects its client on the same
# machine. In host networking mode, discover wlan0 dynamically so remote WebRTC clients do not
# fall back to localhost. REACHY_ADVERTISED_IP remains available as an explicit override.
COPY patches/advertise-lite-ip.patch /tmp/advertise-lite-ip.patch
RUN patch -d /opt/reachy/venv/lib/python3.12/site-packages -p1 < /tmp/advertise-lite-ip.patch \
 && rm /tmp/advertise-lite-ip.patch

# WebRTC needs the Rust plugins (webrtcsink / webrtcsrc / rtpgccbwe). Debian does NOT ship
# gstreamer1.0-plugins-rs, and without webrtcsink the daemon logs
# "Failed to initialize media server" on every boot and serves no video.
#
# This is the official aarch64 overlay published by pollen-robotics/reachy-mini-os. It is built
# in a debian:trixie container -- the same userland this image is based on -- which is why it
# loads against the container's GStreamer 1.26.2. Verified with:
#   gst-inspect-1.0 webrtcsink / webrtcsrc / rtpgccbwe  (all register)
# The sha256 is pinned by the upstream repo's files/gst-plugins-rs.pin, so a bad download fails
# the build instead of producing a silently video-less image.
ENV GST_PLUGIN_PATH=/opt/gst-plugins-rs/lib/aarch64-linux-gnu/gstreamer-1.0

RUN curl -fL --retry 3 -o /tmp/gst-plugins-rs.tar.gz \
      "https://github.com/pollen-robotics/reachy-mini-os/releases/download/gst-plugins-rs-gstreamer-1.29.2/gst-plugins-rs-rpi.tar.gz" \
 && echo "6a9174a98a601cba9096cc18855b6c7929f20e1f3667e64464e4319a8a22a177  /tmp/gst-plugins-rs.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/gst-plugins-rs.tar.gz -C / \
 && rm /tmp/gst-plugins-rs.tar.gz \
 && test -f "${GST_PLUGIN_PATH}/libgstrswebrtc.so"

# The daemon talks to the Lite's USB serial (dialout) and the camera/mic (video, audio), so the
# unprivileged runtime user is placed in those groups. This base has no `app` user of its own.
RUN useradd --create-home --uid 1000 --groups dialout,video,audio,plugdev app \
 && chown -R app:app /opt/reachy

# The daemon is configured entirely through environment variables (see reachy-entrypoint.sh).
# Reason: App Lab's brick_compose.yaml cannot express "no extra flags" cleanly -- a bare
# `command: ""` is ambiguous, and a flag list baked into the image could not be varied per app.
COPY reachy-entrypoint.sh /usr/local/bin/reachy-entrypoint.sh
RUN chmod 755 /usr/local/bin/reachy-entrypoint.sh

# Everything after this point runs as the app user.
USER app

EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/reachy-entrypoint.sh"]
