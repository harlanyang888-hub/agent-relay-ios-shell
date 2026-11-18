import Foundation

func check(_ condition: @autoclosure () -> Bool, _ detail: String) {
    guard condition() else { fatalError(detail + "\n" + DeviceDiagnostics.shared.lines.suffix(20).joined(separator: "\n")) }
}
func settle(_ seconds: Double = 0.15) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
func command(_ sequence: UInt32, seconds: Double = 8) -> BLELabCommand {
    var data = Data([65,82,2,1]); data.watchAppend(UInt32(123)); data.watchAppend(sequence)
    data.watchAppend(UInt32(Date().timeIntervalSince1970 + seconds))
    return BLELabCommand(data)!
}

@main struct LifecycleTests {
    @MainActor static func main() async {
        let voice = VoiceConversationProbe.shared
        let service = WearableService.shared
        await settle()

        // Regression: an ASK start must work without login/VPN even when the
        // old diagnostic preference would request a slow network preflight.
        service.authCookie = nil
        var results: [Bool] = []
        voice.executeLabCommand(command(1)) { ok, _ in results.append(ok) }
        await settle()
        let firstManager = ConversationManager.instances.last!
        let firstCall = voice.callUUID!
        check(firstManager.actions.contains { $0 is StartConversationAction }, "Offline ASK start did not reach system")
        check(!DeviceDiagnostics.shared.lines.contains { $0.contains("preflight-complete") }, "ASK used network preflight")
        firstManager.activate(); await settle()
        service.capturedRecordingDuration = 1.2
        await settle(0.6)
        check(results == [true] && service.isRecording, "Real capture confirmation did not finish start")

        // A delayed End/Pause for another call must never stop the live call.
        let staleEnd = EndConversationAction(conversationUUID: UUID())
        voice.conversationManager(firstManager, perform: staleEnd)
        voice.conversationManager(firstManager, perform: PauseConversationAction(conversationUUID: UUID(), isPaused: true))
        await settle()
        check(voice.callUUID == firstCall && service.isRecording && staleEnd.fulfilled, "Stale system action affected current capture")

        // Phone hang-up, then an immediate new watch press while audio is still
        // releasing. New capture waits for release; old manager callbacks are fenced.
        voice.endSystemConversationKeepingWatchDraft(); await settle()
        check(voice.callUUID == nil && !service.isRecording && !voice.audioReleaseConfirmed, "Phone end didn't close capture")
        voice.executeLabCommand(command(2)) { ok, _ in results.append(ok) }
        await settle()
        check(voice.callUUID == nil, "New call raced old audio release")
        firstManager.deactivate(); await settle(0.4)
        let secondManager = ConversationManager.instances.last!
        check(secondManager !== firstManager && voice.callUUID != nil, "Call did not recover after release")
        secondManager.activate(); await settle()
        service.capturedRecordingDuration = 1.2
        await settle(0.6)
        firstManager.deactivate(); voice.conversationManagerDidReset(firstManager)
        await settle()
        check(results == [true,true] && service.isRecording && voice.audioActive, "Late previous manager callback stopped next recording")

        // Explicit cancel during system startup never opens the microphone later.
        voice.endSystemConversationKeepingWatchDraft(); await settle(); secondManager.deactivate(); await settle()
        voice.executeLabCommand(command(3)) { ok, _ in results.append(ok) }
        await settle(0.4)
        let cancelledManager = ConversationManager.instances.last!
        voice.cancelPendingStart(); await settle()
        cancelledManager.activate(); await settle()
        check(results.last == false && !service.isRecording && voice.callUUID == nil, "Cancelled start resumed on late activation")

        // Background microphone permission failures return immediately, not an
        // unexplained eight-second timeout. Next press works after permission.
        AVAudioSession.sharedInstance().recordPermission = .denied
        UIApplication.shared.applicationState = .background
        let count = results.count
        voice.executeLabCommand(command(4)) { ok, _ in results.append(ok) }
        await settle(0.4)
        check(results.count == count + 1 && results.last == false, "Permission rejection wedged command gate")
        AVAudioSession.sharedInstance().recordPermission = .granted
        UIApplication.shared.applicationState = .active
        service.startFails = true
        voice.executeLabCommand(command(5)) { ok, _ in results.append(ok) }
        await settle(0.4)
        let failedManager = ConversationManager.instances.last!
        failedManager.activate(); await settle()
        check(results.last == false && !service.isRecording, "Recorder failure didn't finish start")
        voice.endSystemConversationKeepingWatchDraft(); await settle(); failedManager.deactivate(); await settle()
        service.startFails = false
        voice.executeLabCommand(command(6)) { ok, _ in results.append(ok) }
        await settle(0.4)
        let finalManager = ConversationManager.instances.last!
        finalManager.activate(); await settle(); service.capturedRecordingDuration = 1.1; await settle(0.6)
        check(results.last == true && service.isRecording, "Failed capture prevented next start")
        voice.endSystemConversationKeepingWatchDraft(); await settle(); finalManager.deactivate(); await settle()
        print("Production LCK lifecycle: offline start, stale action, phone hang-up, audio release, cancel, permission failure, recorder failure recovery passed")
        await runWatchJournalChecks()
    }
}

