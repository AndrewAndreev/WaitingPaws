import Foundation

/// Reads the top-level box headers of a fragmented MP4 as it streams in, to tell when the first media fragment
/// arrives: go2rtc sends the init segment (`ftyp`, `moov`) at once and the first `moof` only with the camera's next
/// keyframe — up to a whole GOP (a few seconds) after the request.
public struct MP4FragmentScanner {
    /// The current box header read so far (8 bytes, 16 with a 64-bit size).
    private var header: [UInt8] = []
    /// Bytes of the current box's body still to skip.
    private var remaining: UInt64 = 0
    /// A box that runs to the end of the stream (size 0), or one too short to be a box: nothing more to read.
    private var gaveUp = false
    public private(set) var sawFragment = false

    public init() {}

    /// Feeds the next bytes of the stream; true once a `moof` (or a bare `mdat`) has started.
    public mutating func feed(_ data: Data) -> Bool {
        guard !sawFragment, !gaveUp else { return sawFragment }
        var index = data.startIndex
        while index < data.endIndex {
            if remaining > 0 {
                let step = Int(min(remaining, UInt64(data.endIndex - index)))
                remaining -= UInt64(step)
                index += step
                continue
            }
            header.append(data[index])
            index += 1
            guard header.count >= 8 else { continue }
            let size32 = header[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if type == "moof" || type == "mdat" {
                sawFragment = true
                return true
            }
            var size = size32
            var headerLength: UInt64 = 8
            if size32 == 1 {
                // A 64-bit size follows the type.
                guard header.count >= 16 else { continue }
                size = header[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                headerLength = 16
            }
            guard size >= headerLength else {
                gaveUp = true
                return false
            }
            remaining = size - headerLength
            header.removeAll(keepingCapacity: true)
        }
        return false
    }
}
