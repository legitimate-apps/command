# Voice process-death reproduction — 2026-10-02

Scope: native test-only subprocesses compile unmodified production voice flow, create-attempt,
and validation source. No production code changed. No app UI, simulator, microphone, or server
was started. The owned native DerivedData lease was released after verification.

Observed after independent review and harness hardening:

```text
$ python3 ios/recovery-repro/test_voice_process_recovery.py --build-dir "$LEASED_DD"
Ran 7 tests in 0.137s
OK (expected failures=4)

$ python3 ios/recovery-repro/test_voice_process_recovery.py --build-dir "$LEASED_DD" --require-recovery
Ran 7 tests in 0.143s
FAILED (failures=4)
```

| Scenario | Before termination | Fresh process observation | Result |
|---|---|---|---|
| Stopped recording | Flow owns existing WAV | No audio URL discovered | Known missing recovery |
| Transcription in flight | Entered held transcriber callback | No audio URL discovered | Known missing recovery |
| Edited review | Latest edited text and sfspeech engine | Empty transcript and engine | Known missing recovery |
| Uncertain create | Request callback has original key | Same re-entered payload obtains a different key | Known missing recovery |
| Same-process failed-save retry | Two failed request callbacks | Same nonempty key; audio retained | Control passes |
| Explicit Cancel | Flow owns audio | Audio deleted | Control passes |
| Acknowledged note save | Flow owns reviewed audio | Audio deleted | Control passes |

All crash cases check the exact SIGKILL exit signal, audio existence after death, and a different
PID on relaunch. JSON shape, engine preconditions, and process/checkpoint errors are validated
outside expected-failure assertions. An unexpected recovery success fails characterization mode.
The worker never reads the observer JSON; Python removes it before launching the next process.

Limits: finalized fixture audio does not prove unfinalized M4A decodability. The request callback
is a simulated unresolved network boundary, not proof of server duplication. Fresh initialization
exercises the current production flow constructor, not real app/bootstrap/account restoration.
The probe must call the future production coordinator when it exists. See
[design contract](../../../docs/decisions/2026-10-02-voice-recovery.md) and
[harness instructions](../../../ios/recovery-repro/README.md).

Raw local logs remain at `/tmp/command-astra-1002/voice-process-characterization.log` and
`/tmp/command-astra-1002/voice-process-required.log`. The above outcome is a confirmed test-first
baseline, **not an implemented or passing crash-recovery feature**.
