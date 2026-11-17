import Foundation
import AVFoundation

enum WatchAudioMerge {
    enum Failure: Error { case format, duration }
    static func merge(files: [URL], output: URL) throws -> Double {
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        var writer: AVAudioFile? = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var frames: AVAudioFramePosition = 0
        for url in files {
            let source = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard source.processingFormat.sampleRate == 16000, source.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096) else { throw Failure.format }
            while source.framePosition < source.length {
                try source.read(into: buffer)
                guard buffer.frameLength > 0 else { throw Failure.format }
                try writer?.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
            }
        }
        writer = nil
        let file = try AVAudioFile(forReading: output)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard frames >= 4800, file.length > 0, abs(duration - Double(frames) / 16000) < 0.25 else { throw Failure.duration }
        return duration
    }
}
