"""Python-side interface to the Reachy Mini daemon brick.

IMPORTANT: this module runs in the *app* container, not in the daemon's container. App Lab
deliberately does not share a filesystem or process namespace between them, so it reaches the
daemon over HTTP. Prefer the Compose service name; host networking removes that alias, so fall
back to the Docker bridge gateway in that case.

The daemon itself is the upstream `reachy-mini` FastAPI app; anything not wrapped here can be
called with `request()` directly (the full API is at `BASE_URL/docs`).
"""

from __future__ import annotations

import os
import socket
import struct
import time

import requests

DAEMON_HOST = os.getenv("REACHY_DAEMON_HOST", "reachy-mini-daemon")
DAEMON_PORT = os.getenv("REACHY_DAEMON_PORT", "8000")
BASE_URL = f"http://{DAEMON_HOST}:{DAEMON_PORT}"

DEFAULT_TIMEOUT = 10


def _docker_host_gateway(route_path: str = "/proc/net/route") -> str | None:
    """Return the IPv4 default gateway, which is the Docker host from a bridge container."""
    try:
        with open(route_path, encoding="ascii") as routes:
            next(routes)
            for line in routes:
                fields = line.split()
                if len(fields) >= 4 and fields[1] == "00000000":
                    if int(fields[3], 16) & 0x2:
                        packed = struct.pack("<L", int(fields[2], 16))
                        return socket.inet_ntoa(packed)
    except (OSError, ValueError, struct.error):
        pass
    return None


def _base_urls() -> list[str]:
    urls = [BASE_URL]
    if os.getenv("REACHY_DAEMON_HOST"):
        return urls
    gateway = _docker_host_gateway()
    gateway_url = f"http://{gateway}:{DAEMON_PORT}" if gateway else None
    if gateway_url and gateway_url not in urls:
        urls.append(gateway_url)
    return urls


def request(method: str, path: str, *, timeout: int = DEFAULT_TIMEOUT, **kwargs):
    """Call the daemon API. `path` is relative to the host, e.g. "/api/daemon/status"."""
    connection_error = None
    for base_url in _base_urls():
        try:
            response = requests.request(
                method, f"{base_url}{path}", timeout=timeout, **kwargs
            )
            break
        except requests.ConnectionError as exc:
            connection_error = exc
    else:
        raise connection_error

    response.raise_for_status()
    if response.headers.get("content-type", "").startswith("application/json"):
        return response.json()
    return response.text


def status(timeout: int = DEFAULT_TIMEOUT) -> dict:
    """Current daemon state (running, awake, backend, robot name...)."""
    return request("GET", "/api/daemon/status", timeout=timeout)


def is_ready(timeout: int = 3) -> bool:
    """True once the daemon answers; False while it is still starting."""
    try:
        status(timeout=timeout)
        return True
    except (requests.RequestException, ValueError):
        return False


def wait_ready(timeout_s: int = 180, poll_s: float = 2.0) -> bool:
    """Block until the daemon answers. The first start loads models, so allow a while."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if is_ready():
            return True
        time.sleep(poll_s)
    return False


def wake_up() -> dict:
    """Wake the robot (motors enabled, head lifted)."""
    return request("POST", "/api/daemon/start")


def goto_sleep() -> dict:
    """Put the robot to sleep (torque released, head lowered)."""
    return request("POST", "/api/daemon/stop")


def stop(goto_sleep_flag: bool = True) -> dict:
    """Stop the daemon process inside the container."""
    return request(
        "POST", "/api/daemon/stop", params={"goto_sleep": str(goto_sleep_flag).lower()}
    )
