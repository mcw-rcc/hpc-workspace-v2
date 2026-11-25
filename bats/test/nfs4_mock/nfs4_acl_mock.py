#!/usr/bin/env python3
"""Test double for nfs4_getfacl / nfs4_setfacl (nfs4-acl-tools).

ACLs are kept in $NFS4_MOCK_STORE (one file per inode). Supports the subset
ws_share uses: nfs4_getfacl FILE..., nfs4_setfacl -a SPEC FILE...,
nfs4_setfacl -e FILE... (runs $EDITOR on a temp copy, like the real tool).
Inheritance on create is emulated by `nfs4_setfacl --mock-create PARENT NEW`.
Calls are appended to $NFS4_MOCK_STORE/calls.log.
"""
import os, stat, subprocess, sys, tempfile

store = os.environ["NFS4_MOCK_STORE"]
os.makedirs(store, exist_ok=True)

def log(args):
    with open(os.path.join(store, "calls.log"), "a") as f:
        f.write(os.path.basename(sys.argv[0]) + " " + " ".join(args) + "\n")

def key(path):
    return os.path.join(store, str(os.lstat(path).st_ino))

def mode_acl(path):
    m = os.lstat(path).st_mode
    def p(r, w, x):
        s = ""
        if m & r: s += "r"
        if m & w: s += "wa" + ("D" if stat.S_ISDIR(m) else "")
        if m & x: s += "x"
        return s + "tcy"
    return ["A::OWNER@:" + p(stat.S_IRUSR, stat.S_IWUSR, stat.S_IXUSR) + "TC",
            "A:g:GROUP@:" + p(stat.S_IRGRP, stat.S_IWGRP, stat.S_IXGRP),
            "A::EVERYONE@:" + p(stat.S_IROTH, stat.S_IWOTH, stat.S_IXOTH)]

def get(path):
    k = key(path)
    if os.path.exists(k):
        return [l for l in open(k).read().splitlines() if l.strip()]
    return mode_acl(path)

def put(path, aces):
    isdir = os.path.isdir(path)
    for a in aces:
        f = a.split(":")
        if len(f) != 4:
            sys.exit("Scanning ACE string '%s' failed." % a)
        if not isdir and any(c in f[1] for c in "fdni"):
            sys.exit("mock: inheritance flags on a non-directory: " + a)
    with open(key(path), "w") as fh:
        fh.write("\n".join(aces) + "\n")

def inherit(parent, new):
    isdir = os.path.isdir(new)
    out = []
    for a in get(parent):
        t, fl, who, perm = a.split(":")
        if "@" in who and who.endswith("@"):
            continue
        if isdir and "d" in fl:
            out.append("%s:%s:%s:%s" % (t, fl.replace("i", ""), who, perm))
        elif isdir and "f" in fl:
            out.append("%s:%s:%s:%s" % (t, fl if "i" in fl else fl + "i", who, perm))
        elif not isdir and "f" in fl:
            out.append("%s:%s:%s:%s" % (t, "".join(c for c in fl if c not in "fdni"), who, perm))
    put(new, out + mode_acl(new))

prog = os.path.basename(sys.argv[0])
args = sys.argv[1:]
log(args)
if prog == "nfs4_getfacl":
    for p in args:
        print("# file: " + p)
        print("\n".join(get(p)))
        print()
    sys.exit(0)

cmd = args[0]
if cmd == "--mock-create":
    inherit(args[1], args[2]); sys.exit(0)
if cmd == "-a":
    spec, files = args[1], args[2:]
    for p in files:
        put(p, spec.split(",") + get(p))
elif cmd == "-e":
    editor = os.environ.get("EDITOR", "vi")
    for p in args[1:]:
        fd, tmp = tempfile.mkstemp()
        with os.fdopen(fd, "w") as f:
            f.write("## Editing NFSv4 ACL for file: %s\n" % p)
            f.write("\n".join(get(p)) + "\n")
        rc = subprocess.call([editor, tmp])
        if rc != 0:
            sys.exit("Editor `%s' did not exit cleanly; changes will not be saved." % editor)
        aces = [l.strip() for l in open(tmp) if l.strip() and not l.lstrip().startswith("#")]
        os.unlink(tmp)
        put(p, aces)
else:
    sys.exit("mock: unsupported command " + cmd)
