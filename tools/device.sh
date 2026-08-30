#!/usr/bin/env bash
# Reaching the phone, in one place.
#
# Sourced by the scripts that talk to the device. The address, the port and the
# password are configuration, not source: they live in device.env, which is not
# in the repository. An SSH key is used when no password is set, which is the
# arrangement worth having - a password on the command line is visible to every
# process on the machine.
DEVICE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[ -f "$DEVICE_ROOT/device.env" ] && . "$DEVICE_ROOT/device.env"

DEVICE_HOST=${DEVICE_HOST:-127.0.0.1}
DEVICE_PORT=${DEVICE_PORT:-2222}

DEVICE_SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
                 -o LogLevel=ERROR -o ConnectTimeout=8)

# Runs a command on the device. First argument is a timeout in seconds.
device_run() {
    local timeout=$1; shift
    if [ -n "$DEVICE_PASSWORD" ]; then
        timeout "$timeout" sshpass -p "$DEVICE_PASSWORD" \
            ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST" "$@"
    else
        timeout "$timeout" ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST" "$@"
    fi
}

# Copies a local file to the device.
device_copy() {
    if [ -n "$DEVICE_PASSWORD" ]; then
        sshpass -p "$DEVICE_PASSWORD" \
            scp "${DEVICE_SSH_OPTS[@]}" -P "$DEVICE_PORT" "$1" "root@$DEVICE_HOST:$2"
    else
        scp "${DEVICE_SSH_OPTS[@]}" -P "$DEVICE_PORT" "$1" "root@$DEVICE_HOST:$2"
    fi
}
