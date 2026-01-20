import AVFoundation
import Foundation
import Shared

/// Writes sentence-level audio segments to disk as compressed M4A files
/// Owner: STORAGE agent
public actor AudioSegmentWriter {
    private let storageRoot: URL

    public init(storageRoot: URL) {
        self.storageRoot = storageRoot
    }

    /// Extract audio segment from buffer and save to M4A file
    /// - Parameters:
    ///   - audioData: Full PCM buffer (e.g., 30s chunk)
    ///   - startTime: Sentence start time relative to buffer start (seconds)
    ///   - endTime: Sentence end time relative to buffer start (seconds)
    ///   - sampleRate: Audio sample rate (default 16000 Hz)
    ///   - channels: Number of audio channels (default 1 for mono)
    ///   - timestamp: Absolute timestamp for the sentence
    ///   - source: Audio source (microphone or system_audio)
    /// - Returns: Tuple of (relative file path, file size in bytes)
    public func writeAudioSegment(
        audioData: Data,
        startTime: Double,
        endTime: Double,
        sampleRate: Int = 16000,
        channels: Int = 1,
        timestamp: Date,
        source: AudioSource
    ) throws -> (filePath: String, fileSize: Int64) {

        // Validation
        guard !audioData.isEmpty else {
            throw StorageError.fileWriteFailed(path: "audio segment", underlying: "Empty audio data")
        }
        guard startTime >= 0 && endTime > startTime else {
            throw StorageError.fileWriteFailed(path: "audio segment", underlying: "Invalid time range: \(startTime)-\(endTime)")
        }

        // Calculate byte offsets for the sentence
        let bytesPerSample = 2  // Int16 PCM
        let startSample = Int(startTime * Double(sampleRate))
        let endSample = Int(endTime * Double(sampleRate))
        let startByte = startSample * bytesPerSample * channels
        let endByte = endSample * bytesPerSample * channels

        // Extract sentence audio data
        guard startByte >= 0 && endByte <= audioData.count && startByte < endByte else {
            throw StorageError.fileWriteFailed(path: "audio segment", underlying: "Invalid byte range: \(startByte)-\(endByte) for buffer size \(audioData.count)")
        }
        let sentenceData = audioData.subdata(in: startByte..<endByte)

        guard !sentenceData.isEmpty else {
            throw StorageError.fileWriteFailed(path: "audio segment", underlying: "Extracted audio segment is empty")
        }

        // Create output directory structure: audio/2024/12/13/
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM/dd"
        let datePath = dateFormatter.string(from: timestamp)
        let outputDir = storageRoot
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent(datePath, isDirectory: true)

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Generate unique filename: sentence_{timestamp}_{source}_{hash}_{uuid}.m4a
        // UUID suffix prevents overwriting in case of hash collision
        let timestampMs = Int(timestamp.timeIntervalSince1970 * 1000)
        let hash = String(abs(sentenceData.hashValue) & 0xFFFF, radix: 16, uppercase: true)
        let uuid = UUID().uuidString.prefix(8)
        let filename = "sentence_\(timestampMs)_\(source.rawValue)_\(hash)_\(uuid).m4a"
        let outputURL = outputDir.appendingPathComponent(filename)

        // Check if file already exists (should never happen with UUID, but safety check)
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw StorageError.fileWriteFailed(path: outputURL.path, underlying: "File already exists")
        }

        // Convert PCM to M4A (AAC compression)
        try convertPCMToM4A(
            pcmData: sentenceData,
            outputURL: outputURL,
            sampleRate: sampleRate,
            channels: channels
        )

        // Get file size
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = attrs[.size] as? Int64 ?? 0

        // Return relative path from storage root
        let relativePath = "audio/\(datePath)/\(filename)"

        return (relativePath, fileSize)
    }

    /// Convert raw PCM Int16 data to compressed M4A file using AVAssetWriter
    private func convertPCMToM4A(
        pcmData: Data,
        outputURL: URL,
        sampleRate: Int,
        channels: Int
    ) throws {

        // Remove existing file if present
        try? FileManager.default.removeItem(at: outputURL)

        // Create asset writer for M4A
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)

        // Configure AAC audio output
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 64000  // 64 kbps for good quality/size tradeoff
        ]

        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false

        // Add input to writer
        guard writer.canAdd(writerInput) else {
            throw StorageError.fileWriteFailed(path: outputURL.path, underlying: "Cannot add audio input to writer")
        }
        writer.add(writerInput)

        // Start writing session
        guard writer.startWriting() else {
            throw StorageError.fileWriteFailed(path: outputURL.path, underlying: writer.error?.localizedDescription ?? "Failed to start writing")
        }
        writer.startSession(atSourceTime: .zero)

        // Create audio format description for PCM input
        var audioFormat = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &audioFormat,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDescription = formatDescription else {
            throw StorageError.fileWriteFailed(path: outputURL.path, underlying: "Failed to create format description")
        }

        // Convert PCM data to sample buffers and append to writer
        let frameCount = pcmData.count / (2 * channels)
        let blockBuffer = try createBlockBuffer(from: pcmData)

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
            throw StorageError.fileWriteFailed(path: outputURL.path, underlying: "Failed to create sample buffer")
        }

        // Append the sample buffer
        guard writerInput.isReadyForMoreMediaData else {
            throw StorageError.fileWriteFailed(path: outputURL.path, underlying: "Writer input not ready for data")
        }

        let appendSuccess = writerInput.append(sampleBuffer)
        guard appendSuccess else {
            throw StorageError.fileWriteFailed(path: outputURL.path, underlying: "Failed to append sample buffer")
        }

        // Finish writing
        writerInput.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        if writer.status == .failed {
            throw StorageError.fileWriteFailed(
                path: outputURL.path,
                underlying: writer.error?.localizedDescription ?? "Unknown encoding error"
            )
        }
    }

    /// Create a CMBlockBuffer from PCM data
    private func createBlockBuffer(from data: Data) throws -> CMBlockBuffer {
        guard !data.isEmpty else {
            throw StorageError.fileWriteFailed(path: "block buffer", underlying: "Cannot create buffer from empty data")
        }

        var blockBuffer: CMBlockBuffer?
        let status = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: data.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: data.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard status == noErr, let blockBuffer = blockBuffer else {
            throw StorageError.fileWriteFailed(path: "block buffer", underlying: "Failed to create block buffer")
        }

        // Copy data into block buffer - safe to force unwrap after empty check
        let copyStatus = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            guard let baseAddress = ptr.baseAddress else {
                return OSStatus(kCMBlockBufferBadCustomBlockSourceErr)
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }

        guard copyStatus == noErr else {
            throw StorageError.fileWriteFailed(path: "block buffer", underlying: "Failed to copy data to block buffer: \(copyStatus)")
        }

        return blockBuffer
    }

    /// Delete an audio segment file
    public func deleteAudioSegment(relativePath: String) throws {
        let fileURL = storageRoot.appendingPathComponent(relativePath)
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Get the full URL for an audio segment
    public func getAudioSegmentURL(relativePath: String) -> URL {
        return storageRoot.appendingPathComponent(relativePath)
    }
}
