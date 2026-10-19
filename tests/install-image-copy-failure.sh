#!/bin/bash
# Negative tests: install_image must fail, and say so, when copying the new
# image's files fails. Standalone (no shUnit2): exits non-zero on any failure.

THIS_DIR=$(cd "$(dirname "$0")" && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export TMPDIR=$T INSTALL_LOG=""

# Fixture stand-in: vii.defaults calls the real helper from another package.
encrypt_shadow_passwd() { echo fixture-hash; }

. "$THIS_DIR/../scripts/vyatta-install-image.functions"
. "$THIS_DIR/../scripts/vyatta-create-partition.functions"
. "$THIS_DIR/../vii_database/vii.defaults"

# Helpers install_image normally gets from the live-image environment.
get_live_persistence_label() { echo persistence; }
get_live_rootfs_path() { echo "$T/src"; }
# install_image falls back to $SHUNIT_TMPDIR/boot when /mnt/cdsquash is absent.
export SHUNIT_TMPDIR=$T/src

fails=0
check() { # name expected_nonzero(0/1) actual_status
    if [ "$2" = fail ] && [ "$3" -ne 0 ]; then echo "ok   $1"
    elif [ "$2" = pass ] && [ "$3" -eq 0 ]; then echo "ok   $1"
    else echo "FAIL $1 (status $3, wanted $2)"; fails=$((fails+1)); fi
}

setup() { # populate a source tree and an empty target
    rm -rf "$T/src" "$T/dst"
    mkdir -p "$T/src/live" "$T/src/boot" "$T/dst"
    echo SQUASH > "$T/src/live/filesystem.squashfs"
    # same layout as the image's /boot: versioned files plus symlinks
    echo KERNEL > "$T/src/boot/vmlinuz-6.12.0"
    echo INITRD > "$T/src/boot/initrd.img-6.12.0"
    ln -s vmlinuz-6.12.0 "$T/src/boot/vmlinuz"
    ln -s initrd.img-6.12.0 "$T/src/boot/initrd.img"
}

run() { # run install_image in a subshell, with optional overrides in $1
    ( eval "$1"; install_image "$T/src" img0 "$T/dst" ) >"$T/out" 2>&1
}

# control: nothing injected, the install succeeds and the data is there
setup
run ':'
check "control: clean copy succeeds" pass $?
[ "$(cat "$T/dst/boot/img0/img0.squashfs" 2>/dev/null)" = SQUASH ] || { echo "FAIL control: squashfs content"; fails=$((fails+1)); }

# squashfs copy fails (e.g. ENOSPC / EIO) while sync succeeds
setup
run 'cp() { case "$*" in *squashfs*) return 1;; *) command cp "$@";; esac; }; sync() { return 0; }'
check "squashfs cp failure is fatal" fail $?

# kernel/initrd copy fails
setup
run 'cp() { case "$*" in *squashfs*) command cp "$@";; *) return 1;; esac; }; sync() { return 0; }'
check "kernel/initrd cp failure is fatal" fail $?

# short write: copy "succeeds" but the target is truncated
setup
run 'cp() { case "$*" in *squashfs*) : > "${@: -1}"; return 0;; *) command cp "$@";; esac; }; sync() { return 0; }'
check "truncated squashfs is fatal" fail $?

# the failure must be reported, not silent
setup
run 'cp() { return 1; }; sync() { return 0; }'
grep -qi "error" "$T/out"
check "failure is reported in output" pass $?

# missing initrd / kernel in the source must not pass
setup; rm "$T/src/boot/initrd.img" "$T/src/boot/initrd.img-6.12.0"
run ':'
check "missing initrd is fatal" fail $?
setup; rm "$T/src/boot/vmlinuz" "$T/src/boot/vmlinuz-6.12.0"
run ':'
check "missing kernel is fatal" fail $?

# same-size corruption of a boot file (existence check alone would pass)
setup
run 'cp() { command cp "$@"; for a; do :; done; [ -f "${a}initrd.img-6.12.0" ] && printf XXXXXX > "${a}initrd.img-6.12.0"; return 0; }'
check "corrupted initrd is fatal" fail $?

# same-size corruption of the squashfs
setup
run 'cp() { command cp "$@"; case "$*" in *squashfs*) printf XXXXXX > "${@: -1}";; esac; return 0; }'
check "corrupted squashfs is fatal" fail $?

# a symlink copied as the wrong thing
setup
run 'cp() { command cp "$@"; for a; do :; done; [ -d "$a" ] && ln -sfn initrd.img-9.9 "${a}initrd.img"; return 0; }'
check "wrong symlink target is fatal" fail $?

# sync -f fails but plain sync succeeds: must not be masked
setup
run 'sync() { [ "$1" = "-f" ] && return 1; return 0; }'
check "sync -f failure is not masked by plain sync" fail $?

# the sync itself failing must not be swallowed either
setup
run 'sync() { return 1; }'
check "sync failure is fatal" fail $?

[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
exit $((fails != 0))
