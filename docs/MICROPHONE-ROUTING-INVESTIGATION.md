# Two Bluetooth audio devices: unresolved routing failure

Status: not fixed; last physical-device reproduction is Agent Relay 1.0.43 (44), iOS 26.7.3, 2026-11-18 05:02:32–05:03:01 UTC (13:02:32–13:03:01 UTC+8).

Additional user evidence: WeChat voice messages default to DJI while both audio devices are connected. This rules out a blanket claim that the device pair cannot coexist, but does not establish WeChat's private audio configuration or prove an identical LCK background capture path is supported.

1.0.44 real-device result, 2026-11-18 07:24–07:26 UTC: the foreground/default-mode/no-LCK comparison also failed twice. Both inputs were available, preferredInput returned the DJI UID, and actual input/output remained Baseus throughout both five-second captures. LCK activation logged callbackIsShared=true, ruling out distinct callback/shared AVAudioSession objects for this reproduction. Neither switching capture backend, changing request timing, nor using the callback session has fixed routing. These failures still share category playAndRecord and options=44.

1.0.45 adds diagnostic-only profiles; the normal watch call configuration is unchanged. Baseline is playAndRecord/default/options44; hfpOnly is playAndRecord/default/options4; inputOnly is record/default/options4. Each runs for five seconds, stops on loss of foreground, restores the previous category, and writes only a separate local file. Record category suppresses playback during the test. A successful inputOnly result must not be extrapolated to LCK background activation without another real-device test. These are controlled comparisons, not a declared fix or a reconstruction of WeChat's undocumented implementation.

1.0.44 diagnostic comparison: use the session supplied by LCK didActivate for routing and log its identity against sharedInstance. Add a five-second foreground/default-mode/no-LCK capture using the same PCM writer and the user's saved UID. The comparison writes a separate local file, does not create/send an Agent message, refuses overlap with a system call, and stops on loss of foreground. Compare this against the regular watch/LCK path. This is a diagnostic tool, not a replacement for unattended lock-screen operation.

## Required behavior

Configure a microphone once. Keep both the selected microphone and Bluetooth earbuds connected. A watch BLE command must start phone-side recording while locked, using the selected microphone. No repeated phone interaction or accessory disconnection is an acceptable final solution. Simultaneous output to a different Bluetooth device is a separate requirement and has not been confirmed by the user.

## Confirmed observations

- Selected microphone: DJI Mic Mini 2-3BDCEE, HFP input UID `9C:5A:8A:3B:DC:EE-tsco`.
- Competing device: Baseus Bass BC1, HFP input UID `41:BB:00:EA:3B:FE-tsco`.
- The app persists the selected UID and finds both devices in `availableInputs`.
- Selecting DJI with the native iOS 26 AVInputPickerInteraction can change the input successfully.
- Disconnecting Baseus allows DJI recording to work. This correlates the failure with the two-device configuration; it does not prove which component initiates the change.
- AVAudioRecorder startup-time and post-start preferred-input requests did not restore DJI when Baseus was present.
- Switching the ASK/LCK capture implementation to AVAudioEngine did not resolve the observed two-device failure.
- Both foreground and background tests are relevant; the latest failing capture was foreground (`UIApplication.State.active`, raw value 0). Do not label this solely a lock-screen restriction.

## Latest failing sequence

1. 05:02:32: watch command creates an LCK conversation.
2. 05:02:34: didActivate; route initially reports DJI. Both Bluetooth HFP inputs are available. Requesting DJI returns without an error.
3. 05:02:34: the next input snapshot already reports Baseus, before the new capture backend reports startup.
4. 05:02:35: `Audio capture backend=AVAudioEngine activation=system-managed` proves the new implementation is running.
5. 05:02:35: route notifications report reason 4 (override) and reason 1 (new device available), with Baseus as actual input.
6. 05:02:35–37: three bounded post-I/O requests still report Baseus. Frame progress proves capture is running, not that the requested microphone is active.
7. 05:03:00: approximately 25.5 seconds are sealed into a local file.
8. 05:03:13: server accepts the message. Upload success is separate from input-source correctness.

The diagnostics header shows the currently installed app version, while retained log lines may predate its installation. In particular, the earlier 04:31/04:42 captures lack the new backend marker and cannot validate AVAudioEngine behavior.

## Hypotheses still requiring evidence

- System call-route selection or accessory-originated HFP events supersede the app's preferred-input request.
- The callback audio session and AVAudioSession.sharedInstance() may have different ownership/state. Current code uses the shared instance for selection. Check object identity and both session snapshots before changing routing behavior or asserting that the public API cannot work.
- The failing route may be chosen before capture starts; the latest timeline does not justify blaming AVAudioEngine startup alone.
- After Bluetooth reconnect, a connected accessory may not yet appear as a routable input. An instantaneous absence from availableInputs must not be described as proof that the accessory is unpaired or disconnected.

Do not treat any hypothesis as an established platform limitation.

## Next diagnostic evidence

Capture a fresh iPhone sysdiagnose immediately after a two-device failure, preserving the exact UTC/local failure time. Inspect only relevant callservicesd, audio routing/audiomxd, mediaserverd and Bluetooth events near the failure. Determine the session and origin of the route-selection request. The older 2026-11-16 sysdiagnose predates these microphone reproductions and cannot establish their cause.

Do not send diagnostic archives, post an Apple Feedback report, or upload them to a third party without explicit authorization. A draft report can be prepared locally.

## Sources and limits

- [Apple preferred-input contract](https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferredinput(_:)): a request, with actual routing verified using currentRoute; it initiates a route change when the app's session controls routing.
- [Apple microphone selection Q&A](https://developer.apple.com/library/archive/qa/qa1799/): Bluetooth HFP input and output are coupled for this routing API. This does not by itself prove that two connected devices cannot coexist or that iOS 26 input-picker behavior is identical.
- [LCK didActivate callback](https://developer.apple.com/documentation/livecommunicationkit/conversationmanagerdelegate/conversationmanager(_:didactivate:)): supplies the audio session that activated.
- [Apple DTS guidance for system-managed audio](https://developer.apple.com/forums/thread/804205): discusses AVAudioRecorder activation and recommends AVAudioEngine in a related PTT/CallKit scenario. It motivated the implementation change; the new real-device result shows that change alone is insufficient here.

## Regression requirements

Keep the approved BLE recovery baseline and working single-microphone recording intact. Verify actual input, pause/resume concatenation, durable file finalization, release on end, lock-screen startup, cold recovery, and two-device behavior separately. Do not claim a routing fix from compile/tests, frame growth or server acceptance alone.
