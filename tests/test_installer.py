"""Regression tests run against disposable game directories; never a live install."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
BUILD = REPO / 'build'
SDK_PATH = os.environ.get('SDKROOT') or subprocess.check_output(
    ['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()


def snapshot(directory):
    return {p.name: (p.read_bytes(), p.stat().st_mode & 0o777)
            for p in directory.iterdir() if p.is_file() and not p.is_symlink()}


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='game-fixture-', dir=BUILD)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.game = self.root / 'game with spaces'
        self.binary = self.game / 'Bin' / 'x64'
        self.binary.mkdir(parents=True)
        shutil.copy2(BUILD / 'fixture-game', self.binary / 'Sam2017')
        self.original = snapshot(self.binary)
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        self.env = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ['PATH'])
        # Exercise SDK discovery even when the developer selected SDKROOT locally.
        self.env.pop('SDKROOT', None)
        self.env['TEST_SDK_PATH'] = SDK_PATH
        self.env['TEST_LIBRARY'] = str(BUILD / 'fusionfix.dylib')
        self.script('xcrun', '''#!/bin/sh
if [ "$1" = --sdk ] && [ "$2" = macosx ] && [ "$3" = --show-sdk-path ]; then
  printf '%s\\n' "$TEST_SDK_PATH"
  exit 0
fi
[ "${FAIL_COMPILE:-0}" != 1 ] || exit 42
[ "$1" = clang ] || exit 43
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then cp "$TEST_LIBRARY" "$2"; exit 0; fi
  shift
done
exit 44
''')
        self.script('mv', '''#!/bin/sh
for arg do
  case "$arg" in
    */.fusionfix-install.*/fusionfix.dylib) [ "${FAIL_MOVE:-}" != library ] || exit 42 ;;
    */.fusionfix-install.*/Sam2017) [ "${FAIL_MOVE:-}" != wrapper ] || exit 42 ;;
    */.fusionfix-install.*/state) [ "${FAIL_MOVE:-}" != state ] || exit 42 ;;
  esac
done
exec /bin/mv "$@"
''')

    def script(self, name, contents):
        path = self.tools / name
        path.write_text(contents)
        path.chmod(0o755)
        return path

    def install(self, *args, repo=REPO, **env):
        return subprocess.run([str(repo / 'install.sh'), '--game-dir', str(self.game), *args],
                              env=dict(self.env, **env), text=True, capture_output=True, timeout=30)

    def assert_clean_original(self):
        self.assertEqual(snapshot(self.binary), self.original)
        self.assertEqual(sorted(p.name for p in self.binary.iterdir()), ['Sam2017'])

    def test_install_and_uninstall_preserve_original(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.binary / 'Sam2017_real').read_bytes(), self.original['Sam2017'][0])
        self.assertEqual((self.binary / 'Sam2017').read_bytes(), (REPO / 'Sam2017.wrapper.sh').read_bytes())
        self.assertEqual((self.binary / '.fusionfix-state').stat().st_mode & 0o777, 0o600)
        result = self.install('--uninstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_clean_original()

    def test_real_compiler_install_and_uninstall(self):
        self.env['PATH'] = os.environ['PATH']
        self.env['SDKROOT'] = SDK_PATH
        self.assertEqual(self.install().returncode, 0)
        result = self.install('--uninstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_clean_original()

    def test_failed_exclusive_backup_does_not_remove_an_existing_copy(self):
        self.script('ln', '''#!/bin/sh
cp "$1" "$2"
exit 42
''')
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.binary / 'Sam2017').read_bytes(), self.original['Sam2017'][0])
        self.assertEqual((self.binary / 'Sam2017_real').read_bytes(), self.original['Sam2017'][0])
        self.assertFalse((self.binary / 'fusionfix.dylib').exists())
        self.assertFalse((self.binary / '.fusionfix-state').exists())

    def test_repeat_install_does_not_touch_backup(self):
        self.assertEqual(self.install().returncode, 0)
        before = snapshot(self.binary)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already exists', result.stderr)
        self.assertEqual(snapshot(self.binary), before)
        self.assertFalse((self.binary / '.fusionfix-lock').exists())

    def test_compile_failure_leaves_original_untouched(self):
        self.assertNotEqual(self.install(FAIL_COMPILE='1').returncode, 0)
        self.assert_clean_original()

    def test_publish_failures_roll_back(self):
        for target in ('library', 'wrapper', 'state'):
            with self.subTest(target=target):
                result = self.install(FAIL_MOVE=target)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('original executable restored', result.stderr)
                self.assert_clean_original()

    def test_existing_backup_symlink_is_rejected(self):
        victim = self.root / 'victim'
        victim.write_text('preserve me')
        (self.binary / 'Sam2017_real').symlink_to(victim)
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual(victim.read_text(), 'preserve me')
        self.assertEqual((self.binary / 'Sam2017').read_bytes(), self.original['Sam2017'][0])

    def test_dangling_backup_symlink_is_rejected(self):
        (self.binary / 'Sam2017_real').symlink_to(self.root / 'absent')
        self.assertNotEqual(self.install().returncode, 0)
        self.assertTrue((self.binary / 'Sam2017_real').is_symlink())

    def test_original_symlink_is_rejected(self):
        victim = self.root / 'original'
        shutil.move(self.binary / 'Sam2017', victim)
        (self.binary / 'Sam2017').symlink_to(victim)
        self.assertNotEqual(self.install().returncode, 0)
        self.assertTrue((self.binary / 'Sam2017').is_symlink())
        self.assertEqual(victim.read_bytes(), self.original['Sam2017'][0])

    def test_modified_backup_prevents_uninstall(self):
        self.assertEqual(self.install().returncode, 0)
        with (self.binary / 'Sam2017_real').open('ab') as stream:
            stream.write(b'changed')
        before = snapshot(self.binary)
        self.assertNotEqual(self.install('--uninstall').returncode, 0)
        self.assertEqual(snapshot(self.binary), before)

    def test_modified_launcher_prevents_uninstall(self):
        self.assertEqual(self.install().returncode, 0)
        (self.binary / 'Sam2017').write_bytes(self.original['Sam2017'][0])
        before = snapshot(self.binary)
        self.assertNotEqual(self.install('--uninstall').returncode, 0)
        self.assertEqual(snapshot(self.binary), before)

    def test_existing_lock_is_not_removed(self):
        lock = self.binary / '.fusionfix-lock'
        lock.mkdir()
        self.assertNotEqual(self.install().returncode, 0)
        self.assertTrue(lock.is_dir())

    def test_tampered_source_fails_before_replacing_original(self):
        repo = self.root / 'source'
        repo.mkdir()
        for name in ('install.sh', 'build.sh', 'fusionfix.m', 'Sam2017.wrapper.sh', 'SHA256SUMS'):
            shutil.copy2(REPO / name, repo / name)
        with (repo / 'fusionfix.m').open('a') as stream:
            stream.write('\n// unexpected change\n')
        result = self.install(repo=repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum verification failed', result.stderr)
        self.assert_clean_original()

    def test_wrapper_preserves_arguments_and_ignores_log_symlinks(self):
        shutil.copy2(REPO / 'Sam2017.wrapper.sh', self.binary / 'Sam2017')
        real = self.binary / 'Sam2017_real'
        real.write_text('#!' + sys.executable + '\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n')
        real.chmod(0o755)
        log = self.game / 'Log'
        log.mkdir()
        victim = self.root / 'untouched'
        victim.write_text('original')
        for name in ('stderr.log', 'fusionfix.log'):
            (log / name).symlink_to(victim)
        canary = self.root / 'must-not-exist'
        args = ['space argument', '$(touch ' + str(canary) + ')', '; touch ' + str(canary), 'quote\"\'']
        result = subprocess.run([str(self.binary / 'Sam2017'), *args],
                                env=dict(self.env, FUSIONFIX_LOG=str(victim)),
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), args)
        self.assertFalse(canary.exists())
        self.assertEqual(victim.read_text(), 'original')

    def test_wrapper_refuses_library_symlink(self):
        shutil.copy2(REPO / 'Sam2017.wrapper.sh', self.binary / 'Sam2017')
        shutil.copy2(BUILD / 'fixture-game', self.binary / 'Sam2017_real')
        (self.binary / 'fusionfix.dylib').symlink_to(BUILD / 'fusionfix.dylib')
        result = subprocess.run([str(self.binary / 'Sam2017')], text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('symbolic link', result.stderr)

    def add_unrestricted_original(self):
        path = self.binary / 'Sam2017_Unrestricted'
        # Distinct bytes catch accidental restoration of the other executable.
        data = (BUILD / 'fixture-game').read_bytes() + b'UNRESTRICTED_FIXTURE'
        path.write_bytes(data)
        path.chmod(0o755)
        return data

    def test_unrestricted_install_uninstall_preserves_regular_patch(self):
        original = self.add_unrestricted_original()
        self.assertEqual(self.install().returncode, 0)
        before = snapshot(self.binary)
        result = self.install('--unrestricted')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.binary / 'Sam2017_Unrestricted_real').read_bytes(), original)
        for name, contents in before.items():
            if name != 'Sam2017_Unrestricted':
                self.assertEqual(snapshot(self.binary)[name], contents)
        self.assertEqual(self.install('--unrestricted', '--uninstall').returncode, 0)
        self.assertEqual(snapshot(self.binary), before)

    def test_regular_uninstall_preserves_unrestricted_patch(self):
        self.add_unrestricted_original()
        original = snapshot(self.binary)
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.install('--unrestricted').returncode, 0)
        before = snapshot(self.binary)
        self.assertEqual(self.install('--uninstall').returncode, 0)
        for name in ('Sam2017_Unrestricted', 'Sam2017_Unrestricted_real',
                     'fusionfix-unrestricted.dylib', '.fusionfix-unrestricted-state'):
            self.assertEqual(snapshot(self.binary)[name], before[name])
        self.assertEqual(self.install('--unrestricted', '--uninstall').returncode, 0)
        self.assertEqual(snapshot(self.binary), original)

    def test_unrestricted_repeat_install_preserves_backup(self):
        self.add_unrestricted_original()
        self.assertEqual(self.install('--unrestricted').returncode, 0)
        before = snapshot(self.binary)
        self.assertNotEqual(self.install('--unrestricted').returncode, 0)
        self.assertEqual(snapshot(self.binary), before)

    def test_unrestricted_publish_failures_preserve_both_originals(self):
        self.add_unrestricted_original()
        self.assertEqual(self.install().returncode, 0)
        before = snapshot(self.binary)
        for target in ('library', 'wrapper', 'state'):
            with self.subTest(target=target):
                result = self.install('--unrestricted', FAIL_MOVE=target)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('original executable restored', result.stderr)
                self.assertEqual(snapshot(self.binary), before)

    def test_unrestricted_wrapper_uses_matching_original_and_arguments(self):
        wrapper = self.binary / 'Sam2017_Unrestricted'
        shutil.copy2(REPO / 'Sam2017.wrapper.sh', wrapper)
        real = self.binary / 'Sam2017_Unrestricted_real'
        real.write_text('#!' + sys.executable + '\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n')
        real.chmod(0o755)
        args = ['mod argument', '$(literal)', 'quote\"\'']
        result = subprocess.run([str(wrapper), *args], text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), args)


if __name__ == '__main__':
    unittest.main(verbosity=2)
