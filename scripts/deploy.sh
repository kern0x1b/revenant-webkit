#!/usr/bin/env bash
# Put the built app on the device and, given a URL, run the headless harness
# there and print what it measured.
#
#   ./deploy.sh                      install only
#   ./deploy.sh https://example.com  install, then load that page and report
#
# The device answers on Wi-Fi or through a USB tunnel; whichever is up is used.
set -u
P=$(cd "$(dirname "$0")/.." && pwd)
APP="$P/dist/LegacyBrowser.app"
PASS=${DEVICE_PASSWORD:-}
# Read the arguments before the device search below, which uses `set --` and so
# overwrites them.
URL="${1:-}"
SECONDS_TO_WAIT="${2:-25}"
SSH_OPTS="-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o KexAlgorithms=+diffie-hellman-group1-sha1 -o Ciphers=+aes128-cbc
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=8 -o PreferredAuthentications=password -o PubkeyAuthentication=no"

# Find the device. Wi-Fi first: the USB tunnel is often left running with
# nothing behind it, so a listening port is not evidence a device is there.
DEV=""
for target in "${DEVICE_HOST:-127.0.0.1} ${DEVICE_PORT:-22}" "127.0.0.1 2222" "127.0.0.1 2223"; do
    set -- $target
    if timeout 12 sshpass -p "$PASS" ssh $SSH_OPTS -p "$2" "root@$1" true 2>/dev/null; then
        DEV="$1"; PORT="$2"; break
    fi
done
[ -n "$DEV" ] || { echo "no device: neither Wi-Fi nor the USB tunnel answered"; exit 1; }
echo "device: $DEV:$PORT"

dev_ssh() { timeout "${1:-60}" sshpass -p "$PASS" ssh $SSH_OPTS -p "$PORT" "root@$DEV" "${@:2}"; }

# One tar over one connection: the bundle is a few thousand files and a copy
# per file spends the whole time in round trips.
echo "copying $(du -sh "$APP" | cut -f1)"
tar -C "$(dirname "$APP")" -cf - "$(basename "$APP")" \
  | sshpass -p "$PASS" ssh $SSH_OPTS -p "$PORT" "root@$DEV" \
    'rm -rf /Applications/LegacyBrowser.app && tar -C /Applications -xf - && chown -R root:wheel /Applications/LegacyBrowser.app' \
  || { echo "copy failed"; exit 1; }
# LaunchServices caches the bundle's Info.plist. Without this a changed plist -
# a new URL scheme, a changed status bar setting - leaves the old record in
# place and `uiopen` either launches something stale or nothing at all. uicache
# writes into mobile's own container, so it has to run as mobile.
dev_ssh 120 'su mobile -c uicache 2>&1 | grep -v "^$" ; true'
echo "installed"

[ -n "$URL" ] || exit 0

echo "loading $URL"
dev_ssh 300 "/Applications/LegacyBrowser.app/headless '$URL' $SECONDS_TO_WAIT 2>&1; echo exit=\$?"
