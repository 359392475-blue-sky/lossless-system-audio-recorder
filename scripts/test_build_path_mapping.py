"""Exercise the build script's compiler flags without packaging or signing an app."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BuildPathMappingTests(unittest.TestCase):
    def test_real_swift_diagnostics_and_debug_metadata_hide_local_paths(self):
        compiler = shutil.which("swiftc")
        if not compiler:
            self.skipTest("swiftc is required for the compiler integration check")
        with tempfile.TemporaryDirectory(prefix="path-check-", dir=str(ROOT)) as source_dir, \
                tempfile.TemporaryDirectory(prefix="scratch path-check-") as scratch_dir, \
                tempfile.TemporaryDirectory(prefix="build-command-check-") as harness_dir:
            harness = Path(harness_dir)
            capture = harness / "arguments.json"
            # Stop on the first build invocation: no app output or signing commands run.
            fake_swift = harness / "swift"
            fake_swift.write_text("#!" + sys.executable + "\n"
                                  "import json, os, sys\n"
                                  "with open(os.environ['BUILD_ARGS_CAPTURE'], 'w') as f:\n"
                                  "    json.dump(sys.argv[1:], f)\n"
                                  "sys.exit(42)\n")
            fake_swift.chmod(0o755)
            fake_python = harness / "python3"
            fake_python.write_text("#!/bin/sh\nexit 0\n")
            fake_python.chmod(0o755)
            env = dict(os.environ, PATH=str(harness) + os.pathsep + os.environ["PATH"],
                       BUILD_ARGS_CAPTURE=str(capture),
                       LOSSLESS_RECORDER_SCRATCH_DIR=scratch_dir,
                       LOSSLESS_RECORDER_OUTPUT_DIR=str(harness / "unused-app"))
            result = subprocess.run(["zsh", str(ROOT / "scripts/build-app.sh")], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 42)
            self.assertFalse((harness / "unused-app").exists())
            args = json.loads(capture.read_text())
            compiler_args = [args[i + 1] for i, arg in enumerate(args) if arg == "-Xswiftc"]
            for directory, public_prefix in ((Path(source_dir), "/source/LosslessSystemAudioRecorder/"),
                                             (Path(scratch_dir), "/build/LosslessSystemAudioRecorder/")):
                with self.subTest(source=public_prefix):
                    source = directory / "main.swift"
                    source.write_text("print(#file)\n")
                    executable = harness / "path-probe"
                    subprocess.run([compiler, "-module-name", "PathProbe", "-swift-version", "5", "-g", *compiler_args, str(source), "-o", str(executable)],
                                   check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    actual = subprocess.check_output([str(executable)], text=True).strip()
                    self.assertEqual(actual, "PathProbe/main.swift")
                    binary = executable.read_bytes()
                    self.assertNotIn(str(ROOT).encode(), binary)
                    self.assertNotIn(str(Path(scratch_dir).resolve()).encode(), binary)


if __name__ == "__main__":
    unittest.main()
