#!/usr/bin/env python3
"""SIGKILL a voice client after real local REST create, then reconcile against SQLite.

Uses production Swift persistence/flow/APIClient and the real server with a disposable database.
No model credentials, simulator or remote server; the owned server always stops at test exit.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import sqlite3
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import wave

from test_voice_process_recovery import ROOT, build_probe

PROBE = None
SERVER_PYTHON = None


class VoiceWireRecoveryTests(unittest.TestCase):
    @staticmethod
    def stop(child):
        if child.poll() is None:
            child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=5)

    def test_lost_create_response_and_process_death_patch_one_note(self):
        with tempfile.TemporaryDirectory(prefix="command-voice-wire-") as temporary:
            directory = Path(temporary)
            db = directory / "command.db"
            log = directory / "server.log"
            # Inherit no application/model credentials and load no worktree .env file.
            env = {name: os.environ[name] for name in ("PATH", "HOME", "TMPDIR", "LANG") if name in os.environ}
            env.update(COMMAND_DB_PATH=str(db), COMMAND_COOKIE_SECURE="false",
                       COMMAND_ENVIRONMENT="dev", COMMAND_MAX_LLM_SENDS_BEFORE_OPEN="0")
            with socket.socket() as listener, log.open("w") as output:
                listener.bind(("127.0.0.1", 0))
                listener.listen()
                server_url = f"http://127.0.0.1:{listener.getsockname()[1]}"
                server = subprocess.Popen([str(SERVER_PYTHON), "-m", "uvicorn", "command.app:app",
                    "--fd", str(listener.fileno()), "--workers", "1"], cwd=directory, env=env,
                    pass_fds=(listener.fileno(),), stdout=output, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 20
                    while True:
                        try:
                            with urllib.request.urlopen(server_url + "/api/health", timeout=0.3) as response:
                                self.assertEqual(response.status, 200)
                            break
                        except (urllib.error.URLError, TimeoutError):
                            if server.poll() is not None or time.monotonic() > deadline:
                                self.fail("Disposable server failed readiness: " + log.read_text()[-2000:])
                            time.sleep(0.05)
                    with wave.open(str(directory / "recording.wav"), "wb") as audio:
                        audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(16000)
                        audio.writeframes(b"\0\0" * 1600)
                    observation = directory / "observation.json"
                    with (directory / "client.log").open("w") as client_output:
                        child = subprocess.Popen([str(PROBE), "wire-seed", str(directory), server_url],
                                                 stdout=client_output, stderr=subprocess.STDOUT)
                        try:
                            deadline = time.monotonic() + 15
                            while not observation.exists() and child.poll() is None and time.monotonic() < deadline:
                                time.sleep(0.01)
                            self.assertTrue(observation.exists(), "Client failed checkpoint: " +
                                            (directory / "client.log").read_text()[-2000:])
                            before = json.loads(observation.read_text())
                            self.assertEqual(before.get("checkpoint"), "server-committed-before-flow-ack", before)
                            with sqlite3.connect(db) as connection:
                                initial = connection.execute("SELECT id, body, source, engine, locale, idempotency_key FROM notes").fetchall()
                            self.assertEqual(initial, [(int(before["noteID"]), "Original voice capture", "voice",
                                                       "sfspeech", "en-US", before["key"])])
                            manifests = list((directory / "recovery").glob("*/*/manifest.json"))
                            self.assertEqual(len(manifests), 1)
                            self.assertIsNone(json.loads(manifests[0].read_text()).get("savedNoteID"))
                            child.kill(); child.wait(timeout=5)
                            self.assertEqual(child.returncode, -signal.SIGKILL)
                        finally:
                            self.stop(child)
                    observation.unlink()  # Relaunch cannot use the external observer as persistence.
                    subprocess.run([str(PROBE), "wire-reconcile", str(directory), server_url],
                                   check=True, capture_output=True, text=True, timeout=15)
                    after = json.loads(observation.read_text())
                    self.assertNotEqual(before["pid"], after["pid"])
                    self.assertEqual(after["key"], before["key"])
                    self.assertEqual(after["createBody"], "Original voice capture")
                    self.assertEqual(after["createLocale"], "en-US")
                    self.assertEqual(after["patchedID"], before["noteID"])
                    self.assertEqual(after["saved"], "true", after)
                    self.assertEqual(after["remaining"], "0")
                    self.assertFalse(Path(before["audio"]).exists())
                    with sqlite3.connect(db) as connection:
                        final = connection.execute("SELECT id, body, source, engine, locale, idempotency_key FROM notes").fetchall()
                    self.assertEqual(final, [(int(before["noteID"]), "Later voice review edits", "voice",
                                             "sfspeech", "en-US", before["key"])])
                    print("OBSERVED SQLite: one voice note, original key/locale, later review body, audio removed")
                    print("OBSERVED HTTP:\n" + "\n".join(line for line in log.read_text().splitlines()
                                                               if ' /api/notes' in line))
                finally:
                    self.stop(server)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True, help="Owned dd-lease directory")
    parser.add_argument("--server-python", type=Path, default=ROOT / "server/.venv/bin/python")
    args = parser.parse_args()
    PROBE = build_probe(args.build_dir)
    SERVER_PYTHON = args.server_python.absolute()
    unittest.main(argv=[__file__], verbosity=2)
