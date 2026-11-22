#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "${RUNNER_TEMP:?}"
src=$PWD/sm8650
out=$PWD/yaap-out
dist=$PWD/dist
mkdir "$out" "$dist"

# setlocalversion consumes these Android build variables; plain `make` leaves
# the Android KMI out of kernel.release (and hence the module's vermagic).
export BRANCH KMI_GENERATION ARCH=arm64 LLVM=1 LLVM_IAS=1
BRANCH=$(sed -n 's/^BRANCH=//p' "$src/build.config.constants")
KMI_GENERATION=$(sed -n 's/^KMI_GENERATION=//p' "$src/build.config.common")
[[ $BRANCH =~ ^(android[0-9]+)-[0-9]+\.[0-9]+$ && $KMI_GENERATION =~ ^[0-9]+$ ]]
km=(make -C "$src" O="$out")
"${km[@]}" gki_defconfig
KCONFIG_CONFIG="$out/.config" "$src/scripts/kconfig/merge_config.sh" -m -r -y "$out/.config" \
  "$src/arch/arm64/configs/vendor/pineapple_GKI.config" \
  "$src/arch/arm64/configs/vendor/oplus/pineapple_GKI.config"
"${km[@]}" olddefconfig
for k in MODULES MODVERSIONS MODULE_SIG_PROTECT SECURITY_SELINUX; do
  grep -Fx "CONFIG_$k=y" "$out/.config" >/dev/null
done
"${km[@]}" -j"$(nproc)" Image modules
"${km[@]}" modules_prepare
release=$(cat "$out/include/config/kernel.release")
[[ $release == *"-${BRANCH%%-*}-$KMI_GENERATION" || $release == *"-${BRANCH%%-*}-$KMI_GENERATION-"* ]]

bash "$here/pack.sh" "$out" "$dist/yaap-kernel-context.tar.gz"
cp "$out/.config" "$dist/yaap-config.txt"
# Exercise the published bytes at a different path with the original source
# path no longer available. This module is only compiled, never loaded.
mkdir verify
mv sm8650 sm8650-modules verify/
tar -xzf "$dist/yaap-kernel-context.tar.gz" -C verify
mkdir verify/probe
printf '%s\n' 'obj-m := yaap_probe.o' > verify/probe/Makefile
cat > verify/probe/yaap_probe.c <<'C'
#include <linux/init.h>
#include <linux/module.h>
static int __init probe_init(void) { return 0; }
static void __exit probe_exit(void) { }
module_init(probe_init);
module_exit(probe_exit);
MODULE_LICENSE("GPL");
C
make -C "$PWD/verify/sm8650" O="$PWD/verify/yaap-out" M="$PWD/verify/probe" modules
ko=verify/probe/yaap_probe.ko
readelf -h "$ko" | grep -E 'Machine:[[:space:]]+AArch64' >/dev/null
[[ $(modinfo -F vermagic "$ko") == "$release "* ]]

jq -n --arg kernel "$GITHUB_REPOSITORY" --arg kc "$KERNEL_COMMIT" --arg release "$release" \
  --arg modules "$MODULES_REPO" --arg mc "$MODULES_COMMIT" \
  --arg url "$TOOLCHAIN_URL" --arg hash "$TOOLCHAIN_SHA256" \
  --arg branch "$BRANCH" --arg kmi "$KMI_GENERATION" --arg recipe "$GITHUB_SHA" \
  '{schema:1,recipe_commit:$recipe,arch:"arm64",host:"ubuntu-24.04-x86_64",
    kernel:{repo:$kernel,ref:"seventeen",commit:$kc,release:$release},
    modules:{repo:$modules,ref:"seventeen",commit:$mc},toolchain:{url:$url,sha256:$hash},
    kbuild:{BRANCH:$branch,KMI_GENERATION:$kmi,LLVM:1,LLVM_IAS:1},module_sig_protect:"y"}' > "$dist/manifest.json"
(cd "$dist" && sha256sum yaap-kernel-context.tar.gz yaap-config.txt manifest.json > SHA256SUMS)
