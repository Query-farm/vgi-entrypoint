#!/usr/bin/env bash
#
# Linux integration tests for vgi-entrypoint capability dropping on fly.io.
#
# Tests cap-drop, no_new_privs, and full exec — things that require Linux.
# Image config parsing is tested locally by test_image_config.py.
#
# Usage: ./test-fly.sh
#
set -euo pipefail

APP_NAME="vgi-entrypoint-test"
REGION="ord"
BINARY="zig-out/bin/vgi-entrypoint"
MACHINE_ID=""

# ── Helpers ──────────────────────────────────────────────────────────────

pass=0
fail=0

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    if printf '%s\n' "$haystack" | grep -qF "$needle"; then
        green "  PASS: $label"
        pass=$((pass + 1))
    else
        red "  FAIL: $label (output missing: $needle)"
        red "  OUTPUT: $haystack"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="$3"
    if printf '%s\n' "$haystack" | grep -qF "$needle"; then
        red "  FAIL: $label (output unexpectedly contains: $needle)"
        fail=$((fail + 1))
    else
        green "  PASS: $label"
        pass=$((pass + 1))
    fi
}

exec_on_machine() {
    fly machine exec "$MACHINE_ID" "$1" --app "$APP_NAME" --timeout "${2:-30}" 2>&1 || true
}

write_file_on_machine() {
    local path="$1" content="$2"
    local encoded
    encoded=$(printf '%s' "$content" | base64)
    exec_on_machine "sh -c echo\ ${encoded}\ |\ base64\ -d\ >\ ${path}"
}

# ── Cleanup ──────────────────────────────────────────────────────────────

cleanup() {
    bold "Cleaning up..."
    if [ -n "$MACHINE_ID" ]; then
        fly machines destroy "$MACHINE_ID" --app "$APP_NAME" --force 2>/dev/null || true
    fi
    fly apps destroy "$APP_NAME" --yes 2>/dev/null || true
    echo "Done."
}
trap cleanup EXIT

# ── Build ────────────────────────────────────────────────────────────────

bold "Building vgi-entrypoint..."
zig build -Darch=x86_64
ls -la "$BINARY"
echo

# ── Provision ────────────────────────────────────────────────────────────

bold "Creating fly.io app and machine..."
fly apps create "$APP_NAME" --org personal

FLY_API_TOKEN=$(fly auth token)
MACHINE_ID=$(curl -s -X POST "https://api.machines.dev/v1/apps/${APP_NAME}/machines" \
    -H "Authorization: Bearer $FLY_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
        \"name\": \"test-vm\",
        \"region\": \"${REGION}\",
        \"config\": {
            \"image\": \"ubuntu:24.04\",
            \"init\": {
                \"entrypoint\": [\"/bin/sleep\"],
                \"cmd\": [\"infinity\"]
            },
            \"guest\": {
                \"cpu_kind\": \"shared\",
                \"cpus\": 1,
                \"memory_mb\": 256
            }
        }
    }" | jq -r '.id')

echo "Machine ID: $MACHINE_ID"
echo "Waiting for machine to start..."
sleep 5

state=$(fly machines list --app "$APP_NAME" --json | jq -r '.[0].state')
if [ "$state" != "started" ]; then
    red "Machine not started (state: $state), aborting."
    exit 1
fi
echo

# ── Upload binary ────────────────────────────────────────────────────────

bold "Uploading binary..."
fly ssh sftp shell --app "$APP_NAME" --machine "$MACHINE_ID" <<SFTP
put $BINARY /usr/local/bin/vgi-entrypoint
SFTP
exec_on_machine "chmod 755 /usr/local/bin/vgi-entrypoint" > /dev/null
echo

# ── Tests ────────────────────────────────────────────────────────────────

bold "Running tests..."
echo

# -- Test 1: Missing VGI_ENTRYPOINT_DROP_CAPS ─────────────────────────────────────
bold "[Test 1] Missing VGI_ENTRYPOINT_DROP_CAPS"
output=$(exec_on_machine "/usr/local/bin/vgi-entrypoint")
assert_contains "$output" "required environment variable VGI_ENTRYPOINT_DROP_CAPS is not set" \
    "error message present"
echo

