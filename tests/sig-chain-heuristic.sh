#!/bin/bash
# Tests for sig_chain_in_db / sig_chain_trusted_for (A09). These check a
# COMPATIBILITY HEURISTIC (certificate subject names), not cryptographic trust.
# sbverify is replaced by a shell function: no real binary, firmware or key is
# touched, and nothing here shows that a signature is valid.
THIS_DIR=$(cd "$(dirname "$0")" && pwd -P)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export TMPDIR=$T INSTALL_LOG=""
encrypt_shadow_passwd() { echo fixture-hash; }
. "$THIS_DIR/../scripts/vyatta-install-image.functions"

fails=0
expect() { # name, wanted status, command...
    local name=$1 want=$2; shift 2
    "$@"; local rc=$?
    if [ "$rc" -eq "$want" ]; then echo "ok   $name"; else echo "FAIL $name (status $rc, wanted $want)"; fails=$((fails+1)); fi
}

MS_LEAF="/C=US/ST=Washington/L=Redmond/O=Microsoft Corporation/CN=Microsoft Windows UEFI Driver Publisher"
MS_CA="/C=US/ST=Washington/L=Redmond/O=Microsoft Corporation/CN=Microsoft Corporation UEFI CA 2011"
OBS_LEAF="/CN=home:danos OBS Project"
DB=("$MS_CA" "/CN=Some OEM db key")
MOK=("$OBS_LEAF")

# sbverify stub: SBV_OUT is what it prints, SBV_RC its exit status
sbverify() { printf '%s' "$SBV_OUT"; return "$SBV_RC"; }
listing() { local s out=""; for s in "$@"; do out+="signature $((++n)): subject: $s"$'\n'"issuer: x"$'\n'; done; printf '%s' "$out"; }

# --- the five requested cases ---------------------------------------------------------
n=0; SBV_OUT=$(listing "$MS_LEAF" "$MS_CA"); SBV_RC=0
expect "success + matching subject -> 0" 0 sig_chain_in_db shim "${DB[@]}"

n=0; SBV_OUT=$(listing "$MS_LEAF" "/CN=Unknown CA"); SBV_RC=0
expect "success + no matching subject -> 1" 1 sig_chain_in_db shim "${DB[@]}"

n=0; SBV_OUT=$(listing "$MS_LEAF" "$MS_CA"); SBV_RC=1
expect "NONZERO + matching subject can never pass -> 2" 2 sig_chain_in_db shim "${DB[@]}"

SBV_OUT=""; SBV_RC=0
expect "success but no subjects at all -> 2" 2 sig_chain_in_db shim "${DB[@]}"

n=0; SBV_OUT=$(listing "$MS_LEAF" "$MS_CA"); SBV_RC=0
expect "shim chain naming the MS CA: db-only trust accepts it" 0 sig_chain_trusted_for shim DB MOK
n=0; SBV_OUT=$(listing "$OBS_LEAF"); SBV_RC=0
expect "OBS-signed binary as shim: db only, MOK subject NOT accepted -> 1" 1 sig_chain_trusted_for /x/usr/lib/shim/shimx64.efi.signed DB MOK
expect "OBS-signed binary as grub: db + MOK accepts it -> 0" 0 sig_chain_trusted_for /x/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed DB MOK
expect "OBS-signed binary as kernel: db + MOK accepts it -> 0" 0 sig_chain_trusted_for /x/boot/vmlinuz DB MOK
n=0; SBV_OUT=$(listing "$MS_CA"); SBV_RC=0
expect "grub/kernel still accept a db subject too -> 0" 0 sig_chain_trusted_for /x/boot/vmlinuz DB MOK
EMPTY=()
n=0; SBV_OUT=$(listing "$OBS_LEAF"); SBV_RC=0
expect "no MOK enrolled: OBS-signed kernel -> 1" 1 sig_chain_trusted_for /x/boot/vmlinuz DB EMPTY

# --- the nonzero rule holds through the trust selection too ----------------------------
n=0; SBV_OUT=$(listing "$OBS_LEAF"); SBV_RC=1
expect "nonzero + MOK match as kernel -> 2" 2 sig_chain_trusted_for /x/boot/vmlinuz DB MOK
for rc in 1 2 127 255; do
    n=0; SBV_OUT=$(listing "$MS_CA"); SBV_RC=$rc
    expect "nonzero status $rc with a db match -> 2" 2 sig_chain_in_db shim "${DB[@]}"
done

# --- hardening around the heuristic ----------------------------------------------------
SBV_OUT=$'signature 1: subject: \n'; SBV_RC=0
expect "empty subject vs empty db entry must not match -> 2" 2 sig_chain_in_db shim "" "${DB[@]}"
n=0; SBV_OUT=$(listing "$MS_LEAF"); SBV_RC=0
expect "empty db entries never match a real subject -> 1" 1 sig_chain_in_db shim "" ""
expect "no db subjects at all -> 1" 1 sig_chain_in_db shim
SBV_OUT="No signature table present"; SBV_RC=1
expect "unsigned binary (sbverify error text, nonzero) -> 2" 2 sig_chain_in_db shim "${DB[@]}"
SBV_OUT="subject: $MS_CA"; SBV_RC=0
expect "subject prefix match is case-insensitive on the label only" 0 sig_chain_in_db shim "$MS_CA"
n=0; SBV_OUT=$(listing "$MS_CA extra"); SBV_RC=0
expect "a DN that merely contains a db DN does not match -> 1" 1 sig_chain_in_db shim "${DB[@]}"

# --- wording: the code must not present this as cryptographic verification -------------
grep -q 'COMPATIBILITY HEURISTIC, not a trust verification' "$THIS_DIR/../scripts/vyatta-install-image.functions"
rc=$?; if [ $rc -eq 0 ]; then echo "ok   documented as a compatibility heuristic"; else echo "FAIL heuristic wording missing"; fails=$((fails+1)); fi

[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
exit $((fails != 0))
