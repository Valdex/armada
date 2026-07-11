#!/usr/bin/env bash

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
COLLECTOR="$SCRIPT_DIR/rpmini-v2-support-bundle.sh"

bash -n "$COLLECTOR"
bash "$COLLECTOR" --self-test

if grep -En \
    '(/etc/(shadow|gshadow)|NetworkManager/system-connections|/proc/[^ ]*/environ|[[:space:]]nmcli[[:space:]]|[[:space:]]ip[[:space:]]+(addr|address)|[[:space:]]iw[[:space:]]+dev)' \
    "$COLLECTOR" >/dev/null; then
    printf 'collector contains a forbidden secret-bearing source or command\n' >&2
    exit 1
fi

if grep -En '[[:space:]]findmnt[^\n]*SOURCE' "$COLLECTOR" >/dev/null; then
    printf 'collector must not ask findmnt for an identifier-bearing source\n' >&2
    exit 1
fi

for required in \
    '[sysfs-block-fallback]' \
    '[known-filesystems-proc-fallback]' \
    '/|/flash|/storage|/boot|/boot/efi' \
    'access=rw'; do
    if ! grep -F -- "$required" "$COLLECTOR" >/dev/null; then
        printf 'collector is missing storage fallback marker: %s\n' "$required" >&2
        exit 1
    fi
done

printf 'support-bundle static checks: PASS\n'
