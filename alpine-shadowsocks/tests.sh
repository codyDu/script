#!/bin/sh
set -eu
cd "$(dirname "$0")"
# Load only definitions, never privileged installer actions.
defs=$(mktemp)
trap 'rm -f "$defs"; rm -rf "$tmp"' EXIT
sed '/^tmp= tty_state= backup=/,$d' install.sh > "$defs"
. "$defs"
tmp=$(mktemp -d)
pass() { "$@" || { printf 'FAILED: %s\n' "$1"; exit 1; }; }
reject() { if "$@"; then printf 'unexpected acceptance: %s\n' "$1"; exit 1; fi; }
for p in 1 9999 65535; do pass valid_port "$p"; done
for p in '' 0 01 65536 -1 abc 9999999999999999999999 '1;id'; do reject valid_port "$p"; done
pass validate_key aes-128-gcm ''
pass validate_key chacha20-ietf-poly1305 x
pass validate_key aes-256-gcm 'quotes" and $shell; characters'
for method in 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305; do
    count=$(key_bytes "$method")
    good=$(dd if=/dev/zero bs=1 count="$count" 2>/dev/null | base64 | tr -d '\n')
    pass validate_key "$method" "$good"
    for bad_count in 0 15 17 31 33; do
        bad=$(dd if=/dev/zero bs=1 count="$bad_count" 2>/dev/null | base64 | tr -d '\n')
        reject validate_key "$method" "$bad"
    done
    reject validate_key "$method" "$good:$good"
    reject validate_key "$method" "$good="
    reject validate_key "$method" '%%%'
done
pass safe_option example.com
pass safe_option /ws-path
reject safe_option 'example.com;tls'
reject safe_option '/tmp/key with spaces'
reject key_bytes none
printf '%s\n' 'Input validation tests passed'
# Exercise failure rollback against temporary files and mocked OpenRC.
fixture=$tmp
mkdir "$fixture/backup"
mkdir "$fixture/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$TEST_CALLS"\n' > "$fixture/bin/rc-service"
cp "$fixture/bin/rc-service" "$fixture/bin/rc-update"
chmod 700 "$fixture/bin/rc-service" "$fixture/bin/rc-update"
TEST_CALLS=$fixture/calls
export TEST_CALLS
PATH=$fixture/bin:$PATH
export PATH
printf old-config > "$fixture/backup/config.json"
printf old-init > "$fixture/backup/init"
printf new-config > "$fixture/config"
printf new-init > "$fixture/service"
(
    config=$fixture/config service=$fixture/service backup=$fixture/backup
    tmp= tty_state= locked=no transaction=yes running=yes enabled=no
    cleanup
) 2>/dev/null
cmp -s "$fixture/config" "$fixture/backup/config.json"
cmp -s "$fixture/service" "$fixture/backup/init"
expected=$(printf 'ss-rust stop\ndel ss-rust default\nss-rust start')
[ "$(cat "$fixture/calls")" = "$expected" ]
rm "$fixture/backup/config.json" "$fixture/backup/init"
(
    config=$fixture/config service=$fixture/service backup=$fixture/backup
    tmp= tty_state= locked=no transaction=yes running=no enabled=no
    cleanup
) 2>/dev/null
[ ! -e "$fixture/config" ] && [ ! -e "$fixture/service" ]
printf '%s\n' 'Existing-service and first-install rollback tests passed'
