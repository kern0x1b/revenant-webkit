#!/usr/bin/env bash
DEVICE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[ -f "$DEVICE_ROOT/device.env" ] && . "$DEVICE_ROOT/device.env"

DEVICE_HOST=${DEVICE_HOST:-127.0.0.1}
DEVICE_PORT=${DEVICE_PORT:-2222}
DEVICE_PASSWORD=${DEVICE_PASSWORD:-${DEVICE_PASS:-}}

DEVICE_SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
                 -o LogLevel=ERROR -o ConnectTimeout=8
                 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa
                 -o KexAlgorithms=+diffie-hellman-group1-sha1 -o Ciphers=+aes128-cbc
                 -o ControlMaster=auto -o ControlPersist=60
                 -o ControlPath=/tmp/rev-ssh-%h-%p)

device_tunnel() {
    [ "$DEVICE_HOST" = "127.0.0.1" ] || return 0
    nc -z "$DEVICE_HOST" "$DEVICE_PORT" 2>/dev/null && return 0
    command -v iproxy >/dev/null 2>&1 || return 0
    local udid=${DEVICE_UDID:-}
    if [ -z "$udid" ] && [ "$(idevice_id -l 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
        udid=$(idevice_id -l 2>/dev/null | head -1)
    fi
    [ -n "$udid" ] || { echo "tunnel on $DEVICE_PORT is down and DEVICE_UDID is not set" >&2; return 0; }
    pkill -f "iproxy $DEVICE_PORT " 2>/dev/null || true
    (iproxy "$DEVICE_PORT" 22 -u "$udid" >/tmp/iproxy-$DEVICE_PORT.log 2>&1 &)
    sleep 3
}

device_run() {
    local timeout=$1; shift
    device_tunnel
    if [ -n "$DEVICE_PASSWORD" ]; then
        timeout "$timeout" sshpass -p "$DEVICE_PASSWORD" \
            ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST" "$@"
    else
        timeout "$timeout" ssh "${DEVICE_SSH_OPTS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST" "$@"
    fi
}

device_fetch() {
    device_tunnel
    if [ -n "$DEVICE_PASSWORD" ]; then
        sshpass -p "$DEVICE_PASSWORD" \
            scp "${DEVICE_SSH_OPTS[@]}" -P "$DEVICE_PORT" "root@$DEVICE_HOST:$1" "$2"
    else
        scp "${DEVICE_SSH_OPTS[@]}" -P "$DEVICE_PORT" "root@$DEVICE_HOST:$1" "$2"
    fi
}

device_copy() {
    device_tunnel
    if [ -n "$DEVICE_PASSWORD" ]; then
        sshpass -p "$DEVICE_PASSWORD" \
            scp "${DEVICE_SSH_OPTS[@]}" -P "$DEVICE_PORT" "$1" "root@$DEVICE_HOST:$2"
    else
        scp "${DEVICE_SSH_OPTS[@]}" -P "$DEVICE_PORT" "$1" "root@$DEVICE_HOST:$2"
    fi
}