# -- Test 2: Empty VGI_ENTRYPOINT_DROP_CAPS ───────────────────────────────────────
bold "[Test 2] Empty VGI_ENTRYPOINT_DROP_CAPS"
output=$(exec_on_machine "sh -c VGI_ENTRYPOINT_DROP_CAPS=\ /usr/local/bin/vgi-entrypoint")
assert_contains "$output" "VGI_ENTRYPOINT_DROP_CAPS is empty" \
    "error message present"
echo

# -- Test 3: Unknown capability name ───────────────────────────────────
bold "[Test 3] Unknown capability name"
output=$(exec_on_machine "sh -c VGI_ENTRYPOINT_DROP_CAPS=cap_bogus\ /usr/local/bin/vgi-entrypoint")
assert_contains "$output" "unknown capability in VGI_ENTRYPOINT_DROP_CAPS" \
    "error message present"
echo

# -- Test 4: Cap drop — verify /proc/self/status ──────────────────────
bold "[Test 4] Cap drop removes cap_net_admin from all sets"
config='{"config":{"Entrypoint":["grep","Cap","/proc/self/status"]}}'
write_file_on_machine "/vgi-image-config" "$config" > /dev/null

output=$(exec_on_machine \
    "sh -c VGI_ENTRYPOINT_DROP_CAPS=cap_net_admin\ VGI_ENTRYPOINT_DUMP_CAPS=true\ /usr/local/bin/vgi-entrypoint")

# Bit 12 (0x1000) must be cleared. Full caps = ffffffffff, without bit 12 = ffffffefff.
assert_contains "$output" "CapBnd:	000001ffffffefff" \
    "bounding set has bit 12 cleared"
assert_contains "$output" "CapPrm:	000001ffffffefff" \
    "permitted set has bit 12 cleared"
assert_contains "$output" "CapEff:	000001ffffffefff" \
    "effective set has bit 12 cleared"

after_effective=$(printf '%s\n' "$output" | grep -A1 "after drop" | grep "Effective" || echo "")
assert_contains "$after_effective" "Effective" \
    "after-drop effective line was found"
assert_not_contains "$after_effective" "cap_net_admin" \
    "after-drop effective does not contain cap_net_admin"
echo

# -- Test 5: Multiple caps dropped (reuses config from test 4) ────────
bold "[Test 5] Drop multiple caps (cap_net_admin,cap_net_raw)"
output=$(exec_on_machine \
    "sh -c VGI_ENTRYPOINT_DROP_CAPS=cap_net_admin,cap_net_raw\ /usr/local/bin/vgi-entrypoint")

# Bits 12+13 (0x3000) cleared: ffffffffff -> ffffffcfff
assert_contains "$output" "CapBnd:	000001ffffffcfff" \
    "bounding set has bits 12+13 cleared"
echo

# -- Test 6: no_new_privs default ─────────────────────────────────────
bold "[Test 6] no_new_privs is set by default"
config='{"config":{"Entrypoint":["cat","/proc/self/status"]}}'
write_file_on_machine "/vgi-image-config" "$config" > /dev/null

output=$(exec_on_machine \
    "sh -c VGI_ENTRYPOINT_DROP_CAPS=cap_net_admin\ /usr/local/bin/vgi-entrypoint")

assert_contains "$output" "NoNewPrivs:	1" \
    "NoNewPrivs is 1 in exec'd process"
echo

# -- Test 7: Full exec with real command ──────────────────────────────
bold "[Test 7] Full exec with echo command"
config='{"config":{"Entrypoint":["echo","EXEC_WORKS"]}}'
write_file_on_machine "/vgi-image-config" "$config" > /dev/null

output=$(exec_on_machine \
    "sh -c VGI_ENTRYPOINT_DROP_CAPS=cap_net_admin\ /usr/local/bin/vgi-entrypoint")

assert_contains "$output" "EXEC_WORKS" \
    "exec'd process produced expected output"
echo

# ── Summary ──────────────────────────────────────────────────────────────

echo
bold "════════════════════════════════════"
if [ "$fail" -eq 0 ]; then
    green "All $pass tests passed."
else
    red "$fail test(s) failed, $pass passed."
fi
bold "════════════════════════════════════"

exit "$fail"
