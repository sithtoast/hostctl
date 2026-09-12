"""Exercise the wrapper's exact RPC expression with harmless fixture code."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

WRAPPER = Path(__file__).resolve().parents[2] / "scripts/ftp-isolation-smoke"


@unittest.skipUnless(shutil.which("elixir"), "Elixir is required")
class FtpSmokeWrapperTest(unittest.TestCase):
    def expression(self, directory, mode):
        line = next(line for line in WRAPPER.read_text().splitlines()
                    if line.startswith("/opt/hostctl/bin/hostctl rpc "))
        # Expand exactly the same shell quoting/variables without connecting RPC.
        command = line.replace("/opt/hostctl/bin/hostctl rpc ", "printf '%s' ", 1)
        return subprocess.check_output(["bash", "-c", command], text=True,
                                       env=dict(os.environ, state_dir=str(directory), mode=mode))

    def test_all_modes_pass_bindings_and_filename(self):
        with tempfile.TemporaryDirectory(prefix="hostctl-wrapper-") as temporary:
            directory = Path(temporary)
            for mode in ("prepare", "retry", "verify", "cleanup"):
                with self.subTest(mode=mode):
                    (directory / "check.exs").write_text(
                        f'true = Keyword.fetch!(binding(), :mode) == :{mode}\n'
                        'true = Keyword.fetch!(binding(), :directory) == Path.dirname(__ENV__.file)\n'
                        ':ok\n')
                    result = subprocess.run(["elixir", "-e", self.expression(directory, mode)],
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_probe_returns_nonzero(self):
        with tempfile.TemporaryDirectory(prefix="hostctl-wrapper-") as temporary:
            directory = Path(temporary)
            (directory / "check.exs").write_text('{:error, :fixture_failed}\n')
            result = subprocess.run(["elixir", "-e", self.expression(directory, "prepare")],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FTP isolation check failed", result.stderr)
