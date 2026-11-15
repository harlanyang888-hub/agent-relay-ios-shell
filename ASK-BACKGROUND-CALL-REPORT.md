# iOS 18.6.1: background outgoing LCK conversation rejected after an ASK-authorized BLE button notification

## Environment

iPhone 11, iOS 18.6.1 (22G90). LiveCommunicationKit + CoreBluetooth. Same application identifier, Xcode 16.4 (16F6), iOS 18.5 SDK, minimum iOS 15. Background modes: audio, voip, bluetooth-central. Microphone access granted.

Legacy 1.0.24 (25) and ASK 1.0.25 (26) executable SHA256 are identical: `7515144e0de23f284334a66d0f71d8e11789491549fdc55aea0137e83d8cbc0a`. Differences are version values, ASK Info.plist declarations, and the runtime ASK flag. Both execute the same outgoing conversation and recording implementation.

## Reproduction

1. Authorize a dedicated GATT peripheral using ASAccessorySession. Connect and subscribe to the custom notification characteristic using CBCentralManager. It is a dedicated button protocol, not a media key.
2. Grant microphone access. Do not establish a system conversation in advance.
3. Background/lock the application. Send a button START command from the connected peripheral.
4. In the notification handler, start a finite UIApplication background task and perform a fresh StartConversationAction with a unique conversation UUID and generic handle.

Expected: the explicit accessory button requests the application's voice interaction, as in the ordinary CoreBluetooth configuration. Alternatively, please clarify the supported method to convey this hardware user intent to the call-management system.

Actual: the BLE notification and execution receipt work, but the outgoing action fails with `com.apple.CallKit.error.requesttransaction` code 6. No audio session activation or recording follows.

## Controlled observations

- Ordinary CoreBluetooth configuration starts in background and records/uploads successfully.
- ASK configuration starts successfully in foreground and resumes an existing paused conversation in background.
- ASK configuration fails to create a new conversation in background even in the same process after a foreground conversation has fully ended. This excludes a cold-restoration-only explanation.
- Removing the asynchronous network preflight does not fix it. In 1.0.27 (28), perform starts within 161/209 ms; rejection arrives at 225/305 ms. Manager didBegin received, conversation count zero, background task requested, microphone permission granted.
- We do not claim that an iOS 26 update resolves this. The documented ASK Bluetooth relaunch rules address process restoration, not this outgoing-action authorization result.

## System evidence

Provided sysdiagnose: `sysdiagnose_2026.11.16_00-30-30+0800_iPhone-OS_iPhone_22G90.tar.gz`. Relevant local time 2026-11-16 00:30:08 +0800 (UTC 2026-11-15 16:30:08), app PID 30713, callservicesd PID 30245.

1. 16:30:08.503781632Z callservicesd receives the transaction.
2. 16:30:08.535679232Z tccd records callservicesd checking `kTCCServiceBluetoothAlways` for the Agent Relay process, request `30245.7`.
3. 16:30:08.537494784Z this request returns `authValue=1, authReason=0, error=(null)`. App-side CBManager.authorization is `.notDetermined` (raw 0), while ASK accessory communication works.
4. 16:30:08.543332864Z callservicesd's media playback-state query returns Paused.
5. 16:30:08.547083008Z callservicesd logs: `[WARN] Not allowing requested CXStartCallAction because user intent could not be validated for call source with identifier: <private>`.
6. 16:30:08.550520832Z requested transaction rejected. The app receives error 6.
7. System call-source registration reports `hasVoIPBackgroundMode: 1` and `supportsCurrentPlatform: 1`.

The same rejection and preceding TCC check also occur at 16:21:26 and 16:21:29 UTC.

## What is and is not established

The immediate system rejection is **user-intent validation**, not missing BLE delivery, microphone denial, absent voip background mode, a full conversation group, network delay, or a failed upload. The permission-check sequence is strong evidence to investigate interaction between ASK-scoped access and callservicesd's legacy Bluetooth/user-intent validation. The internal predicates are privacy-redacted, so the sysdiagnose alone does not prove which exact predicate is false or establish a supported fix.

No private APIs, fabricated incoming calls, media playback keepalive, or automatic pre-established system conversation are used to bypass the result. This report has not been submitted externally.
