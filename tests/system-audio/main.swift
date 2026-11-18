import Foundation
import AVFoundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-engine-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let url = root.appendingPathComponent("route-format-changes.m4a")
let writer = try SystemAudioPCMWriter(url: url)
// Hardware changes from 8k mono HFP to 48k stereo, then 24k mono.
// Feed realistic streaming blocks, not one preconverted file.
for (rate, channels, frequency) in [(8000.0, 1, 440.0), (48000.0, 2, 880.0), (24000.0, 1, 660.0)] {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
    let total = Int(rate * 0.6)
    var offset = 0
    while offset < total {
        let count = min(512, total - offset)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for c in 0..<channels {
            for i in 0..<count {
                buffer.floatChannelData![c][i] = Float(sin(Double(offset + i) * 2 * .pi * frequency / rate) * 0.25)
            }
        }
        try writer.append(buffer)
        offset += count
    }
}
try writer.close()
try writer.close() // Lifecycle cleanup can run twice; it must not corrupt the file.
assert(abs(writer.duration - 1.8) < 0.04, "Converted frames must preserve duration across input format changes")
let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
assert(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1)
assert(abs(Double(file.length) / 16000 - 1.8) < 0.15)
let decoded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try file.read(into: decoded)
for (start, frequency) in [(0.15, 440.0), (0.75, 880.0), (1.35, 660.0)] {
    let a = Int(start * 16000), b = a + 3200
    var crossings = 0
    for i in (a + 1)..<b where decoded.floatChannelData![0][i-1] < 0 && decoded.floatChannelData![0][i] >= 0 { crossings += 1 }
    assert(abs(Double(crossings) / 0.2 - frequency) < 30, "Tone order and pitch must survive streaming resampling")
}
let closedBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!, frameCapacity: 16)!
closedBuffer.frameLength = 16
do { try writer.append(closedBuffer); fatalError("Closed writer accepted new samples") }
catch SystemAudioPCMWriter.Failure.closed {}
print("System audio streaming conversion, AAC finalization, format changes and tone-order checks passed")
