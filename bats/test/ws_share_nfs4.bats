# Tests for the MCW RCC NFSv4 ACL backend of ws_share.
# nfs4_getfacl/nfs4_setfacl are replaced by a test double (nfs4_mock/) that
# keeps ACLs in a side store and shows mode bits the way Qumulo does (numeric
# owner/group ACEs), so these run on any local filesystem.

setup() {
    load 'test_helper/common-setup'
    _common_setup
    MOCKBIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$MOCKBIN"
    WS="$BATS_TEST_TMPDIR/scratch/g/pi/me-ws"
    mkdir -p "$WS/sub/deeper"
    echo data > "$WS/data.txt"; chmod 644 "$WS/data.txt"
    echo '#!/bin/sh' > "$WS/run.sh"; chmod 755 "$WS/run.sh"
    echo data > "$WS/sub/deeper/f"; chmod 600 "$WS/sub/deeper/f"
    ln -s data.txt "$WS/link"
    cat > "$MOCKBIN/ws_find" <<EOF
#!/bin/sh
echo "$WS"
EOF
    chmod +x "$MOCKBIN/ws_find"
    ln -s "$PROJECT_ROOT/test/nfs4_mock/nfs4_getfacl" "$MOCKBIN/nfs4_getfacl"
    ln -s "$PROJECT_ROOT/test/nfs4_mock/nfs4_setfacl" "$MOCKBIN/nfs4_setfacl"
    export PATH="$MOCKBIN:$PROJECT_ROOT/../bin:$PATH"
    export NFS4_MOCK_STORE="$BATS_TEST_TMPDIR/acls"
    export WS_SHARE_ACL_BACKEND=nfs4
    export WS_SHARE_NFS4_IDFORMAT=numeric
    U=nobody
    G=$(id -gn nobody)
    UID_U=$(id -u nobody)
    GID_G=$(getent group "$G" | cut -d: -f3)
    OWNER_UID=$(stat -c %u "$WS")
    OWNER_GID=$(stat -c %g "$WS")
    export U G UID_U GID_G OWNER_UID OWNER_GID WS
}

acl() { nfs4_getfacl "$1" | grep -v '^#'; }

@test "nfs4 share read-only writes the mapped ACEs" {
    run ws_share share ws $U
    assert_success
    assert_output --partial "Granting rX access for user $U"
    run acl "$WS"
    assert_line --index 0 "A:fd:$UID_U:rxtncy"
    run acl "$WS/sub/deeper"
    assert_line --index 0 "A:fd:$UID_U:rxtncy"
    run acl "$WS/data.txt"
    assert_line --index 0 "A::$UID_U:rtncy"
    run acl "$WS/run.sh"
    assert_line --index 0 "A::$UID_U:rxtncy"
    run acl "$WS/sub/deeper/f"
    assert_line --index 0 "A::$UID_U:rtncy"
}

@test "nfs4 share readwrite writes the mapped ACEs" {
    run ws_share --readwrite share ws $U
    assert_success
    run acl "$WS"
    assert_line --index 0 "A:fd:$UID_U:rwaDxtTnNcy"
    run acl "$WS/data.txt"
    assert_line --index 0 "A::$UID_U:rwatTnNcy"
    run acl "$WS/run.sh"
    assert_line --index 0 "A::$UID_U:rwaxtTnNcy"
}

@test "nfs4 readwrite share grants what Qumulo gives the owning group for rwx" {
    chmod 2770 "$WS"
    run ws_share --readwrite share ws $U
    run acl "$WS"
    assert_line "A:fd:$UID_U:rwaDxtTnNcy"
    assert_line "A:g:$OWNER_GID:rwaDxtTnNcy"
}

@test "nfs4 name@domain principals" {
    export WS_SHARE_NFS4_IDFORMAT=name WS_SHARE_NFS4_DOMAIN=example.org
    run ws_share share ws $U
    assert_success
    run acl "$WS"
    assert_line --index 0 "A:fd:$U@example.org:rxtncy"
    run ws_share list ws
    assert_line --regexp "^user +$U +read$"
    ws_share unshare ws $U
    run acl "$WS"
    refute_output --partial "$U@"
}

@test "nfs4 share skips symlinks" {
    run ws_share share ws $U
    assert_success
    run grep -c -- "link" "$NFS4_MOCK_STORE/calls.log"
    assert_output "0"
}

@test "nfs4 re-share replaces the earlier grant instead of adding a second one" {
    ws_share share ws $U
    run ws_share --readwrite share ws $U
    assert_success
    run acl "$WS"
    assert_line --index 0 "A:fd:$UID_U:rwaDxtTnNcy"
    refute_output --partial "A:fd:$UID_U:rxtncy"
    run bash -c "nfs4_getfacl '$WS/data.txt' | grep -c ':$UID_U:'"
    assert_output "1"
}

@test "nfs4 new files and directories inherit the grant" {
    ws_share share ws $U
    mkdir "$WS/newdir"; nfs4_setfacl --mock-create "$WS" "$WS/newdir"
    echo x > "$WS/newdir/newfile"; nfs4_setfacl --mock-create "$WS/newdir" "$WS/newdir/newfile"
    run acl "$WS/newdir"
    assert_output --partial "A:fd:$UID_U:rxtncy"
    run acl "$WS/newdir/newfile"
    assert_output --partial "A::$UID_U:rxtncy"
}

