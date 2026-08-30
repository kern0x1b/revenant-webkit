#!/usr/bin/env bash
# Restore the system WebKitLegacy/WebCore/JavaScriptCore frameworks saved by
# install-system-webkit.sh. Run this if any app misbehaves after installing.
set -euo pipefail
DEVICE=${DEVICE:?set DEVICE=root@host}
PORT=${PORT:-22}
PASS=${DEVICE_PASSWORD:-}
SSH_OPTS="-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o KexAlgorithms=+diffie-hellman-group1-sha1 -o Ciphers=+aes128-cbc -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
BACKUP=/var/backups/revenant-system-frameworks
LIBCXX_DIR=/usr/lib/revenant

dev_ssh() { sshpass -p "$PASS" ssh $SSH_OPTS -p "$PORT" "$DEVICE" "$@"; }

SYSTEM_PATHS=(
    /System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore
    /System/Library/PrivateFrameworks/WebCore.framework/WebCore
    /System/Library/PrivateFrameworks/WebKitLegacy.framework/WebKitLegacy
)

dev_ssh "test -d $BACKUP" || { echo "no backup at $BACKUP on device - nothing to restore" >&2; exit 1; }

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

for sys_path in "${SYSTEM_PATHS[@]}"; do
    name=$(basename "$sys_path")
    if ! dev_ssh "test -f '$BACKUP/$name'"; then
        echo "  no backup for $name, left as-is"
        continue
    fi
    echo "restoring $sys_path"
    sshpass -p "$PASS" scp $SSH_OPTS -P "$PORT" "$DEVICE:$BACKUP/$name" "$SCRATCH/$name"
    ldid -S "$SCRATCH/$name"
    if sshpass -p "$PASS" scp $SSH_OPTS -P "$PORT" "$SCRATCH/$name" "$DEVICE:$sys_path.new" \
        && dev_ssh "chown root:wheel '$sys_path.new' && chmod 755 '$sys_path.new' && mv '$sys_path.new' '$sys_path'"; then
        :
    else
        echo "  RESTORE FAILED for $name - fix manually" >&2
    fi
done

echo "removing $LIBCXX_DIR (install-system-webkit.sh's own addition, nothing to restore it to)"
dev_ssh "rm -rf '$LIBCXX_DIR'"

echo "respringing"
dev_ssh "killall SpringBoard"
echo "restored."
