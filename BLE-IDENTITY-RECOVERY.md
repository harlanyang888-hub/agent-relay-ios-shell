# Windows resume identity investigation — 2026-11-17

Confirmed evidence (phone timestamps UTC; PC timestamps UTC+8):

- PC server remains run `603ea803f0965eda`, PID 5940 across the execution gap of 23829.7 seconds. This is not a server process restart.
- Subscription dropped at 2026-11-17 01:18:55 local, matching iOS Bluetooth disconnect/restore at 2026-11-16T17:18:55Z.
- Opening the phone app did not restore the subscription. An explicit PC stop/start advertising comparison also did not restore it.
- Previous selected CBPeripheral identifier: `CCC80BEE-2F6A-DFAE-AD85-96B989F2F22D`.
- Re-adding via ASK at 2026-11-17T00:25:56Z selected `F1214F40-0A3F-F19A-4817-A44D0DC92883`; connection and subscription succeeded at 00:26:02Z.
- Both connections read application identity `f22c8583d4aa4acb9677197d66cc7af4`.

This establishes an OS-visible identity/binding discontinuity, not a recording or CallKit failure. It does not by itself establish the raw Bluetooth address, whether a Windows controller reset or address rotation caused it, or whether the subsequent advertising comparison affected the new identity.

Existing characteristics use Plain protection; ASK authorization alone is not evidence of a persistent Bluetooth bond. The application UUID is read only after connection, so it cannot enable the OS to reconnect an unknown address while the app is terminated.

Next controlled experiment: run the same server with `--require-encryption`, requiring encrypted access to its characteristics. Verify any pairing prompts, actual encrypted access, and retained pairing records on both hosts before claiming bonding works. Then compare identities after sleep, long idle and true power cycle. Encryption requested is not proof of bonding or IRK exchange, and Windows support must be tested. Do not replace a working live server without recording its state; do not replay pending start commands during transport tests.

ESP32 acceptance: persistent identity and bond keys/IRK where supported, automatic advertising after disconnect and boot, and phone reconnection/subscription without a new ASK picker after power loss. Never treat an arbitrary device with the same name, service UUID or readable application UUID as authenticated.

References:
- https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/BestPracticesForInteractingWithARemotePeripheralDevice/BestPracticesForInteractingWithARemotePeripheralDevice.html
- https://learn.microsoft.com/en-us/uwp/api/windows.devices.bluetooth.genericattributeprofile.gattprotectionlevel
