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
    }
}