@test "nfs4 unshare removes only that user" {
    ws_share share ws $U
    ws_share share ws daemon
    run ws_share unshare ws $U
    assert_success
    assert_output --partial "Removing access for $U"
    run acl "$WS"
    refute_output --partial ":$UID_U:"
    assert_output --partial "A:fd:$(id -u daemon):rxtncy"
    run acl "$WS/sub/deeper/f"
    refute_output --partial ":$UID_U:"
    assert_line "A::$OWNER_UID:rwatTnNcy"
}

@test "nfs4 unshare of a user without grants succeeds and changes nothing" {
    run ws_share unshare ws $U
    assert_success
    run grep -c -- " -e " "$NFS4_MOCK_STORE/calls.log"
    assert_output "0"
}

@test "nfs4 user and group with the same id are kept apart" {
    ws_share --yes sharegroup ws daemon
    ws_share share ws daemon
    run ws_share unsharegroup ws daemon
    assert_success
    run acl "$WS"
    refute_output --partial "A:fdg:$(getent group daemon | cut -d: -f3):"
    assert_output --partial "A:fd:$(id -u daemon):rxtncy"
    run acl "$WS/data.txt"
    assert_output --partial "A::$(id -u daemon):rtncy"
}

@test "nfs4 sharegroup writes group ACEs" {
    run ws_share --readwrite --yes sharegroup ws $G
    assert_success
    run acl "$WS"
    assert_line --index 0 "A:fdg:$GID_G:rwaDxtTnNcy"
    run acl "$WS/data.txt"
    assert_line --index 0 "A:g:$GID_G:rwatTnNcy"
}

@test "nfs4 unshare-all keeps the owner and owning-group ACEs" {
    chmod 2770 "$WS"
    ws_share share ws $U
    ws_share --yes sharegroup ws $G
    run ws_share unshare-all ws
    assert_success
    run acl "$WS"
    assert_output "$(printf 'A::%s:rwaDxtTnNcy\nA:g:%s:rwaDxtTnNcy' $OWNER_UID $OWNER_GID)"
    for f in "$WS/data.txt" "$WS/sub/deeper/f"; do
        run acl "$f"
        refute_output --partial ":$UID_U:"
        refute_output --partial "g:$GID_G:"
        assert_line "A::$OWNER_UID:rwatTnNcy"
    done
}

@test "nfs4 unsharegroup of the owning group keeps the group mode ACE" {
    chmod 2770 "$WS"
    group=$(stat -c %G "$WS")
    ws_share --yes sharegroup ws "$group"
    run ws_share unsharegroup ws "$group"
    assert_success
    run acl "$WS"
    assert_line "A:g:$OWNER_GID:rwaDxtTnNcy"
}

@test "nfs4 list shows shares but not the owner or owning group" {
    ws_share share ws $U
    ws_share --readwrite --yes sharegroup ws $G
    run ws_share list ws
    assert_success
    assert_line --regexp "^user +$U +read$"
    assert_line --regexp "^group +$G +readwrite$"
    assert_equal "${#lines[@]}" 2
}

@test "nfs4 check reports a consistent share" {
    ws_share share ws $U
    run ws_share check ws
    assert_success
    assert_output --partial "user $U: read"
    refute_output --partial "Warning"
}

@test "nfs4 check flags a grant without inheritable ACE" {
    ws_share share ws $U
    store="$NFS4_MOCK_STORE/$(stat -c %i "$WS")"
    sed -i "s/^A:fd:$UID_U:/A::$UID_U:/" "$store"
    run ws_share check ws
    assert_failure
    assert_output --partial "new files will not inherit"
}

@test "nfs4 check on an unshared workspace" {
    run ws_share check ws
    assert_success
    assert_output --partial "not shared"
}

@test "nfs4 auto id format is numeric when the client does not map ids" {
    export WS_SHARE_NFS4_IDFORMAT=auto WS_SHARE_NFS4_DOMAIN=example.org
    if [[ "$(cat /sys/module/nfs/parameters/nfs4_disable_idmapping 2>/dev/null)" == "N" ]]; then
        skip "this host maps NFSv4 ids"
    fi
    run ws_share share ws $U
    run acl "$WS"
    assert_line --index 0 "A:fd:$UID_U:rxtncy"
}

@test "nfs4 auto backend stays posix off nfs4 mounts" {
    export WS_SHARE_ACL_BACKEND=auto
    run ws_share list ws
    assert_file_not_exists "$NFS4_MOCK_STORE/calls.log"
}

@test "nfs4 invalid backend is rejected" {
    export WS_SHARE_ACL_BACKEND=zfs
    run ws_share list ws
    assert_failure
    assert_output --partial "invalid WS_SHARE_ACL_BACKEND"
}

@test "nfs4 unshare only rewrites files that hold the principal" {
    ws_share share ws $U
    # a file created later by someone else, which never got the grant
    echo x > "$WS/sub/other.txt"; chown daemon "$WS/sub/other.txt"
    run ws_share unshare ws $U
    assert_success
    run grep -c -- "-e .*other.txt" "$NFS4_MOCK_STORE/calls.log"
    assert_output "0"
    run grep -c -- "-e .*data.txt" "$NFS4_MOCK_STORE/calls.log"
    assert_output "1"
    run acl "$WS/data.txt"
    refute_output --partial ":$UID_U:"
}

@test "nfs4 unshare handles file names with newlines" {
    f="$WS/sub/bad"$'\n'"name"
    echo x > "$f"
    ws_share share ws $U
    run acl "$f"
    assert_line "A::$UID_U:rtncy"
    run ws_share unshare ws $U
    assert_success
    run acl "$f"
    refute_output --partial ":$UID_U:"
}
