#!/bin/bash
# Fault-injection tests for install_image (A03): when copying the new image
# fails part-way, the previously installed image and its boot entry must be
# untouched and no half-written new image may be left for the boot menu to find.
#
# Fault kinds, labelled in the output:
#   [kernel]    an error the kernel itself returns, provoked unprivileged:
#               /dev/full as the copy target (ENOSPC) and `ulimit -f` (EFBIG).
#               The write really fails; the disk is not really full.
#   [simulated] a shell wrapper makes cp report failure (EIO-like). Nothing
#               in the I/O stack failed.
# No test here fills a real filesystem or injects errors into a real device.

THIS_DIR=$(cd "$(dirname "$0")" && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export TMPDIR=$T INSTALL_LOG=""

encrypt_shadow_passwd() { echo fixture-hash; }
. "$THIS_DIR/../scripts/vyatta-install-image.functions"
. "$THIS_DIR/../scripts/vyatta-create-partition.functions"
. "$THIS_DIR/../vii_database/vii.defaults"
get_live_persistence_label() { echo persistence; }
get_live_rootfs_path() { echo "$T/src"; }
export SHUNIT_TMPDIR=$T/src

fails=0
check() { # name want(pass|fail) status
    if { [ "$2" = fail ] && [ "$3" -ne 0 ]; } || { [ "$2" = pass ] && [ "$3" -eq 0 ]; }; then
        echo "ok   $1"
    else echo "FAIL $1 (status $3, wanted $2)"; fails=$((fails+1)); fi
}
yes_() { # name condition-status(0=true)
    if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi
}

setup() { # $1 = squashfs bytes, $2 = initrd bytes
    rm -rf "$T/src" "$T/dst"
    mkdir -p "$T/src/live" "$T/src/boot" "$T/dst/boot/old" "$T/dst/boot/grub"
    head -c "${1:-100}" /dev/zero | tr '\0' S > "$T/src/live/filesystem.squashfs"
    echo KERNEL > "$T/src/boot/vmlinuz-6.12.0"
    head -c "${2:-100}" /dev/zero | tr '\0' I > "$T/src/boot/initrd.img-6.12.0"
    ln -s vmlinuz-6.12.0 "$T/src/boot/vmlinuz"
    ln -s initrd.img-6.12.0 "$T/src/boot/initrd.img"
    # the image that is already installed and bootable
    echo OLDSQUASH > "$T/dst/boot/old/old.squashfs"
    echo OLDKERNEL > "$T/dst/boot/old/vmlinuz-5.0"
    echo OLDINITRD > "$T/dst/boot/old/initrd.img-5.0"
    ln -s vmlinuz-5.0 "$T/dst/boot/old/vmlinuz"
    printf 'menuentry "old" { linux /boot/old/vmlinuz\n initrd /boot/old/initrd.img }\n' \
        > "$T/dst/boot/grub/grub.cfg"
}

snapshot() { # stable description of everything the old image / boot menu consists of
    ( cd "$T/dst/boot" && find old grub -printf '%p %y %l\n' | sort
      find old grub -type f -exec sha256sum {} + | sort )
}

# old image must still be complete and readable end to end
old_usable() {
    [ "$(cat "$T/dst/boot/old/old.squashfs")" = OLDSQUASH ] &&
    [ "$(cat "$T/dst/boot/old/vmlinuz")" = OLDKERNEL ] &&
    [ "$(cat "$T/dst/boot/old/initrd.img-5.0")" = OLDINITRD ] &&
    grep -q '/boot/old/vmlinuz' "$T/dst/boot/grub/grub.cfg" &&
    grep -q '/boot/old/initrd.img' "$T/dst/boot/grub/grub.cfg"
}

run() { ( eval "$1"; install_image "$T/src" img0 "$T/dst" ) >"$T/out" 2>&1; }

expect_failed_install() { # label, setup-args..., then fault code in $FAULT, msg regex in $MSG
    local label=$1; shift
    setup "$@"
    local before; before=$(snapshot)
    run "$FAULT"
    check "$label: install fails" fail $?
    grep -Eqi "$MSG" "$T/out"; yes_ "$label: the underlying error is reported ($MSG)" $?
    [ "$(snapshot)" = "$before" ]; yes_ "$label: old image and boot menu byte-identical" $?
    old_usable; yes_ "$label: old image still complete and referenced by the menu" $?
    [ ! -e "$T/dst/boot/img0" ]; yes_ "$label: no half-written new image left behind" $?
    run ':'
    check "$label: a clean retry afterwards succeeds" pass $?
}

# --- control: no fault -------------------------------------------------------
setup
before=$(snapshot)
run ':'
check "control: unfaulted install succeeds" pass $?
[ "$(snapshot)" = "$before" ]; yes_ "control: old image untouched by a good install" $?

# --- [kernel] ENOSPC: the squashfs copy lands on /dev/full -------------------
FAULT='cp() { case "$*" in *squashfs*) command cp -p "$2" /dev/full;; *) command cp "$@";; esac; }'
MSG='No space left on device'
expect_failed_install "[kernel] ENOSPC on squashfs (/dev/full)"

# --- [kernel] EFBIG: squashfs fits under ulimit -f, the initrd does not -------
FAULT='trap "" XFSZ; ulimit -f 4'
MSG='File too large'
expect_failed_install "[kernel] EFBIG on initrd (ulimit -f)" 100 8192

# --- [kernel] EFBIG on the squashfs itself ------------------------------------
FAULT='trap "" XFSZ; ulimit -f 4'
MSG='File too large'
expect_failed_install "[kernel] EFBIG on squashfs (ulimit -f)" 8192 100

# --- [simulated] EIO-like failure while copying kernel/initrd -----------------
FAULT='cp() { case "$*" in *squashfs*) command cp "$@";; *) echo "cp: error writing: Input/output error" >&2; return 1;; esac; }'
MSG='Input/output error'
expect_failed_install "[simulated] EIO on kernel/initrd copy"

# --- [simulated] failure after a partial write of the squashfs ----------------
FAULT='cp() { case "$*" in *squashfs*) head -c 10 "$2" > "${@: -1}"; echo "cp: Input/output error" >&2; return 1;; *) command cp "$@";; esac; }'
MSG='Input/output error'
expect_failed_install "[simulated] EIO after partial squashfs write"

# --- the second directory creation (persistence dir) fails ----------------------
# [simulated] install reports ENOSPC for the persistence directory
FAULT='install() { case "$*" in *persistence*) echo "install: cannot create directory: No space left on device" >&2; return 1;; *) command install "$@";; esac; }'
MSG='No space left on device'
expect_failed_install "[simulated] ENOSPC creating the persistence dir"

# [kernel] real EACCES: once the image dir exists it is made read-only, so the
# kernel refuses the nested mkdir. Needs a non-root user (root ignores modes).
if [ "$(id -u)" -ne 0 ]; then
    FAULT='mkdir() { command mkdir "$@"; local rc=$?; [ $rc -eq 0 ] && chmod 555 "${@: -1}"; return $rc; }'
    MSG='Permission denied'
    expect_failed_install "[kernel] EACCES creating the persistence dir (read-only image dir)"
else
    echo "skip [kernel] EACCES case: running as root"
fi

# --- [kernel] persistence.conf write fails with ENOSPC (/dev/full) ----------------
FAULT='install() { command install "$@"; local rc=$?; case "$*" in *persistence*) ln -s /dev/full "${@: -1}/persistence.conf";; esac; return $rc; }'
MSG='No space left on device'
expect_failed_install "[kernel] ENOSPC writing persistence.conf (/dev/full)"

# --- a pre-existing image of the same name is never touched ------------------------
setup
mkdir -p "$T/dst/boot/img0"; echo KEEP > "$T/dst/boot/img0/precious"
before=$(snapshot; cat "$T/dst/boot/img0/precious")
run ':'
check "pre-existing same-name image: install refused" fail $?
[ "$(snapshot; cat "$T/dst/boot/img0/precious" 2>/dev/null)" = "$before" ]; yes_ "pre-existing same-name image left intact" $?
grep -q "already installed" "$T/out"; yes_ "pre-existing same-name image: reason reported" $?

# --- cleanup after a failure never removes other images ----------------------------
setup
mkdir -p "$T/dst/boot/img1"; echo KEEP > "$T/dst/boot/img1/precious"
FAULT='cp() { echo "cp: Input/output error" >&2; return 1; }'
run "$FAULT"
check "cleanup test: failing install of img0 fails" fail $?
[ "$(cat "$T/dst/boot/img1/precious")" = KEEP ] && [ "$(cat "$T/dst/boot/old/old.squashfs")" = OLDSQUASH ]
yes_ "cleanup removed only the new image dir, not sibling images" $?

# --- concurrency: a same-name install appears after our existence check -----------
# Deterministic: install_image calls df between its "already installed" check and
# the creation of the image dir, so a df hook plays the competing installer.
setup
FAULT='df() { mkdir -p "$T/dst/boot/img0" && echo racer > "$T/dst/boot/img0/racer-file"; command df "$@"; }'
before=$(snapshot)
run "$FAULT"
check "race: install refused when the name appeared after the check" fail $?
[ "$(cat "$T/dst/boot/img0/racer-file" 2>/dev/null)" = racer ]
yes_ "race: the competing installer's directory and files are untouched" $?
[ "$(snapshot)" = "$before" ]; yes_ "race: old image and boot menu byte-identical" $?
grep -qi "already installed\|exists" "$T/out"; yes_ "race: refusal is reported" $?

# competitor creates the directory only AFTER our own creation: ours is removed on
# failure, theirs (a different name) is untouched
setup
mkdir -p "$T/dst/boot/other"; echo theirs > "$T/dst/boot/other/f"
run 'cp() { echo "cp: Input/output error" >&2; return 1; }'
check "race: unrelated concurrent image, our install fails" fail $?
[ "$(cat "$T/dst/boot/other/f")" = theirs ] && [ ! -e "$T/dst/boot/img0" ]
yes_ "race: only our own directory was removed" $?

# --- cleanup failure must be reported, not hidden ---------------------------------
# [simulated] rm refuses
setup
before=$(snapshot)
run 'cp() { echo "cp: Input/output error" >&2; return 1; }; rm() { echo "rm: cannot remove: Device or resource busy" >&2; return 1; }'
check "cleanup failure [simulated]: install fails" fail $?
grep -q "Input/output error" "$T/out"; yes_ "cleanup failure [simulated]: original error still reported" $?
grep -q "$T/dst/boot/img0" "$T/out" && grep -qi "could not remove\|remove it" "$T/out"
yes_ "cleanup failure [simulated]: the leftover path and the need to remove it are reported" $?
[ "$(snapshot)" = "$before" ]; yes_ "cleanup failure [simulated]: old image and boot menu untouched" $?

# [kernel] real EACCES: a read-only subdirectory holding a file cannot be emptied
if [ "$(id -u)" -ne 0 ]; then
    setup
    before=$(snapshot)
    run 'cp() { chmod 555 "$T/dst/boot/img0/persistence"; echo "cp: Input/output error" >&2; return 1; }'
    check "cleanup failure [kernel]: install fails" fail $?
    [ -e "$T/dst/boot/img0" ]; yes_ "cleanup failure [kernel]: leftover really exists (control)" $?
    grep -q "$T/dst/boot/img0" "$T/out" && grep -qi "could not remove\|remove it" "$T/out"
    yes_ "cleanup failure [kernel]: leftover is reported" $?
    [ "$(snapshot)" = "$before" ]; yes_ "cleanup failure [kernel]: old image and boot menu untouched" $?
    chmod -R u+w "$T/dst/boot/img0" 2>/dev/null
else
    echo "skip [kernel] cleanup-failure case: running as root"
fi

[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
exit $((fails != 0))
