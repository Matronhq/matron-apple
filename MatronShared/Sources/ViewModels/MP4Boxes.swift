import Foundation

/// Just enough MP4 parsing to spot what older decoders reject in a voice
/// note before it is sent.
enum MP4Boxes {
    /// Whether the file's `moov` holds a `chnl` (channel layout) box with
    /// a version other than 0. ffmpeg before 7.0 refuses to open such a
    /// file ("Unsupported 'chnl' box with version 1").
    static func hasVersionedChannelLayout(_ data: Data) -> Bool {
        guard let moov = topLevelBox("moov", in: data) else { return false }
        let bytes = [UInt8](data[moov])
        let tag: [UInt8] = Array("chnl".utf8)
        var i = 4
        while i + 8 <= bytes.count {
            if bytes[i] == tag[0], bytes[i + 1] == tag[1], bytes[i + 2] == tag[2], bytes[i + 3] == tag[3] {
                let size = Int(bytes[i - 4]) << 24 | Int(bytes[i - 3]) << 16 | Int(bytes[i - 2]) << 8 | Int(bytes[i - 1])
                // A real box header: its size covers a full-box header and
                // stays inside `moov`.
                if size >= 12, i - 4 + size <= bytes.count {
                    return bytes[i + 4] != 0
                }
            }
            i += 1
        }
        return false
    }

    /// The byte range of the first top-level box of `type`, header included.
    static func topLevelBox(_ type: String, in data: Data) -> Range<Data.Index>? {
        let tag = Array(type.utf8)
        var offset = data.startIndex
        while offset + 8 <= data.endIndex {
            var size = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            let name = Array(data[(offset + 4)..<(offset + 8)])
            if size == 1 {
                guard offset + 16 <= data.endIndex else { return nil }
                size = data[(offset + 8)..<(offset + 16)].reduce(0) { $0 << 8 | Int($1) }
            } else if size == 0 {
                size = data.endIndex - offset
            }
            guard size >= 8, offset + size <= data.endIndex else { return nil }
            if name == tag { return offset..<(offset + size) }
            offset += size
        }
        return nil
    }
}