@MainActor func runWatchJournalChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-state-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = WearableService.shared
    let voice = VoiceConversationProbe.shared
    let watch = WatchVoiceSession(storageRoot: root)
    var responses: [Data] = []
    var wireSequence: UInt16 = 0
    func wire(_ controller: WatchVoiceSession, _ action: WatchRequest.Action) {
        controller.send = { responses.append($0) }
        wireSequence += 1
        var sync = Data([65,82,3,0]); sync.watchAppend(UInt32(424242)); sync.watchAppend(wireSequence)
        sync.watchAppend(UInt32(0)); sync.watchAppend(UInt16(0)); sync.watchAppend(UInt32(0))
        controller.receive(sync)
        let state = responses.last!
        wireSequence += 1
        var packet = Data([65,82,3,action.rawValue]); packet.watchAppend(UInt32(424242)); packet.watchAppend(wireSequence)
        packet.watchAppend(state.watchUInt32(6)); packet.watchAppend(state.watchUInt16(10)); packet.watchAppend(state.watchUInt32(12) + 8)
        controller.receive(packet)
    }
    service.captureDirectory = root.appendingPathComponent("Recordings")
    service.authCookie = nil
    let destination: [String:String] = ["hostId":"original", "project":"first"]
    UserDefaults.standard.set(destination, forKey: "shortcut_recording_destination")
    func journal() -> [String:Any] {
        let bytes = try! Data(contentsOf: root.appendingPathComponent("WatchVoice/journal.json"))
        return try! JSONSerialization.jsonObject(with: bytes) as! [String:Any]
    }
    func activate(_ controller: WatchVoiceSession) async -> ConversationManager {
        await settle(0.4)
        let manager = ConversationManager.instances.last!
        manager.activate(); await settle()
        return manager
    }
    func release(_ manager: ConversationManager) async { await settle(0.2); manager.deactivate(); await settle(0.25) }

    // Four controls use one real journal. Phone pause/continue omits the pause
    // gap, and changing UI destination during recording cannot retarget audio.
    watch.phoneStart()
    let first = await activate(watch)
    service.capturedRecordingDuration = 0.6
    await settle(0.6)
    watch.phonePause(); await release(first)
    check(watch.isPausedDraft, "Phone pause lost draft")
    UserDefaults.standard.set(["hostId":"changed", "project":"other"], forKey:"shortcut_recording_destination")
    watch.phoneStart()
    let second = await activate(watch)
    service.capturedRecordingDuration = 0.8
    await settle(0.6)
    watch.phoneSend(); await release(second); await settle(0.4)
    var saved = journal()
    var deliveries = saved["deliveries"] as! [[String:Any]]
    check(deliveries.count == 1 && !watch.hasDraft, "Segment send did not persist exactly one message")
    check(abs((deliveries[0]["duration"] as! Double) - 1.4) < 0.001, "Pause gap leaked into merged duration")
    check((deliveries[0]["destination"] as! [String:String]) == destination, "UI context change retargeted capture")
    let originalSession = saved["session"] as! String
    check(deliveries[0]["session"] as! String == originalSession, "Send ended logical conversation")

    watch.phoneEnd(); await settle()
    check(journal()["session"] == nil, "End with no recording did not close logical context")

    // PWR must cancel a start that has not acquired audio, instead of just
    // returning busy forever. A late activation must not reopen the microphone.
    watch.phoneStart(); await settle(0.4)
    let cancelled = ConversationManager.instances.last!
    wire(watch, .end); await settle(0.4)
    cancelled.activate(); await settle()
    check(!watch.hasDraft && !service.isRecording && journal()["session"] == nil, "PWR during startup did not cancel cleanly")
    check(responses.last?[3] == WatchReply.Result.applied.rawValue, "PWR cancel did not receive terminal confirmation")

    // Early failed/empty recording must not trap every later long press in send.
    service.startFails = true
    watch.phoneStart()
    let failed = await activate(watch)
    await release(failed)
    check(!watch.hasDraft && !service.isRecording, "Failed start left phantom draft")
    service.startFails = false
    watch.phoneStart()
    let third = await activate(watch)
    service.capturedRecordingDuration = 0.5
    await settle(0.6)
    check(service.isRecording, "Start after empty failure failed")

    // Unexpected stop saves a paused draft; a controller restart recovers it
    // without automatically reopening the microphone.
    service.stopRecording(shouldProcess: false); await release(third)
    check(watch.isPausedDraft, "External phone stop lost captured segment")
    let recovered = WatchVoiceSession(storageRoot: root)
    check(recovered.isPausedDraft && !service.isRecording, "Journal restart auto-recorded or lost draft")
    recovered.phoneStart()
    let fourth = await activate(recovered)
    service.capturedRecordingDuration = 0.5
    await settle(0.6)

    // User hangs up while a send is still merging. Save finishes once and closes
    // the logical context; delayed call cleanup cannot interfere with the save.
    let barrier = DispatchSemaphore(value: 0)
    MediaSDK.mergeBarrier = barrier
    recovered.phoneSend(); await settle()
    wire(recovered, .end)
    voice.end(); await settle()
    MediaSDK.mergeBarrier = nil; barrier.signal()
    await release(fourth); await settle(0.5)
    saved = journal(); deliveries = saved["deliveries"] as! [[String:Any]]
    check(deliveries.count == 2 && saved["session"] == nil, "Hang-up during merge lost message or retained closed context")
    check(deliveries[1]["session"] as! String != originalSession, "Explicit end did not create new context next time")
    check(deliveries.allSatisfy { $0["state"] as? String == "pending" }, "Offline files did not remain pending")
    check(responses.last?[3] == WatchReply.Result.applied.rawValue, "PWR during save did not receive terminal confirmation")

    // A merge error preserves source segments, then succeeds once when retried.
    recovered.phoneStart()
    let fifth = await activate(recovered)
    service.capturedRecordingDuration = 0.7; await settle(0.6)
    MediaSDK.forceMergeFailure = true
    recovered.phoneSend(); await release(fifth); await settle(0.3)
    check(recovered.hasDraft && (journal()["deliveries"] as! [Any]).count == 2, "Merge failure lost or duplicated audio")
    MediaSDK.forceMergeFailure = false
    recovered.phoneSend(); await settle(0.5)
    check(!recovered.hasDraft && (journal()["deliveries"] as! [Any]).count == 3, "Merge retry failed to close durable draft")
    print("Production watch journal: pause/resume, same/new context, target freeze, failed-start recovery, external stop, restart, hang-up during merge, offline persistence, merge retry passed")
}
