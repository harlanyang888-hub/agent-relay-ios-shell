import Foundation
import AVFoundation

protocol RelayAudioCapture: AnyObject {
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    func stop()
    func updateMeters()
    func peakPower(forChannel channelNumber: Int) -> Float
}

extension AVAudioRecorder: RelayAudioCapture {}

// One AAC file with a fixed format, even when the hardware input changes format.
// Caller serializes append/close. This object never activates an audio session.
final class SystemAudioPCMWriter {
    enum Failure: Error { case format, conversion, closed }
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private(set) var frames: AVAudioFramePosition = 0
    private(set) var peakDB: Float = -120
    var duration: Double { Double(frames) / 16000 }

    init(url: URL) throws {
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ input: AVAudioPCMBuffer) throws {
        guard file != nil else { throw Failure.closed }
        guard input.frameLength > 0, input.format.sampleRate > 0,
              input.format.channelCount > 0 else { throw Failure.format }
        if sourceFormat != input.format {
            try drainConverter()
            converter = AVAudioConverter(from: input.format, to: outputFormat)
            guard converter != nil else { throw Failure.format }
            sourceFormat = input.format
        }
        guard let converter = converter else { throw Failure.conversion }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate) + 1024)
        let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)!
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if let error = conversionError { throw error }
        guard status != .error else { throw Failure.conversion }
        try write(output)
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        try file?.write(from: buffer)
        frames += AVAudioFramePosition(buffer.frameLength)
        var peak: Float = 0
        if let samples = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[i])) }
        }
        peakDB = peak > 0 ? max(-120, 20 * log10(peak)) : -120
    }

    private func drainConverter() throws {
        guard let converter = converter else { return }
        let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)!
        for _ in 0..<16 {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                state.pointee = .endOfStream
                return nil
            }
            if let error = conversionError { throw error }
            guard status != .error else { throw Failure.conversion }
            try write(output)
            if status == .endOfStream || output.frameLength == 0 { return }
        }
        throw Failure.conversion
    }

    func close() throws {
        guard file != nil else { return }
        defer { file = nil; converter = nil; sourceFormat = nil }
        try drainConverter()
    }
}

// Used only after LCK didActivate. No AVAudioRecorder, setActive or category
// mutation: the system retains responsibility for audio session activation.
final class SystemAudioCapture: RelayAudioCapture {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let writer: SystemAudioPCMWriter
    private var enabled = false
    private var failed = false
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var routeRestarts = 0
    var onFailure: ((Error) -> Void)?
    var onConfigurationChange: (() -> Void)?

    init(url: URL) throws { writer = try SystemAudioPCMWriter(url: url) }
    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return enabled && !failed }
    var currentTime: TimeInterval { lock.lock(); defer { lock.unlock() }; return writer.duration }
    func updateMeters() {}
    func peakPower(forChannel channelNumber: Int) -> Float {
        lock.lock(); defer { lock.unlock() }; return writer.peakDB
    }

    func start() throws {
        lock.lock(); enabled = true; lock.unlock()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.restoreEngineAfterRouteChange() }
        do { try installTapAndStart() }
        catch { stop(); throw error }
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SystemAudioPCMWriter.Failure.format }
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.lock.lock()
            guard self.enabled && !self.failed else { self.lock.unlock(); return }
            do { try self.writer.append(buffer); self.lock.unlock() }
            catch {
                self.failed = true
                self.lock.unlock()
                DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
            }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    private func restoreEngineAfterRouteChange() {
        guard isRecording else { return }
        // A hardware-rate change invalidates the engine graph. Restart only this
        // still-active capture, without changing the call or opening a new file.
        routeRestarts += 1
        guard routeRestarts <= 8 else {
            onFailure?(SystemAudioPCMWriter.Failure.format)
            return
        }
        onConfigurationChange?()
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        do { try installTapAndStart() }
        catch { onFailure?(error) }
    }

    func stop() {
        lock.lock(); enabled = false; lock.unlock()
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        configurationObserver = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        lock.lock()
        do { try writer.close() }
        catch { lock.unlock(); onFailure?(error); return }
        lock.unlock()
    }
    deinit { stop() }
}
