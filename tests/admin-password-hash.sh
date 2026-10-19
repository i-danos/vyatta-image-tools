#!/bin/bash
# Regression test: the administrator password hash must reach BOTH
# config.boot and useradd unchanged. A hash containing '/' used to be
# sed-escaped to '\/' inside _dialog_enter_password, which is right for the
# config.boot sed replacement and wrong for `useradd --password`: the literal
# backslash ended up in /etc/shadow and the account could never log in.
# Standalone (no shUnit2): exits non-zero on any failure.

THIS_DIR=$(cd "$(dirname "$0")" && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export TMPDIR=$T INSTALL_LOG=""

command -v python3 >/dev/null || { echo "SKIP: python3 needed for the pty"; exit 0; }

# Deterministic hashes: one with several '/', one with the other characters a
# sed replacement treats specially.
HASH_SLASH='$6$sa/lt/12$aaa/bbb.ccc/ddd/eee'
HASH_ODD='$6$sa\lt&12$aaa/b&b\ccc'

fails=0
check() { # name, expected, actual
    if [ "$2" = "$3" ]; then echo "ok   $1"
    else echo "FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; fails=$((fails+1)); fi
}

# The dialog reads from /dev/tty, so drive it through a pty.
dialog_hash() { # $1 = hash the (fixture) crypt helper returns
    FIXTURE_HASH=$1 FUNCS="$THIS_DIR/../scripts/vyatta-install-image.functions" python3 - <<'PY'
import os, pty, re, sys, time
child = r'''
. "$FUNCS"
encrypt_shadow_passwd() { printf '%s\n' "$FIXTURE_HASH"; }
cli-shell-api() { :; }
cfgcmds() { cat; }
VII_ADMIN_PASSWORD=$(_dialog_enter_password vyatta)
printf 'RESULT=[%s]\n' "$VII_ADMIN_PASSWORD"
'''
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", child])
out = b""
sent = 0
deadline = time.time() + 20
while time.time() < deadline:
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    out += d
    if sent < 2 and (b"user 'vyatta':" in out):
        n = out.count(b"user 'vyatta':")
        while sent < n and sent < 2:
            os.write(fd, b"correct-horse\n")
            sent += 1
            time.sleep(0.2)
text = out.decode(errors="replace").replace("\r", "")
m = re.search(r"RESULT=\[(.*)\]\n", text, re.S)
print(m.group(1) if m else "NO-RESULT:" + text[-200:])
PY
}

for name in SLASH ODD; do
    eval "hash=\$HASH_$name"
    got=$(dialog_hash "$hash")
    check "$name: dialog returns the hash unmodified" "$hash" "$got"

    # Feed that value through the real create_admin_account.
    (
        . "$THIS_DIR/../scripts/vyatta-install-image.functions" >/dev/null 2>&1
        mkdir -p "$T/sbin"
        printf '#!/bin/sh\nexit 0\n' > "$T/sbin/vyatta_create_account"
        chmod +x "$T/sbin/vyatta_create_account"
        vyatta_sbindir=$T/sbin
        cfg=$T/config.boot.$name
        printf 'system {\n  login {\n    user vyatta {\n      authentication {\n        encrypted-password "placeholder"\n      }\n    }\n  }\n}\n' > "$cfg"
        useradd() { printf '%s\n' "$@" > "$T/useradd.$name"; }
        VII_ADMIN_USERNAME=vyatta
        VII_ADMIN_PASSWORD=$got
        create_admin_account "$cfg" "$T/root" >/dev/null 2>&1
    )
    cfgval=$(sed -n 's/.*encrypted-password "\(.*\)"$/\1/p' "$T/config.boot.$name")
    check "$name: config.boot holds the exact hash" "$hash" "$cfgval"
    # the argument after --password
    ua=$(awk '$0=="--password"{getline; print; exit}' "$T/useradd.$name" 2>/dev/null)
    check "$name: useradd receives the exact hash" "$hash" "$ua"
done

[ "$fails" -eq 0 ] && echo "all admin-password-hash checks passed"
exit $fails
