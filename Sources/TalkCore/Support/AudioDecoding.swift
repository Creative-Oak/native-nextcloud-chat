import AudioToolbox
import Foundation

/// A recording decoded to mono samples, for drawing its waveform and transcribing it.
struct DecodedAudio: Sendable {
    var samples: [Float]
    var sampleRate: Double

    var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    /// `count` bar heights between `floor` and 1: the loudness of each stretch of the
    /// recording, scaled so the loudest stretch fills the bar. Silence keeps a small stub,
    /// as Messages draws it, so the bars still read as a row.
    func levels(count: Int, floor: Float = 0.12) -> [Float] {
        guard count > 0, !samples.isEmpty else { return Array(repeating: floor, count: max(count, 0)) }
        let bucket = max(samples.count / count, 1)
        var rms: [Float] = []
        rms.reserveCapacity(count)
        for index in 0..<count {
            let start = index * bucket
            guard start < samples.count else { rms.append(0); continue }
            let end = min(start + bucket, samples.count)
            var sum: Float = 0
            for sample in samples[start..<end] { sum += sample * sample }
            rms.append((sum / Float(end - start)).squareRoot())
        }
        let loudest = rms.max() ?? 0
        guard loudest > 0 else { return Array(repeating: floor, count: count) }
        return rms.map { floor + (1 - floor) * ($0 / loudest) }
    }
}

enum AudioDecodingError: Error, Equatable {
    /// Core Audio can't read this format — Ogg is the one that turns up.
    case unsupportedFormat
    case readFailed
}

/// Decodes audio that is only in memory.
///
/// Core Audio normally wants a file, and the voice messages this reads are someone's voice:
/// kvidr keeps its cache encrypted and doesn't write a plaintext copy to a temporary folder to
/// get around that. `AudioFileOpenWithCallbacks` reads through callbacks instead, and
/// `ExtAudioFile` converts whatever the recording is (WAV, MP3, AAC) to mono floats.
enum AudioDecoder {
    static func decode(_ data: Data) throws(AudioDecodingError) -> DecodedAudio {
        let source = MemorySource(data: data)
        let context = Unmanaged.passUnretained(source).toOpaque()

        var fileID: AudioFileID?
        let opened = AudioFileOpenWithCallbacks(context, readProc, nil, sizeProc, nil, 0, &fileID)
        guard opened == noErr, let fileID else { throw .unsupportedFormat }
        defer { AudioFileClose(fileID) }

        var extFile: ExtAudioFileRef?
        guard ExtAudioFileWrapAudioFileID(fileID, false, &extFile) == noErr, let extFile else {
            throw .unsupportedFormat
        }
        defer { ExtAudioFileDispose(extFile) }

        var fileFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat) == noErr,
              fileFormat.mSampleRate > 0
        else { throw .unsupportedFormat }

        var client = AudioStreamBasicDescription(
            mSampleRate: fileFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard ExtAudioFileSetProperty(
            extFile, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client
        ) == noErr else { throw .unsupportedFormat }

        var samples: [Float] = []
        let chunk = 16_384
        var scratch = [Float](repeating: 0, count: chunk)
        while true {
            var frames = UInt32(chunk)
            let status = scratch.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
                )
                return ExtAudioFileRead(extFile, &frames, &list)
            }
            guard status == noErr else { throw .readFailed }
            if frames == 0 { break }
            samples.append(contentsOf: scratch[0..<Int(frames)])
        }
        guard !samples.isEmpty else { throw .readFailed }
        return DecodedAudio(samples: samples, sampleRate: fileFormat.mSampleRate)
    }
}

private final class MemorySource {
    let data: Data
    init(data: Data) { self.data = data }
}

private let readProc: AudioFile_ReadProc = { context, position, requestCount, buffer, actualCount in
    let source = Unmanaged<MemorySource>.fromOpaque(context).takeUnretainedValue()
    let available = Int64(source.data.count) - position
    let count = Int(max(0, min(Int64(requestCount), available)))
    if count > 0 {
        source.data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(buffer, base.advanced(by: Int(position)), count)
            }
        }
    }
    actualCount.pointee = UInt32(count)
    return noErr
}

private let sizeProc: AudioFile_GetSizeProc = { context in
    Int64(Unmanaged<MemorySource>.fromOpaque(context).takeUnretainedValue().data.count)
}
