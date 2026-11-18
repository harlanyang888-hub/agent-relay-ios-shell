// Headless SDK boundary only. Tests compile the production VoiceConversationProbe.
import Foundation

enum TestFailure: Error { case rejected }
struct UIBackgroundTaskIdentifier: Equatable {
    let rawValue: Int
    static let invalid = Self(rawValue: -1)
}
final class UIApplication {
    static let didBecomeActiveNotification = Notification.Name("TestAppActive")
    static let protectedDataDidBecomeAvailableNotification = Notification.Name("TestAppUnlocked")
    enum State: Int { case active, inactive, background }
    static let shared = UIApplication()
    var applicationState: State = .active
    var backgroundTimeRemaining: Double = 1000000
    private var task = 0
    func beginBackgroundTask(withName: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        task += 1; return .init(rawValue: task)
    }
    func endBackgroundTask(_ task: UIBackgroundTaskIdentifier) {}
}
final class AVAudioSession {
    enum RecordPermission: UInt { case undetermined, denied, granted }
    enum Category: String { case playAndRecord }
    enum Mode: String { case voiceChat }
    struct CategoryOptions: OptionSet {
        let rawValue: Int
        static let allowBluetooth = Self(rawValue: 1)
        static let allowBluetoothA2DP = Self(rawValue: 2)
        static let defaultToSpeaker = Self(rawValue: 4)
    }
    struct Port { var portName = "Test input" }
    struct Route { var inputs: [Port] = [Port()]; var outputs: [Port] = [] }
    private static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }
    var recordPermission: RecordPermission = .granted
    var currentRoute = Route()
    var mode = Mode.voiceChat
    var isOtherAudioPlaying = false
    var permissionReply: ((Bool) -> Void)?
    func setCategory(_ category: Category, mode: Mode, options: CategoryOptions) throws {}
    func requestRecordPermission(_ completion: @escaping (Bool) -> Void) { permissionReply = completion }
}
protocol AVAudioPlayerDelegate: AnyObject {}
final class AVAudioPlayer {
    weak var delegate: AVAudioPlayerDelegate?
    var isPlaying = false
    init(data: Data) throws {}
    func play() -> Bool { isPlaying = true; return true }
    func stop() { isPlaying = false }
}
enum CBManager { enum Authorization: Int { case allowed }; static let authorization = Authorization.allowed }
enum BLERecoveryLab {
    static var enabled = true
    static var usesASK = true
    // Intentionally simulates an old persisted preflight diagnostic switch.
    static var immediateSystemStart = false
}
final class DeviceDiagnostics {
    static let shared = DeviceDiagnostics()
    var lines: [String] = []
    func log(_ line: String) { lines.append(line) }
}
final class WearableService {
    static let shared = WearableService()
    var isRecording = false
    var isListening = false
    var inputComparisonActive = false
    var capturedRecordingDuration: Double = 0
    var recordingInputName = "Test input"
    var lastVoiceSubmissionQueued = false
    var authCookie: String?
    var gatewayBaseURL = "http://127.0.0.1:1"
    var startFails = false
    var starts = 0
    var captureDirectory: URL?
    var currentFile: URL?
    var watchRecordingStarted: ((URL) -> Bool)?
    var watchEndRequested: (() -> Void)?
    var watchStopRequested: ((Bool) -> Void)?
    var communicationButtonHandler: ((String) -> Void)?
    var communicationPlaybackHandler: ((Data) -> Void)?
    func startRecording() {
        starts += 1; capturedRecordingDuration = 0
        if let directory = captureDirectory {
            let url = directory.appendingPathComponent("test-\(UUID().uuidString).m4a")
            try! Data().write(to: url); currentFile = url
            if watchRecordingStarted?(url) == false { isRecording = false; return }
        }
        isRecording = !startFails
    }
    func sealWatchSegment() -> (URL, TimeInterval)? {
        guard let url = currentFile else { return nil }
        currentFile = nil; isRecording = false
        guard capturedRecordingDuration > 0 else { return nil }
        try! Data(repeating: 1, count: Int(capturedRecordingDuration * 16000)).write(to: url)
        return (url, capturedRecordingDuration)
    }
    func stopRecording(shouldProcess: Bool = true) {
        if let handler = watchStopRequested { handler(shouldProcess); return }
        isRecording = false; lastVoiceSubmissionQueued = shouldProcess
    }
    func stopListening() { isListening = false }
    func enterCommunicationMode() {}
    func leaveCommunicationMode() { if isRecording { stopRecording(shouldProcess: false) } }
    func refreshCommunicationMediaState(active: Bool) {}
    func communicationAudioDidActivate(_ session: AVAudioSession) {}
    func communicationAudioDidDeactivate(_ session: AVAudioSession) {}
}
struct Handle {
    enum Kind { case generic }
    init(type: Kind, value: String, displayName: String) {}
}
class ConversationAction {
    let conversationUUID: UUID
    var completion: ((Result<Void, Error>) -> Void)?
    var fulfilled = false
    init(conversationUUID: UUID) { self.conversationUUID = conversationUUID }
    func fulfill() { fulfilled = true; let fn = completion; completion = nil; fn?(.success(())) }
    func fail() { let fn = completion; completion = nil; fn?(.failure(TestFailure.rejected)) }
}
final class StartConversationAction: ConversationAction {
    init(conversationUUID: UUID, handles: [Handle], isVideo: Bool) { super.init(conversationUUID: conversationUUID) }
}
final class EndConversationAction: ConversationAction {}
final class PauseConversationAction: ConversationAction {
    let isPaused: Bool
    init(conversationUUID: UUID, isPaused: Bool) { self.isPaused = isPaused; super.init(conversationUUID: conversationUUID) }
}
struct Conversation { let uuid: UUID }
enum ConversationEvent { case conversationConnected(Date) }
protocol ConversationManagerDelegate: AnyObject {
    func conversationManagerDidBegin(_ manager: ConversationManager)
    func conversationManagerDidReset(_ manager: ConversationManager)
    func conversationManager(_ manager: ConversationManager, perform action: ConversationAction)
    func conversationManager(_ manager: ConversationManager, didActivate session: AVAudioSession)
    func conversationManager(_ manager: ConversationManager, didDeactivate session: AVAudioSession)
}
final class ConversationManager {
    struct Configuration {
        init(ringtoneName: String?, iconTemplateImageData: Data?, maximumConversationGroups: Int,
             maximumConversationsPerConversationGroup: Int, includesConversationInRecents: Bool,
             supportsVideo: Bool, supportedHandleTypes: [Handle.Kind]) {}
    }
    static var instances: [ConversationManager] = []
    static var autoReady = true
    weak var delegate: ConversationManagerDelegate?
    var conversations: [Conversation] = []
    var actions: [ConversationAction] = []
    var invalidated = false
    var holdEnds = false
    init(configuration: Configuration) {
        Self.instances.append(self)
        DispatchQueue.main.async { if Self.autoReady { self.delegate?.conversationManagerDidBegin(self) } }
    }
    func perform(_ actions: [ConversationAction]) async throws {
        guard !invalidated else { throw TestFailure.rejected }
        for action in actions {
            self.actions.append(action)
            if action is StartConversationAction { conversations.append(Conversation(uuid: action.conversationUUID)) }
            try await withCheckedThrowingContinuation { continuation in
                action.completion = { result in
                    if action is EndConversationAction { self.conversations.removeAll { $0.uuid == action.conversationUUID } }
                    continuation.resume(with: result)
                }
                if !(holdEnds && action is EndConversationAction) { delegate?.conversationManager(self, perform: action) }
            }
        }
    }
    func invalidate() { invalidated = true }
    func reportConversationEvent(_ event: ConversationEvent, for conversation: Conversation) {}
    func activate() { delegate?.conversationManager(self, didActivate: .sharedInstance()) }
    func deactivate() { delegate?.conversationManager(self, didDeactivate: .sharedInstance()) }
}

