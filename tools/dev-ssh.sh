#!/usr/bin/env bash
# Device helper: dev_ssh "command"
SSH_OPTS=(-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa
  -o KexAlgorithms=+diffie-hellman-group1-sha1 -o Ciphers=+aes128-cbc
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8
  -o PreferredAuthentications=password -o PubkeyAuthentication=no)
DEV=${DEV:-${DEVICE_HOST:-127.0.0.1}}
PORT=${PORT:-22}
# The password, when there is one, comes from device.env; without it the
# connection uses a key from the agent, which is the better arrangement.
if [ -n "$DEVICE_PASSWORD" ]; then
    timeout "${DT:-60}" sshpass -p "$DEVICE_PASSWORD" ssh "${SSH_OPTS[@]}" -p "$PORT" "root@$DEV" "$@"
else
    timeout "${DT:-60}" ssh "${SSH_OPTS[@]}" -p "$PORT" "root@$DEV" "$@"
fi
