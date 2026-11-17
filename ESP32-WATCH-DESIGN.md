# ESP32 watch: implementation contract and validation plan

Status: proposed design, not implemented firmware. Baseline tag: v1.0.33-user-approved-ble-recovery (53c8448). User confirmed recording after hours offline and PC power cycle with encrypted mock.

## Hardware references

- https://docs.waveshare.net/ESP32-S3-Touch-AMOLED-2.06/
- https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-2.06
- https://www.waveshare.net/w/upload/8/8b/ESP32-S3-Touch-AMOLED-2.06.pdf
- BOOT GPIO0 active low; PWR GPIO10 active high. PWR held approximately 6 seconds powers off. Proposed application long press: 1.2 seconds, once per hold; suppress short press after a long press. Verify on physical board.
- Schematic identifies GPIO18 MOTOR; verify motor population, drive polarity and power initialization against vendor example before enabling.
- Use vendor ESP-IDF board support for power/display; phone microphone remains the only recording source.

## Distinct state dimensions

Do not conflate BLE connection, iOS LCK conversation, backend Agent conversation, recording draft and upload status.
Phone owns recording truth. Snapshot includes phone process epoch, monotonically increasing revision, draft ID, logical session ID, capture state (idle/starting/recording/paused/finalizing), upload state and error. Backend ID may be absent until first upload succeeds.
Watch begins unknown after boot/disconnect. After encrypted connection and notification subscription, request snapshot. Never persist a local recording Boolean as authoritative truth.

## Gestures

| Gesture | Authoritative phone state | Requested result |
| --- | --- | --- |
| BOOT long | idle | start draft; create LCK conversation if needed; reuse open logical Agent session |
| BOOT long | recording or paused draft | finalize and durably enqueue one message; preserve logical session |
| BOOT short | recording | pause draft without sending |
| BOOT short | paused draft | resume same draft |
| BOOT short | idle | no recording; display state |
| PWR long | any | finalize nonempty draft, seal logical session, end LCK; next draft gets a new logical session |

During unknown/busy state, synchronize or report busy rather than queue alternating gestures. Request carries expected epoch/revision and draft/session IDs. Phone atomically validates before mutation; stale request returns current snapshot without side effect. Use unique command ID, bounded expiry and idempotent retries of that same request. At most one in-flight state-changing request. No backlog of historical toggle commands. If the request expires before reconnect, report failure and require a fresh gesture.

If ACK is lost, query snapshot/result; do not reverse the gesture or manufacture a new command ID. Phone UI actions, interruption, process death and reboot invalidate stale revisions. Recover finalized segments as interrupted draft; never claim capture continued through process death or power loss. If phone cannot be reached, watch reports unknown/unreachable, not success.

Haptics acknowledge actual phone-confirmed transition: start only after audio frames grow; paused only after capture stops; saved locally distinct from server accepted. Failed/timeout uses a different pattern. Reception ACK is not execution success. Design patterns must be tested for recognizability.

## Pause and file durability

Current pauseAndSend stops and submits; it is not the requested pause. AVAudioRecorder pause()/record() supports ordinary same-file pause/resume, but background LCK reactivation and crash recovery need separate verification.
Preferred durable design: close a segment on pause, store ordered segments and draft manifest in Application Support, start a new segment on resume, then export one continuous audio file without pause gaps. Freeze sample format or convert explicitly. Preserve originals until export validation and durable upload acceptance. Test recording/paused/finalizing independently and adjust current wall-time validity check to exclude pauses.
Avoid holding audio capture active simply to keep the process alive. Test reactivation after a long pause and interaction with WeChat. Keeping logical Agent history does not require falsely treating a paused OS call as fully released.

## Offline delivery

Baseline immediate LCK start skips gateway preflight, but requires cached login cookie and OS permissions. Recording and BLE do not inherently require Tailscale. Current gateway upload does require a reachable configured gateway, including VPN when that route requires it.
Current code saves recordings but uses URLSession.shared.dataTask and in-memory conversation association; it has no durable delivery journal. Do not promise automatic recovery today.
Persist audio + destination + logical session + message UUID + ordering before reporting saved. Retry on available execution/network opportunities, including app/BLE wake; never promise unlimited background execution. File-based background upload requires compatible server request format and authentication handling. Server must deduplicate by stable message UUID and resolve a durable client logical session to one backend conversation atomically. A new session must never inherit an old upload response. Distinguish local saved, gateway accepted, Agent attachment available and Agent processed. Expired login/storage-full/export failure must remain visible and retryable.
Sudden power loss can still lose the active unflushed tail; periodic finalized segments reduce exposure but cannot guarantee zero loss.

