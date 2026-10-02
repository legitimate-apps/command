#!/usr/bin/env python3
"""Real process-death characterization against copied, unmodified production Swift sources.

Eight crash/relaunch and control cases exercise the opt-in production restore API.
--require-recovery remains compatible with the original failing-baseline invocation. No simulator, microphone or server.
"""
import argparse
import json
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
import wave

ROOT = Path(__file__).resolve().parents[2]
PROBE = None


def build_probe(build_dir):
    package = build_dir / "VoiceRecoveryProcessRepro"
    sources = package / "Sources" / "Probe"
    sources.mkdir(parents=True, exist_ok=True)
    (package / "Package.swift").write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "VoiceRecoveryProcessRepro", platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Probe")])
''')
    for relative in (
        "Transcription/VoiceCaptureFlow.swift", "Transcription/VoiceRecordingRecoveryStore.swift",
        "Networking/CreateAttempt.swift",
        "Widgets/AssistantSurfaceLogic.swift",
    ):
        source = ROOT / "ios/Command" / relative
        shutil.copyfile(source, sources / source.name)
    shutil.copyfile(Path(__file__).with_name("VoiceRecoveryProbe.swift"), sources / "VoiceRecoveryProbe.swift")
    subprocess.run(["swift", "build", "--package-path", str(package), "--jobs", "2"], check=True, timeout=120)
    result = subprocess.run(["swift", "build", "--package-path", str(package), "--show-bin-path"],
                            check=True, capture_output=True, text=True, timeout=30)
    return Path(result.stdout.strip()) / "Probe"


class VoiceProcessRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="command-voice-repro-"))
        self.addCleanup(shutil.rmtree, self.directory)
        self.audio = self.directory / "recording.wav"
        # A valid 16 kHz mono WAV fixture; these tests do not invoke a codec or microphone.
        with wave.open(str(self.audio), "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16000)
            audio.writeframes(b"\0\0" * 1600)
        self.observation = self.directory / "observation.json"
        scenarios = {
            "test_stopped_recording_is_discoverable_after_process_death": "stopped",
            "test_transcribing_recording_is_discoverable_after_process_death": "transcribing",
            "test_review_text_and_engine_survive_process_death": "review",
            "test_uncertain_create_reuses_key_after_process_death": "uncertain",
            "test_later_edits_reconcile_original_request_after_process_death": "uncertain-edited",
        }
        scenario = scenarios.get(self._testMethodName)
        if scenario:
            # Preconditions live in setUp so harness faults CANNOT count as expected failures.
            child = subprocess.Popen([str(PROBE), scenario, str(self.directory)],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.addCleanup(self.stop_child, child)
            deadline = time.monotonic() + 10
            while not self.observation.exists() and child.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(self.observation.exists(), "child failed to reach the requested checkpoint")
            self.before = json.loads(self.observation.read_text())
            self.assertEqual(child.pid, int(self.before["pid"]))
            self.audio = Path(self.before["audio"])
            self.assertTrue(self.audio.is_relative_to(self.directory / "recovery"))
            self.assertTrue(self.audio.exists())
            with wave.open(str(self.audio), "rb") as recovered_audio:
                self.assertEqual(recovered_audio.getnframes(), 1600)
            if scenario == "transcribing":
                self.assertEqual(self.before["checkpoint"], "inside-transcriber")
            if scenario in ("uncertain", "uncertain-edited"):
                self.assertEqual(self.before["checkpoint"], "request-awaiting-response")
                self.assertTrue(self.before["key"])
            if scenario == "review":
                self.assertEqual(self.before["transcript"], "Latest edited review")
                self.assertEqual(self.before["engine"], "sfspeech")
            child.kill()
            child.communicate(timeout=5)
            self.assertEqual(child.returncode, -signal.SIGKILL)
            self.assertTrue(self.audio.exists(), "SIGKILL must bypass all app cleanup callbacks")
            self.after = self.run_probe({"uncertain": "retry", "uncertain-edited": "reconcile"}.get(scenario, "relaunch"))
            self.assertNotEqual(self.before["pid"], self.after["pid"])
            if scenario in ("uncertain", "uncertain-edited"):
                self.assertIsInstance(self.after.get("key"), str)
                self.assertTrue(self.after["key"], "retry must reach the request boundary")

    @staticmethod
    def stop_child(child):
        if child.poll() is None:
            child.kill()
        child.communicate(timeout=5)

    def run_probe(self, mode):
        self.observation.unlink(missing_ok=True)
        subprocess.run([str(PROBE), mode, str(self.directory)], check=True,
                       capture_output=True, text=True, timeout=10)
        value = json.loads(self.observation.read_text())
        for key in ("audio", "transcript", "engine", "pid"):
            self.assertIn(key, value, f"probe observation missing {key}")
            self.assertIsInstance(value[key], str)
        return value

    def test_stopped_recording_is_discoverable_after_process_death(self):
        self.assertEqual(self.after["audio"], str(self.audio))

    def test_transcribing_recording_is_discoverable_after_process_death(self):
        self.assertEqual(self.after["audio"], str(self.audio))

    def test_review_text_and_engine_survive_process_death(self):
        self.assertEqual((self.after["transcript"], self.after["engine"]),
                         ("Latest edited review", "sfspeech"))

    def test_uncertain_create_reuses_key_after_process_death(self):
        self.assertEqual(self.after["key"], self.before["key"])

    def test_later_edits_reconcile_original_request_after_process_death(self):
        self.assertEqual(self.after["key"], self.before["key"])
        self.assertEqual(self.after["createBody"], "Reviewed capture")
        self.assertEqual(self.after["createLocale"], "en-US")
        self.assertEqual(self.after["patchedID"], "7")
        self.assertEqual(self.after["patchedBody"], "Later review edits")
        self.assertEqual(self.after["saved"], "true")
        self.assertEqual(self.after["remaining"], "0")
        self.assertFalse(self.audio.exists())

    def test_failed_save_reuses_key_without_process_death(self):
        result = self.run_probe("same-process-retry")
        self.assertTrue(result["firstKey"])
        self.assertEqual(result["firstKey"], result["secondKey"])
        self.assertTrue(Path(result["audio"]).exists())

    def test_explicit_cancel_removes_recording(self):
        result = self.run_probe("cancel")
        self.assertEqual(result["audio"], "")
        self.assertFalse(self.audio.exists())

    def test_acknowledged_save_removes_recording(self):
        result = self.run_probe("success")
        self.assertEqual(result["audio"], "")
        self.assertFalse(self.audio.exists())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True, help="Owned dd-lease directory")
    parser.add_argument("--require-recovery", action="store_true", help="Fail for known missing durability")
    args = parser.parse_args()
    PROBE = build_probe(args.build_dir)
    if args.require_recovery:
        for name in unittest.defaultTestLoader.getTestCaseNames(VoiceProcessRecoveryTests):
            method = getattr(VoiceProcessRecoveryTests, name)
            if hasattr(method, "__unittest_expecting_failure__"):
                method.__unittest_expecting_failure__ = False
    unittest.main(argv=[__file__], verbosity=2)
