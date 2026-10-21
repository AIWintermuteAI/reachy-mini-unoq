#!/bin/sh
# Entrypoint for the Reachy Mini daemon container.
#
# Everything is env-driven so App Lab's brick_compose.yaml never has to assemble an argv list
# (compose `command:` cannot express "no flags" cleanly, and a bare `command: ""` is ambiguous).
#
#   REACHY_SERIAL_PORT  USB serial device for the motor bus   (Lite: VID:PID 1a86:55d3)
#   REACHY_SIM          "mockup" -> --mockup-sim, "mujoco" -> --sim   (run with no robot attached)
#   REACHY_NO_MEDIA     "1" -> --no-media                     (skip camera/mic, saves CPU)
#   REACHY_WAKE         "0" -> --no-wake-up-on-start          (connect without moving the robot)
#   REACHY_HOST         bind address                          (default 0.0.0.0)
#   REACHY_PORT         bind port                             (default 8000)
#   REACHY_EXTRA_ARGS   any additional raw flags
set -eu

set -- -m reachy_mini.daemon.app.main
set -- "$@" --fastapi-host "${REACHY_HOST:-0.0.0.0}" \
            --fastapi-port "${REACHY_PORT:-8000}"

if [ -n "${REACHY_SERIAL_PORT:-}" ]; then
    set -- "$@" --serialport "${REACHY_SERIAL_PORT}"
fi

case "${REACHY_SIM:-}" in
    mockup|1|true)  set -- "$@" --mockup-sim ;;
    mujoco|sim)     set -- "$@" --sim ;;
    ""|0)            ;;   # 0 = App Lab normalizes empty-string variables to 0
    *)              echo "entrypoint: warning: unrecognized REACHY_SIM=${REACHY_SIM}, assuming real hardware" >&2 ;;
esac

if [ "${REACHY_NO_MEDIA:-0}" = "1" ]; then
    set -- "$@" --no-media
fi

# The daemon wakes the robot by default, which physically moves the head and antennas.
# REACHY_WAKE=0 makes the first connection non-moving, so a bring-up can be verified
# (motors, camera, audio all detected) without the robot doing anything.
if [ "${REACHY_WAKE:-1}" = "0" ]; then
    set -- "$@" --no-wake-up-on-start
fi

# Deliberately word-split: REACHY_EXTRA_ARGS is documented as multiple raw flags.
# shellcheck disable=SC2086
if [ -n "${REACHY_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2086
    set -- "$@" ${REACHY_EXTRA_ARGS}
fi

echo "entrypoint: python -u $*" >&2
exec python -u "$@"
