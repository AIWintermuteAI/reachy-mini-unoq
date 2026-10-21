"""App entry point: wait for the Reachy daemon, then keep the app alive.

The daemon runs in its own container (see bricks/reachy_daemon/brick_compose.yaml). This process
only talks to it over HTTP, so it stays tiny and cannot crash the robot controller.
"""

import time

from arduino.app_utils import App
from reachy_daemon import status, wait_ready

POLL_INTERVAL_S = 10


def loop():
    if not wait_ready(timeout_s=180):
        print("[reachy] daemon did not become ready within 180s -- check `docker logs`")
        return

    try:
        state = status()
        print(f"[reachy] daemon ready: {state}")
    except Exception as exc:  # noqa: BLE001 - purely informational
        print(f"[reachy] status call failed: {exc}")
        return

    time.sleep(POLL_INTERVAL_S)


print("[reachy] starting; waiting for the Reachy Mini daemon container...")
App.run(user_loop=loop)
