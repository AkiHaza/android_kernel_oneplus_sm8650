#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Offline checks of the release archive contract; CI tests the actual ARM64 build."""
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

PACK = Path(__file__).resolve().with_name('pack.sh')


class ContextTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.out = self.root / 'yaap-out'
        self.archive = self.root / 'context.tar.gz'
        for name in ('.config Module.symvers vmlinux System.map include/config/auto.conf '
                     'include/config/kernel.release include/generated/utsrelease.h '
                     'include/generated/autoconf.h scripts/module.lds scripts/basic/fixdep '
                     'scripts/mod/modpost arch/arm64/include/generated/asm/syscalls.h '
                     'security/selinux/flask.h security/selinux/av_permissions.h '
                     'certs/signing_key.pem scripts/mod/modpost.o scripts/mod/.modpost.o.cmd').split():
            path = self.out / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture\n')
        for name in ('scripts/basic/fixdep', 'scripts/mod/modpost'):
            (self.out / name).chmod(0o755)

    def pack(self):
        return subprocess.run(['bash', PACK, self.out, self.archive], capture_output=True)

    def test_relocatable_allowlist(self):
        (self.out / 'source').symlink_to('/old/runner/sm8650')
        (self.out / 'Makefile').write_text('include /old/runner/sm8650/Makefile\n')
        result = self.pack()
        self.assertEqual(result.returncode, 0, result.stderr)
        with tarfile.open(self.archive) as tar:
            names = set(tar.getnames())
            for name in ('Module.symvers', '.config', 'security/selinux/flask.h', 'vmlinux'):
                self.assertIn('yaap-out/' + name, names)
            for name in ('certs/signing_key.pem', 'scripts/mod/modpost.o', 'scripts/mod/.modpost.o.cmd'):
                self.assertNotIn('yaap-out/' + name, names)
            self.assertEqual(tar.getmember('yaap-out/source').linkname, '../sm8650')
            self.assertEqual(tar.extractfile('yaap-out/Makefile').read(), b'include ../sm8650/Makefile\n')
            self.assertTrue(tar.getmember('yaap-out/scripts/mod/modpost').mode & 0o100)

    def test_btf_helper_is_required_and_shipped_when_enabled(self):
        (self.out / '.config').write_text('CONFIG_DEBUG_INFO_BTF_MODULES=y\n')
        self.assertNotEqual(self.pack().returncode, 0)
        tool = self.out / 'tools/bpf/resolve_btfids/resolve_btfids'
        tool.parent.mkdir(parents=True)
        tool.write_text('fixture\n')
        tool.chmod(0o755)
        self.assertEqual(self.pack().returncode, 0)
        with tarfile.open(self.archive) as tar:
            self.assertIn(str(tool.relative_to(self.root)), tar.getnames())

    def test_modules_prepare_alone_is_not_enough(self):
        (self.out / 'Module.symvers').write_bytes(b'')
        self.assertNotEqual(self.pack().returncode, 0)
        self.assertFalse(self.archive.exists())


if __name__ == '__main__':
    unittest.main()
