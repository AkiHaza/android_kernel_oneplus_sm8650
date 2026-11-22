# YAAP SM8650 外置模块的内核预构建包

在 **内核仓库**运行 `Watch waffle OTA and sync seventeen`（定时或手动）。同步成功后，直接把刚推送的 kernel SHA 交给预构建任务；不依赖机器人 push 触发第二个 workflow，也不以 OTA tag 为构建条件。modules 从同账号的 `android_kernel_oneplus_sm8650-modules:seventeen` 取 SHA，确认它已包含本次检查所见的 YAAP modules 上游提交。任一 SHA 变化就产生一组新文件，已有完整 Release 则跳过整个编译。首次运行、上次失败、仅 modules 更新都不要求 kernel 再有新提交。

**启用条件**：GitHub Actions 定时任务读取默认分支。若工作流只放在 `action` 分支，请将它设为默认分支，或把工作流及 `.github/yaap-prebuilt/` 部署到默认分支；modules 仓库也需要其原有同步任务正常运行。fork 需启用 Actions，允许同步任务写 `seventeen` 及发布任务写 Releases。内核任务排在每天 00:37 UTC（北京时间 08:37），比 modules 任务晚 37 分钟；若 modules 同步延迟，等待其完成后重跑，或留给下次定时任务。

## Release 契约

Tag：`yaap-kbuild-v1-<kernel SHA 前12位>-<modules SHA 前12位>`，指向内核提交，而非 workflow 提交。如果更换配置、工具链或不兼容的打包方式，请调整 workflow 的 tag 版本。构建使用 Ubuntu 24.04 x86-64、Floran clang-r596125、ARM64 `gki_defconfig` + 两个 pineapple GKI fragment；不修改内核的模块签名、保护或导出符号策略。Android release/KMI generation 取自该版源码的 `build.config.constants` 和 `build.config.common`。

| 附件 | 内容 |
| --- | --- |
| `yaap-kernel-context.tar.gz` | `yaap-out/`：完整 `.config`、`Module.symvers`、带符号的 `vmlinux`、`System.map`、生成的通用/ARM64/SELinux 头文件、链接脚本和宿主机辅助程序。不是可刷机镜像。 |
| `manifest.json` | 两个源码仓库和完整 SHA、实际 `kernel.release`、构建参数、工具链 URL/SHA-256 及构建配方提交。 |
| `yaap-config.txt` | 生效的完整 `.config`，可与目标设备配置比较。 |
| `SHA256SUMS` | 上述三个附件的 SHA-256。 |

只发布在**解包并换目录后**成功编译最小外置模块、验证 AArch64 和 vermagic 的包。源码树、Clang、内核中间对象、签名私钥和下游 `.ko` 不在包内。

## 下游如何使用

在空工作目录中，指定期望的两个完整 SHA（不要使用 `releases/latest`）；预备 `gh`、`jq`、Git、Kbuild 构建依赖和相同版本的 Clang/LLVM。宿主机辅助程序以 Ubuntu 24.04 x86-64 为目标，不是在 Android 手机上运行的程序。

```bash
set -euo pipefail
: "${KERNEL_COMMIT:?设为要构建的 kernel SHA}" "${MODULES_COMMIT:?设为要构建的 modules SHA}"
repo=AkiHaza/android_kernel_oneplus_sm8650
tag="yaap-kbuild-v1-${KERNEL_COMMIT:0:12}-${MODULES_COMMIT:0:12}"
gh release download "$tag" -R "$repo"
sha256sum -c SHA256SUMS
jq -e --arg k "$KERNEL_COMMIT" --arg m "$MODULES_COMMIT" \
  '.schema == 1 and .kernel.commit == $k and .modules.commit == $m' manifest.json >/dev/null

for pair in kernel:sm8650 modules:sm8650-modules; do
  key=${pair%:*}; dir=${pair#*:}
  git init -q "$dir"
  git -C "$dir" fetch --no-tags --depth=1 "https://github.com/$(jq -r ".$key.repo" manifest.json).git" \
    "$(jq -r ".$key.commit" manifest.json)"
  git -C "$dir" checkout -q --detach FETCH_HEAD
done
tar -xzf yaap-kernel-context.tar.gz
cmp yaap-config.txt yaap-out/.config
test "$(cat yaap-out/include/config/kernel.release)" = "$(jq -r .kernel.release manifest.json)"
# 将 manifest 指定的工具链校验 SHA-256、解压并将其 bin 加入 PATH 后：
export ARCH=arm64 LLVM=1 LLVM_IAS=1
export BRANCH="$(jq -r .kbuild.BRANCH manifest.json)" KMI_GENERATION="$(jq -r .kbuild.KMI_GENERATION manifest.json)"
make -C "$PWD/sm8650" O="$PWD/yaap-out" M="${MODULE_DIR:?设为外置模块源码绝对路径}" modules
```

两个下游现有工作流**不会自动切换**至 Release。接入时用上述下载/校验/恢复步骤替代公共的 `Image modules` 阶段；保留下游各自的模块构建、专用宿主工具处理、校验及打包步骤。该包只对应 `MODULE_SIG_PROTECT=y`；`LKM4YAAP` 若选 `n` 或需要其他配置，仍按其原流程从源码构建，勿修改预构建包的 `.config` 混用。两个 SHA 是源码身份，不是 OTA 与设备 ABI 一致的证明；使用前仍需核对实际设备的 `uname -r`、配置和模块策略。