// Deterministic dispatch-backed timers avoid requiring an Apple main RunLoop in
// the Linux harness. The production source still chooses the scheduling mode.
final class Timer {
    private let interval: Double
    private let repeats: Bool
    private let block: (Timer) -> Void
    private var valid = true
    init(timeInterval: Double, repeats: Bool, block: @escaping (Timer) -> Void) {
        interval = timeInterval; self.repeats = repeats; self.block = block
    }
    func invalidate() { valid = false }
    func schedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [self] in
            guard valid else { return }; block(self)
            if repeats && valid { schedule() }
        }
    }
}
final class RunLoop {
    enum Mode { case common }
    static let main = RunLoop()
    func add(_ timer: Timer, forMode: Mode) { timer.schedule() }
}

struct NWPath { enum Status { case satisfied, unsatisfied }; let status: Status }
final class NWPathMonitor {
    var pathUpdateHandler: ((NWPath) -> Void)?
    func start(queue: DispatchQueue) {}
}
final class AVAudioFile {
    struct Format { let sampleRate: Double = 16000 }
    let length: Int64
    let processingFormat = Format()
    init(forReading url: URL) throws { length = Int64(try Data(contentsOf: url).count) }
}
enum MediaSDK {
    static var forceMergeFailure = false
    static var mergeBarrier: DispatchSemaphore?
}
enum WatchAudioMerge {
    static func merge(files: [URL], output: URL) throws -> Double {
        MediaSDK.mergeBarrier?.wait()
        if MediaSDK.forceMergeFailure { throw TestFailure.rejected }
        var bytes = Data()
        for file in files { bytes.append(try Data(contentsOf: file)) }
        guard bytes.count >= 4800 else { throw TestFailure.rejected }
        try bytes.write(to: output)
        return Double(bytes.count) / 16000
    }
}
