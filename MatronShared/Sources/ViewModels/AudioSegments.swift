import Foundation
import AVFoundation

/// One part of a voice note that changed microphone part-way through:
/// the file a recorder wrote, and how much of its start to drop (the new
/// microphone's silent lead-in, recorded while the old one still had the
/// voice).
struct AudioSegment: Equatable {
    let url: URL
    let trimStart: TimeInterval
}

/// Writes `parts` one after another into a new AAC `.m4a` at `url`, in the
/// first part's format. A part in another format (a microphone with a
/// different channel count, say) is converted on the way.
func joinAudioSegments(_ parts: [AudioSegment], into url: URL) throws {
    guard let first = parts.first else { return }
    let format = try AVAudioFile(forReading: first.url).processingFormat
    let out = try AVAudioFile(forWriting: url,
                              settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                         AVSampleRateKey: format.sampleRate,
                                         AVNumberOfChannelsKey: format.channelCount,
                                         AVEncoderBitRateKey: 64_000],
                              commonFormat: .pcmFormatFloat32,
                              interleaved: false)
    let chunk: AVAudioFrameCount = 8_192
    for part in parts {
        let file = try AVAudioFile(forReading: part.url)
        let skip = AVAudioFramePosition(max(0, part.trimStart) * file.processingFormat.sampleRate)
        guard skip < file.length else { continue }
        file.framePosition = skip
        func readChunk() throws -> AVAudioPCMBuffer? {
            guard file.framePosition < file.length,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return nil }
            try file.read(into: buffer, frameCount: chunk)
            return buffer.frameLength > 0 ? buffer : nil
        }
        if file.processingFormat == out.processingFormat {
            while let buffer = try readChunk() { try out.write(from: buffer) }
            continue
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: out.processingFormat) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let ratio = out.processingFormat.sampleRate / file.processingFormat.sampleRate
        var readError: Error?
        while true {
            guard let converted = AVAudioPCMBuffer(pcmFormat: out.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 1) else { break }
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                do {
                    guard let buffer = try readChunk() else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return buffer
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let error { throw error }
            if let readError { throw readError }
            if converted.frameLength > 0 { try out.write(from: converted) }
            if status == .endOfStream || status == .error { break }
        }
    }
}
