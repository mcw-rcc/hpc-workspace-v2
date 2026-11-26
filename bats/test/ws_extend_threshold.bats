# MCW: extensionthreshold - a workspace can only be extended once a configured
# percentage of its current period (creation or last extension until expiration)
# has elapsed. The DB entries are rewritten with sed to simulate elapsed time.

setup() {
    load 'test_helper/common-setup'
    _common_setup
    export PATH=$PATH:$PWD/bin
    conf=/tmp/ws_threshold_$$.conf
    cat > "$conf" <<EOF
admins: [root]
adminmail: [root@a.com]
clustername: bats
dbgid: 2
dbuid: 2
duration: 60
maxextensions: 2
extensionthreshold: 75
smtphost: localhost
mail_from: root@localhost
default: ws2
workspaces:
  ws2:
    database: /tmp/ws/ws2-db
    deleted: .removed
    keeptime: 7
    spaces: [/tmp/ws/ws2/1, /tmp/ws/ws2/2]
EOF
    day=$((24*3600))
}

teardown() {
    rm -f "$conf"
}

dbfile() { echo "/tmp/ws/ws2-db/${USER}-$1"; }

# set creation and expiration of workspace $1 to now-$2 days and now+$3 days
backdate() {
    local now; now=$(date +%s)
    sed -i -e "s/^creation: .*/creation: $((now - $2*day))/" \
           -e "s/^expiration: .*/expiration: $((now + $3*day))/" "$(dbfile "$1")"
}

@test "ws_extend_threshold: extension refused before 75% of the period" {
    rm -f "$(dbfile THR_EARLY)"
    ws_allocate --config "$conf" THR_EARLY 10 2>/dev/null
    run ws_allocate --config "$conf" -x THR_EARLY 20
    assert_failure
    assert_output --partial "can not be extended yet, 75% of its current duration"
    assert_output --partial "you can extend it on or after"
    assert_output --partial "(in 8 days)"
    assert_output --partial "no extension was used"
    # nothing changed in the DB
    run grep "^extensions: 2" "$(dbfile THR_EARLY)"
    assert_success
    run grep "^extended:" "$(dbfile THR_EARLY)"
    assert_failure
    rm -f "$(dbfile THR_EARLY)"
}

@test "ws_extend_threshold: ws_extend wrapper is refused too" {
    rm -f "$(dbfile THR_WRAP)"
    ws_allocate --config "$conf" THR_WRAP 10 2>/dev/null
    # ws_extend has no --config option: put a shim first in PATH that adds it
    shim=/tmp/ws_threshold_shim_$$
    mkdir -p "$shim"
    printf '#!/bin/sh\nexec %s --config %s "$@"\n' "$(command -v ws_allocate)" "$conf" > "$shim/ws_allocate"
    chmod +x "$shim/ws_allocate"
    PATH="$shim:$PATH" run "$PWD/bin/ws_extend" THR_WRAP 20
    assert_failure
    assert_output --partial "can not be extended yet"
    rm -rf "$shim" "$(dbfile THR_WRAP)"
}

@test "ws_extend_threshold: extension allowed after 75% and resets the period" {
    rm -f "$(dbfile THR_LATE)"
    ws_allocate --config "$conf" THR_LATE 10 2>/dev/null
    # 8 of 10 days elapsed = 80%
    backdate THR_LATE 8 2
    run ws_allocate --config "$conf" -x THR_LATE 20
    assert_success
    assert_output --partial "extending workspace"
    assert_output --partial "remaining extensions  : 1"
    run grep "^extended:" "$(dbfile THR_LATE)"
    assert_success
    # the new period starts now, so an immediate second extension is refused
    run ws_allocate --config "$conf" -x THR_LATE 30
    assert_failure
    assert_output --partial "can not be extended yet"
    assert_output --partial "(in 15 days)"
    run grep "^extensions: 1" "$(dbfile THR_LATE)"
    assert_success
    rm -f "$(dbfile THR_LATE)"
}

@test "ws_extend_threshold: just below 75% is refused" {
    rm -f "$(dbfile THR_EDGE)"
    ws_allocate --config "$conf" THR_EDGE 10 2>/dev/null
    # 7 of 10 days elapsed = 70%
    backdate THR_EDGE 7 3
    run ws_allocate --config "$conf" -x THR_EDGE 10
    assert_failure
    assert_output --partial "(in 1 day)"
    rm -f "$(dbfile THR_EDGE)"
}

@test "ws_extend_threshold: comment, mail and shortening are not blocked" {
    rm -f "$(dbfile THR_META)"
    ws_allocate --config "$conf" THR_META 10 2>/dev/null
    run ws_allocate --config "$conf" -x -c "a comment" THR_META
    assert_success
    assert_output --partial "remaining extensions  : 2"
    run ws_allocate --config "$conf" -x -m "someone@example.com" THR_META
    assert_success
    assert_output --partial "remaining extensions  : 2"
    # shortening does not consume an extension, so it is not subject to the rule
    run ws_allocate --config "$conf" -x THR_META 3
    assert_success
    assert_output --partial "remaining extensions  : 2"
    rm -f "$(dbfile THR_META)"
}

@test "ws_extend_threshold: no extensions left reports that, not a date" {
    rm -f "$(dbfile THR_NONE)"
    ws_allocate --config "$conf" THR_NONE 10 2>/dev/null
    sed -i "s/^extensions: .*/extensions: 0/" "$(dbfile THR_NONE)"
    run ws_allocate --config "$conf" -x THR_NONE 20
    assert_failure
    assert_output --partial "no more extensions!"
    refute_output --partial "can not be extended yet"
    rm -f "$(dbfile THR_NONE)"
}

@test "ws_extend_threshold: ws_validate_config rejects threshold above 100" {
    sed -i "s/^extensionthreshold: 75/extensionthreshold: 101/" "$conf"
    run ws_validate_config --config "$conf"
    assert_output --partial "extensionthreshold must be between 0 and 100"
}

# MCW: extensionwindow - in the last N days before expiration an extension is always
# allowed, so short workspaces are not stuck until 75% of a tiny period has passed.
window_conf() {
    sed 's/^extensionthreshold: 75$/extensionthreshold: 75\nextensionwindow: 7/' "$conf" > "$conf.win"
}

@test "ws_extend_threshold: extensionwindow allows a short workspace at once" {
    window_conf
    rm -f "$(dbfile THR_WIN)"
    ws_allocate --config "$conf.win" THR_WIN 4 2>/dev/null
    run ws_allocate --config "$conf.win" -x THR_WIN 20
    assert_success
    run grep "^extensions: 1" "$(dbfile THR_WIN)"
    assert_success
    rm -f "$(dbfile THR_WIN)" "$conf.win"
}

@test "ws_extend_threshold: extensionwindow does not change a long workspace" {
    window_conf
    rm -f "$(dbfile THR_WINLONG)"
    ws_allocate --config "$conf.win" THR_WINLONG 30 2>/dev/null
    backdate THR_WINLONG 10 20
    run ws_allocate --config "$conf.win" -x THR_WINLONG 30
    assert_failure
    assert_output --partial "or less than 7 days must remain"
    assert_output --partial "no extension was used"
    rm -f "$(dbfile THR_WINLONG)" "$conf.win"
}