## BLE recovery contract

Persist device identity, bonding/security keys and any privacy resolution material used in NVS across normal boots, firmware updates and battery loss. Do not erase NVS on ordinary startup. Reset pairing is an explicit operation. Encrypted GATT access and a static application UUID alone do not prove identity resolution is correct.
Watch is peripheral: advertise on boot and disconnect; iPhone central initiates GATT connection. Reconnect automatically using saved authorization/identity, with no picker in the normal path. Mirror proven service UUIDs where compatible, but version the extended state protocol so old START/STOP packets cannot be misinterpreted.

## Acceptance gates

1. Vendor power/button/motor demo; preserve stock firmware recovery instructions; no flash before board connection/port identified.
2. Encrypted GATT, ASK pairing, state snapshot and one start/send round on phone builtin mic.
3. Pause/resume multiple segments -> one message, expected duration, no long gaps; same-session ordering and explicit new-session boundary.
4. Duplicate/lost ACK, stale commands, rapid gestures, phone-side end, watch reset during recording, phone kill/reboot, disconnected stop and long pause.
5. Wi-Fi/cellular unavailable, VPN off, expired authentication, interrupted upload, app relaunch, duplicate retry and storage full; verify server attachment bytes and conversation placement.
6. Battery removal/full depletion, complete reboot, repeated power cycles, hours offline while phone used, phone first unlock, screen locked, process restoration; no re-add and correct recording acknowledgment.
7. WeChat voice playback/microphone after pause/send/end, calls and audio interruptions. Baseline held LCK call can block WeChat; do not mark fixed without real-device evidence.

## Review of Gemini document (2026-11-17)

Read via read-only Agent Relay SQLite queries and SSH file access. Conversation 29659080-a10c-4e03-9741-0a7f76cab62d points to /home/complicated/project/agent-relay-next/docs/esp32-wearable-watch-integration-design.md. Also found another Codex conversation 941aef0d-70ec-4ca7-b7c9-2543625fef45 which had begun work from that document; do not overwrite its work without inspecting its current branch/diff.

Corrections required before implementation:

- Document calls v1.0.9-wearable-verified / 82296f1 the baseline. This user's approved ASK 1.0.33 (34) baseline is 53c8448 and v1.0.33-user-approved-ble-recovery. Do not import unrelated audio policy changes from the old baseline.
- GATT direction is reversed: with watch peripheral/GATT server and phone central/client, watch button events are readable/notifiable server characteristics subscribed by phone; phone sends state/results by writing a watch characteristic. The watch cannot use a client WriteWithoutResponse to send a command to its own server. Preserve proven A8D702xx service compatibility or explicitly version/migrate ASK discovery and both endpoints together; proposed FFF0 is not a drop-in replacement.
- LCK is not an absolute process-lifetime guarantee; BLE wake does not alone guarantee permission to activate microphone. Preserve proven ASK + restoration + LCK activation ordering.
- AAC is lossy. 16 kHz does not establish losslessness or universal high fidelity. No measured basis for exactly 10 seconds or 80 percent recognition latency savings; verify encoded duration and actual model charging rules.
- Current upload failures retain recording files; missing automatic retry journal is not equivalent to deleting all failed audio.
- NWPathMonitor satisfied is not gateway/VPN reachability and does not wake a terminated app by itself. Durable retry and idempotency/session mapping remain necessary. HTTP 200 alone is insufficient without a valid durable server acceptance response.
- Missing key baseline lessons: encrypted GATT, durable bonding/identity, battery loss recovery, no re-add, command ID/expiry/state revision, ACK loss and duplicate suppression. A generic shared service UUID or app-level device ID cannot replace bonding identity.
- Disconnected and idle are separate states. Not every transient disconnect proves phone recording stopped. Do not disable the wake/reconnect path merely because the app process is absent; successful process restoration is already observed.
- PWR document asserts user-measured 8 seconds and absolute safety; provenance is unverified here. Vendor states about 6 seconds. Verify actual board/PMU configuration; application threshold must precede hardware shutdown.
- Unconditional watchdog resume after interruptions can restart recording against current intent. Reconcile draft identity, user intent and actual OS activation before resuming.

Useful ideas retained: phone-authoritative state, confirmation-based haptics, initial reconnect snapshot, pause/resume, durable Outbox, explicit same/new Agent conversation boundary. These are requirements, not evidence they are already implemented.
