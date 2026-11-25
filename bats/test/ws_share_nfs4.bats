# Tests for the MCW RCC NFSv4 ACL backend of ws_share.
# nfs4_getfacl/nfs4_setfacl are replaced by a test double (nfs4_mock/) that
# keeps ACLs in a side store, so these run on any local filesystem.

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
    export WS_SHARE_NFS4_DOMAIN=example.org
    export WS_SHARE_NFS4_IDFORMAT=auto
    U=nobody
    G=$(id -gn nobody)
    export U G WS
}

acl() { nfs4_getfacl "$1" | grep -v '^#'; }

@test "nfs4 share read-only writes the mapped ACEs" {
    run ws_share share ws $U
    assert_success
    assert_output --partial "Granting rX access for user $U"
    run acl "$WS"
    assert_line --index 0 "A:d:$U@example.org:rxtcy"
    assert_line --index 1 "A:fi:$U@example.org:rtcy"
    run acl "$WS/sub/deeper"
    assert_line --index 0 "A:d:$U@example.org:rxtcy"
    run acl "$WS/data.txt"
    assert_line --index 0 "A::$U@example.org:rtcy"
    run acl "$WS/run.sh"
    assert_line --index 0 "A::$U@example.org:rxtcy"
    run acl "$WS/sub/deeper/f"
    assert_line --index 0 "A::$U@example.org:rtcy"
}

@test "nfs4 share readwrite writes the mapped ACEs" {
    run ws_share --readwrite share ws $U
    assert_success
    run acl "$WS"
    assert_line --index 0 "A:d:$U@example.org:rwaDxtcy"
    assert_line --index 1 "A:fi:$U@example.org:rwatcy"
    run acl "$WS/data.txt"
    assert_line --index 0 "A::$U@example.org:rwatcy"
    run acl "$WS/run.sh"
    assert_line --index 0 "A::$U@example.org:rwaxtcy"
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
    assert_output --partial "A:d:$U@example.org:rwaDxtcy"
    refute_output --partial "A:d:$U@example.org:rxtcy"
    run bash -c "nfs4_getfacl '$WS/data.txt' | grep -c '$U@'"
    assert_output "1"
}

@test "nfs4 new files and directories inherit like POSIX default entries" {
    ws_share share ws $U
    mkdir "$WS/newdir"; nfs4_setfacl --mock-create "$WS" "$WS/newdir"
    echo x > "$WS/newdir/newfile"; nfs4_setfacl --mock-create "$WS/newdir" "$WS/newdir/newfile"
    run acl "$WS/newdir"
    assert_output --partial "A:d:$U@example.org:rxtcy"
    assert_output --partial "A:fi:$U@example.org:rtcy"
    run acl "$WS/newdir/newfile"
    assert_output --partial "A::$U@example.org:rtcy"
}

@test "nfs4 unshare removes only that user" {
    ws_share share ws $U
    ws_share share ws root
    run ws_share unshare ws $U
    assert_success
    assert_output --partial "Removing access for $U"
    run acl "$WS"
    refute_output --partial "$U@"
    assert_output --partial "A:d:root@example.org:rxtcy"
    run acl "$WS/sub/deeper/f"
    refute_output --partial "$U@"
    assert_output --partial "OWNER@"
}

@test "nfs4 unshare of a user without grants succeeds and changes nothing" {
    run ws_share unshare ws $U
    assert_success
    run grep -c -- "-e" "$NFS4_MOCK_STORE/calls.log"
    assert_output "0"
}

@test "nfs4 user and group of the same name are kept apart" {
    ws_share --yes sharegroup ws root
    ws_share share ws root
    run ws_share unsharegroup ws root
    assert_success
    run acl "$WS"
    refute_output --partial "A:dg:root@"
    assert_output --partial "A:d:root@example.org:rxtcy"
    run acl "$WS/data.txt"
    refute_output --partial "A:g:root@"
    assert_output --partial "A::root@example.org:rtcy"
}

@test "nfs4 sharegroup writes group ACEs" {
    run ws_share --readwrite --yes sharegroup ws $G
    assert_success
    run acl "$WS"
    assert_line --index 0 "A:dg:$G@example.org:rwaDxtcy"
    assert_line --index 1 "A:fig:$G@example.org:rwatcy"
    run acl "$WS/data.txt"
    assert_line --index 0 "A:g:$G@example.org:rwatcy"
}

@test "nfs4 unshare-all removes every named ACE and keeps the special ones" {
    ws_share share ws $U
    ws_share --yes sharegroup ws $G
    run ws_share unshare-all ws
    assert_success
    for f in "$WS" "$WS/data.txt" "$WS/sub/deeper/f"; do
        run acl "$f"
        refute_output --partial "example.org"
        assert_output --partial "OWNER@"
        assert_output --partial "EVERYONE@"
    done
}

@test "nfs4 list shows effective grants" {
    ws_share share ws $U
    ws_share --readwrite --yes sharegroup ws $G
    run ws_share list ws
    assert_success
    assert_line --regexp "^user +$U +read$"
    assert_line --regexp "^group +$G +readwrite$"
    refute_output --partial "OWNER"
}

@test "nfs4 check reports a consistent share" {
    ws_share share ws $U
    run ws_share check ws
    assert_success
    assert_output --partial "user $U: read"
}

@test "nfs4 check flags a grant without inheritable ACE" {
    ws_share share ws $U
    nfs4_getfacl "$WS" | grep -v '^#' | grep -v ':fi:' > "$BATS_TEST_TMPDIR/acl"
    cp "$BATS_TEST_TMPDIR/acl" "$NFS4_MOCK_STORE/$(stat -c %i "$WS")"
    sed -i "s/^A:d:/A::/" "$NFS4_MOCK_STORE/$(stat -c %i "$WS")"
    run ws_share check ws
    assert_failure
    assert_output --partial "new files will not inherit"
}

@test "nfs4 check on an unshared workspace" {
    run ws_share check ws
    assert_success
    assert_output --partial "not shared"
}

@test "nfs4 numeric principals" {
    export WS_SHARE_NFS4_IDFORMAT=numeric
    run ws_share share ws $U
    assert_success
    run acl "$WS"
    assert_line --index 0 "A:d:$(id -u $U):rxtcy"
    run ws_share list ws
    assert_line --regexp "^user +$U +read$"
    run ws_share unshare ws $U
    run acl "$WS"
    refute_output --partial ":$(id -u $U):"
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
