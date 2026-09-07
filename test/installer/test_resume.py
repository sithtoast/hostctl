"""Exercise the standalone installer helpers without installing host services."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[2] / "priv/deploy/install.sh"
HELPERS = INSTALLER.read_text().split("# --- Begin installation")[0]


class ResumeTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hostctl-installer-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.env = dict(os.environ, HOSTCTL_INSTALL_STATE_DIR=str(self.root / "state"))

    def run_shell(self, script, success=True):
        # flock is a Linux dependency. Replace only locking in these portable
        # tests; all serialization, parsing, and file operations are real.
        result = subprocess.run(
            ["bash", "-c", HELPERS + '\nflock() { return 0; }\n' + script],
            env=self.env, capture_output=True,
        )
        self.assertEqual(result.returncode == 0, success, result.stderr.decode())
        return result

    def test_choices_secrets_and_overrides_survive_a_new_process(self):
        self.run_shell("""
initialize_state
parse_arguments --domain=panel.example.test --repo=https://example.test/repo.git \
  --branch=testing --db-flavor=mariadb --cloudflare --skip-php --yes
DB_PASSWORD='quote " and dollar $(touch SHOULD_NOT_EXIST)'
MYSQL_ROOT_PASSWORD=first-root-secret
POSTGRES_ROOT_PASSWORD=second-root-secret
SECRET_KEY_BASE=stable-encryption-key
INITIAL_SETUP_TOKEN=stable-setup-token
LOG_FILE=$'a log path\nwith newline'
save_choices
step 'Downloading prerequisites'
""")
        self.run_shell("""
initialize_state
load_choices
[[ "$DOMAIN" == panel.example.test && "$MYSQL_FLAVOR" == mariadb ]]
[[ "$REPO_BRANCH" == testing && "$CLOUDFLARE_PROXY" == true ]]
[[ "$DB_PASSWORD" == 'quote " and dollar $(touch SHOULD_NOT_EXIST)' ]]
[[ "$MYSQL_ROOT_PASSWORD" == first-root-secret ]]
[[ "$POSTGRES_ROOT_PASSWORD" == second-root-secret ]]
[[ "$SECRET_KEY_BASE" == stable-encryption-key && "$INITIAL_SETUP_TOKEN" == stable-setup-token ]]
[[ "$LOG_FILE" == $'a log path\nwith newline' ]]
[[ "$LAST_STEP" == 'Downloading prerequisites' ]]
[[ "$ASSUME_YES" == false && "$INTERACTIVE" == false ]]
parse_arguments --domain=new.example.test --resume --skip-php=false --cloudflare=false
[[ "$DOMAIN" == new.example.test && "$SKIP_PHP" == false && "$CLOUDFLARE_PROXY" == false ]]
[[ ! -e SHOULD_NOT_EXIST ]]
""")
        self.assertEqual((self.root / "state").stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.root / "state/choices").stat().st_mode & 0o777, 0o600)

    def test_missing_state_is_actionable(self):
        result = self.run_shell("initialize_state; load_choices", success=False)
        self.assertIn(b"Run the installer normally first", result.stderr)
        self.assertNotIn(b"Choices saved", result.stdout)

    def test_truncated_or_unknown_state_is_rejected(self):
        for payload in (b"HOSTCTL_INSTALL_STATE_V1\0DOMAIN\0", b"HOSTCTL_INSTALL_STATE_V1\0PATH\0bad\0"):
            self.run_shell("initialize_state; save_choices")
            (self.root / "state/choices").write_bytes(payload)
            self.run_shell("initialize_state; load_choices", success=False)

    def test_invalid_saved_boolean_is_rejected(self):
        self.run_shell("initialize_state; save_choices")
        path = self.root / "state/choices"
        path.write_bytes(path.read_bytes().replace(b"SKIP_PHP\0false\0", b"SKIP_PHP\0maybe\0"))
        self.run_shell("initialize_state; load_choices", success=False)

    def test_failed_step_leaves_choices_and_retry_instructions(self):
        result = self.run_shell("""
initialize_state
DOMAIN=panel.example.test
save_choices
step 'Installing Docker'
exit 23
""", success=False)
        self.assertEqual(result.returncode, 23)
        self.assertIn(b"Installing Docker", result.stdout)
        self.assertIn(b"--resume", result.stdout)
        self.assertTrue((self.root / "state/choices").is_file())

    def test_lock_failure_does_not_overwrite_saved_choices(self):
        self.run_shell("initialize_state; DOMAIN=keep.example.test; save_choices")
        path = self.root / "state/choices"
        previous = path.read_bytes()
        self.run_shell("flock() { return 1; }; initialize_state; save_choices", success=False)
        self.assertEqual(path.read_bytes(), previous)

    def test_download_retry_does_not_reuse_partial_files(self):
        self.run_shell("""
initialize_state
mkdir -p "$DOWNLOAD_DIR"
curl() { printf partial > "$3"; return 1; }
if cached_download https://example.test/archive "$DOWNLOAD_DIR/archive"; then exit 1; fi
[[ ! -e "$DOWNLOAD_DIR/archive" ]]
curl() { printf complete > "$3"; }
cached_download https://example.test/archive "$DOWNLOAD_DIR/archive"
[[ "$(cat "$DOWNLOAD_DIR/archive")" == complete ]]
curl() { exit 99; }
cached_download https://example.test/archive "$DOWNLOAD_DIR/archive"
""")

    def test_help_does_not_require_root_or_create_state(self):
        result = subprocess.run(["bash", str(INSTALLER), "--help"], env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"--resume", result.stdout)
        self.assertFalse((self.root / "state").exists())


if __name__ == "__main__":
    unittest.main()
