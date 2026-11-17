import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

var data = Data([65, 82, 3, 1])
data.watchAppend(UInt32(0x12345678)); data.watchAppend(UInt16(0x2001))
data.watchAppend(UInt32(0x89abcdef)); data.watchAppend(UInt16(0x1234)); data.watchAppend(UInt32(0x70000000))
let request = WatchRequest(data)!
assert(request.key == "785634120120" && request.epoch == 0x89abcdef && request.revision == 0x1234)
assert(!request.expired(at: Double(0x70000000) - 1) && request.expired(at: Double(0x70000000)))
assert(request.isFresh(at: Double(0x70000000) - 8))
assert(!request.isFresh(at: Double(0x70000000) - 11))
assert(!request.isFresh(at: Double(0x70000000)))
assert(WatchRequest(data.dropLast()) == nil)
var bad = data; bad[3] = 0; assert(WatchRequest(bad) == nil)
bad = data; bad[8] = 0; bad[9] = 0; assert(WatchRequest(bad) == nil)
let suite = "watch-tests-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
let receipts = WatchReceipts(defaults: defaults)
assert(receipts.result(for: request) == nil)
receipts.record(request, succeeded: true, error: 0)
assert(WatchReceipts(defaults: defaults).result(for: request)?.0 == true)
bad = data; bad[10] ^= 1
assert(receipts.result(for: WatchRequest(bad)!)?.0 == false)
defaults.removePersistentDomain(forName: suite)
let response = WatchReply(result: .applied, sequence: 0x2001, epoch: 42, revision: 7, capture: .paused, flags: 2).encoded(at: 100)
assert(Array(response) == [65,82,3,1,1,32,42,0,0,0,7,0,100,0,0,0,3,2,0,0])
assert(WatchDeliveryOrder.nextIndex([(session: "a", state: "pending"), (session: "b", state: "pending")]) == 0)
assert(WatchDeliveryOrder.nextIndex([(session: "a", state: "uncertain"), (session: "a", state: "pending"), (session: "b", state: "pending")]) == 2)
assert(WatchDeliveryOrder.nextIndex([(session: "a", state: "sending"), (session: "a", state: "pending")]) == nil)
assert(WatchDeliveryOrder.nextIndex([(session: "a", state: "needsReview"), (session: "b", state: "pending")]) == 1)

#if canImport(AVFoundation)
let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-merge-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
func tone(_ name: String, seconds: Double, frequency: Double) throws -> URL {
    let url = root.appendingPathComponent(name + ".m4a")
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 16000))!
    buffer.frameLength = buffer.frameCapacity
    for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * frequency / 16000) * 0.3) }
    var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1], commonFormat: .pcmFormatFloat32, interleaved: false)
    try file?.write(from: buffer); file = nil
    return url
}
let first = try tone("first", seconds: 0.6, frequency: 440)
let second = try tone("second", seconds: 0.8, frequency: 880)
let output = root.appendingPathComponent("message.m4a")
let duration = try WatchAudioMerge.merge(files: [first, second], output: output)
assert(abs(duration - 1.4) < 0.25)
let audio = try AVAudioFile(forReading: output, commonFormat: .pcmFormatFloat32, interleaved: false)
let decoded = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
try audio.read(into: decoded)
func crossings(_ start: Int, _ end: Int) -> Int {
    var count = 0
    for i in (start+1)..<end where decoded.floatChannelData![0][i-1] < 0 && decoded.floatChannelData![0][i] >= 0 { count += 1 }
    return count
}
// Distinct tones prove segment order as well as absence of a large pause gap.
assert(crossings(1600, 6400) > 100 && crossings(1600, 6400) < 160)
assert(crossings(12800, 17600) > 230 && crossings(12800, 17600) < 300)
print("Watch wire, receipt persistence, AAC merge/order checks passed")
#else
print("Watch wire and receipt persistence checks passed")
#endif
