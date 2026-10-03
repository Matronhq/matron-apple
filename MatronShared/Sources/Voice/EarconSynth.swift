import Foundation

/// The three short sounds that mark a state change, so nothing needs a
/// glance at the screen (spec 2026-10-03 §3, §11). Made here as WAV bytes
/// rather than shipped as files: two sine notes each, a few hundred
/// milliseconds, with a short fade at both ends so they do not click.
public enum EarconSynth {
    public static let sampleRate = 24_000

    /// (frequency in Hz, seconds) for each note.
    static func notes(_ earcon: VoiceModeEngine.Earcon) -> [(Double, Double)] {
        switch earcon {
        case .micOpen: return [(660, 0.07), (880, 0.09)]    // up: go ahead
        case .sent: return [(880, 0.06), (1_175, 0.10)]     // up and away
        case .error: return [(392, 0.12), (294, 0.16)]      // down
        }
    }

    public static func duration(_ earcon: VoiceModeEngine.Earcon) -> TimeInterval {
        notes(earcon).reduce(0) { $0 + $1.1 }
    }

    /// 16-bit mono PCM samples.
    static func samples(_ earcon: VoiceModeEngine.Earcon) -> [Int16] {
        var out: [Int16] = []
        let fade = Int(Double(sampleRate) * 0.008)
        for (frequency, seconds) in notes(earcon) {
            let count = Int(Double(sampleRate) * seconds)
            for index in 0..<count {
                let envelope = min(1, Double(min(index, count - 1 - index)) / Double(fade))
                let value = sin(2 * Double.pi * frequency * Double(index) / Double(sampleRate))
                out.append(Int16(value * envelope * 0.35 * Double(Int16.max)))
            }
        }
        return out
    }

    /// A complete WAV file (RIFF header + PCM), playable by any player.
    public static func wav(_ earcon: VoiceModeEngine.Earcon) -> Data {
        let samples = samples(earcon)
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                      // PCM chunk size
        append(UInt16(1))                       // PCM
        append(UInt16(1))                       // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))          // byte rate
        append(UInt16(2))                       // block align
        append(UInt16(16))                      // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in samples { append(sample) }
        return data
    }
}
