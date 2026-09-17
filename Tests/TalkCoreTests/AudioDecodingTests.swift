import Foundation
import Testing
@testable import TalkCore

/// A 16-bit PCM WAV file, built byte by byte.
private func wav(samples: [Int16], sampleRate: Int = 16_000, channels: Int = 1) -> Data {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let byteCount = samples.count * 2
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(channels))
    append(UInt32(sampleRate)); append(UInt32(sampleRate * channels * 2)); append(UInt16(channels * 2)); append(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
    for sample in samples { append(sample) }
    return data
}

@Suite("Audio decoding")
struct AudioDecodingTests {
    @Test("A WAV held in memory decodes to its samples and length")
    func decodesWAV() throws {
        // Half a second of silence, then half a second of a loud square wave.
        let quiet = [Int16](repeating: 0, count: 8_000)
        let loud = (0..<8_000).map { $0 % 40 < 20 ? Int16(20_000) : Int16(-20_000) }
        let audio = try AudioDecoder.decode(wav(samples: quiet + loud))

        #expect(audio.sampleRate == 16_000)
        #expect(abs(audio.duration - 1.0) < 0.01)

        let levels = audio.levels(count: 10)
        #expect(levels.count == 10)
        #expect(levels.prefix(5).allSatisfy { $0 < 0.2 })     // the silent half keeps a stub
        #expect(levels.suffix(5).allSatisfy { $0 > 0.95 })    // the loud half fills the bar
    }

    @Test("Something that isn't audio is refused rather than read as noise")
    func refusesGarbage() {
        #expect(throws: AudioDecodingError.self) {
            try AudioDecoder.decode(Data("OggS not really a recording at all".utf8))
        }
    }

    @Test("Levels of nothing are flat")
    func emptyLevels() {
        #expect(DecodedAudio(samples: [], sampleRate: 16_000).levels(count: 4) == [0.12, 0.12, 0.12, 0.12])
    }
}
