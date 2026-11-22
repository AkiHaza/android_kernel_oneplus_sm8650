#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Pack only the external module build inputs, never certs/ (may contain signing keys).
set -euo pipefail
out=$(realpath -e "${1:?expected path to yaap-out}")
archive=$(realpath -m "${2:?expected output tarball}")
[[ $(basename "$out") == yaap-out ]]
cd "$out"
for file in .config Module.symvers System.map vmlinux include/config/{auto.conf,kernel.release} \
  include/generated/{autoconf,utsrelease}.h scripts/module.lds security/selinux/{flask,av_permissions}.h; do
  [[ -s $file ]] || { echo "Missing Kbuild output: $file" >&2; exit 1; }
done
for tool in scripts/basic/fixdep scripts/mod/modpost; do test -x "$tool"; done
entries=(.config Module.symvers System.map vmlinux include arch/arm64/include/generated scripts
         security/selinux/flask.h security/selinux/av_permissions.h)
if grep -Fxq 'CONFIG_DEBUG_INFO_BTF_MODULES=y' .config; then
  test -x tools/bpf/resolve_btfids/resolve_btfids
  entries+=(tools/bpf/resolve_btfids/resolve_btfids)
fi
# Kbuild generates these with absolute paths. Use the same sibling layout on
# any runner, including when downstream uses `make -C yaap-out`.
ln -sfn ../sm8650 source
printf 'include ../sm8650/Makefile\n' > Makefile
entries+=(source Makefile)
cd ..
tar --exclude='*.o' --exclude='*.a' --exclude='.*.cmd' -cf - "${entries[@]/#/yaap-out/}" | gzip -1 > "$archive"
if (( $(stat -c %s "$archive") >= 2147483648 )); then
  echo 'Context exceeds the per-asset GitHub Release size limit' >&2
  exit 1
fi
