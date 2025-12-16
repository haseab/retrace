import Foundation
import AVFoundation
import Shared
import CWhisper

/// Whisper.cpp-based local transcription service
/// Uses whisper.cpp C library for on-device speech-to-text
/// Owner: PROCESSING agent
public actor WhisperCppTranscriptionService: TranscriptionProtocol {

    private var whisperContext: OpaquePointer?
    private let modelPath: String
    private let coreMLModelPath: String?
    private var isInitialized = false

    public init(modelPath: String, coreMLModelPath: String? = nil) {
        self.modelPath = modelPath
        self.coreMLModelPath = coreMLModelPath
    }

    // MARK: - Initialization

    /// Initialize whisper.cpp with the specified model
    public func initialize() async throws {
        guard !isInitialized else { return }

        // Expand ~ in paths
        let expandedPath = NSString(string: modelPath).expandingTildeInPath

        // Initialize with CoreML if available
        if let coreMLPath = coreMLModelPath {
            let expandedCoreMLPath = NSString(string: coreMLPath).expandingTildeInPath

            // Check if CoreML model exists
            if FileManager.default.fileExists(atPath: expandedCoreMLPath) {
                var params = whisper_context_default_params()
                params.use_gpu = true  // Enable Metal/CoreML acceleration

                whisperContext = whisper_init_from_file_with_params(expandedPath, params)

                if whisperContext != nil {
                    isInitialized = true
                    print("✅ Whisper.cpp initialized with CoreML acceleration: \(expandedPath)")
                    return
                }
            }
        }

        // Fallback: Load without CoreML
        whisperContext = whisper_init_from_file(expandedPath)

        guard whisperContext != nil else {
            throw TranscriptionError.modelLoadFailed("Failed to load model at: \(expandedPath)")
        }

        isInitialized = true
        print("✅ Whisper.cpp initialized with model: \(expandedPath)")
    }

    /// Cleanup
    public func cleanup() {
        if let ctx = whisperContext {
            whisper_free(ctx)
            whisperContext = nil
        }
        isInitialized = false
    }

    // MARK: - Transcription

    /// Transcribe audio data (must be 16kHz mono Float32 or PCM Int16)
    public func transcribe(_ audioData: Data) async throws -> TranscriptionResult {
        guard isInitialized else {
            throw TranscriptionError.notInitialized
        }

        guard let ctx = whisperContext else {
            throw TranscriptionError.notInitialized
        }

        // Convert PCM Int16 to Float32 for whisper.cpp
        let samples = convertToFloat32(audioData)

        // Call whisper.cpp with default parameters
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        let result = samples.withUnsafeBufferPointer { samplesPtr in
            whisper_full(ctx, params, samplesPtr.baseAddress, Int32(samples.count))
        }

        guard result == 0 else {
            throw TranscriptionError.transcriptionFailed
        }

        // Get transcription text
        let numSegments = whisper_full_n_segments(ctx)
        var fullText = ""

        for i in 0..<numSegments {
            if let segmentText = whisper_full_get_segment_text(ctx, i) {
                fullText += String(cString: segmentText)
            }
        }

        // Get detected language
        let langId = whisper_full_lang_id(ctx)
        let language = String(cString: whisper_lang_str(langId))

        return TranscriptionResult(
            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: 0.0,  // whisper.cpp doesn't provide overall confidence
            language: language,
            duration: Double(samples.count) / 16000.0
        )
    }

    /// Transcribe with word-level timestamps
    public func transcribeWithTimestamps(_ audioData: Data, wordLevel: Bool = false) async throws -> DetailedTranscriptionResult {
        guard isInitialized else {
            throw TranscriptionError.notInitialized
        }

        guard let ctx = whisperContext else {
            throw TranscriptionError.notInitialized
        }

        let samples = convertToFloat32(audioData)

        // Configure whisper.cpp for word-level timestamps
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_timestamps = wordLevel
        params.token_timestamps = wordLevel
        params.max_len = 0  // Don't limit segment length

        // Run transcription
        let result = samples.withUnsafeBufferPointer { samplesPtr in
            whisper_full(ctx, params, samplesPtr.baseAddress, Int32(samples.count))
        }

        guard result == 0 else {
            throw TranscriptionError.transcriptionFailed
        }

        var words: [TranscriptionWord] = []
        var fullText = ""

        // Extract word-level timestamps from tokens within each segment
        let numSegments = whisper_full_n_segments(ctx)
        for segmentIdx in 0..<numSegments {
            guard let segmentText = whisper_full_get_segment_text(ctx, segmentIdx) else {
                continue
            }
            fullText += String(cString: segmentText)

            if wordLevel {
                // Get tokens for this segment
                let numTokens = whisper_full_n_tokens(ctx, segmentIdx)

                var currentWord = ""
                var wordStartTime: Double? = nil

                for tokenIdx in 0..<numTokens {
                    let tokenData = whisper_full_get_token_data(ctx, segmentIdx, tokenIdx)

                    // Get token text
                    guard let tokenTextPtr = whisper_full_get_token_text(ctx, segmentIdx, tokenIdx) else {
                        continue
                    }
                    let tokenText = String(cString: tokenTextPtr)

                    // Get token timestamps (in centiseconds)
                    let t0 = Double(tokenData.t0) / 100.0
                    let t1 = Double(tokenData.t1) / 100.0

                    // Word boundary detection: whisper tokens starting with space indicate new word
                    if tokenText.hasPrefix(" ") || tokenText.hasPrefix("\n") {
                        // Save previous word if exists
                        if !currentWord.isEmpty, let startTime = wordStartTime {
                            words.append(TranscriptionWord(
                                word: currentWord.trimmingCharacters(in: .whitespacesAndNewlines),
                                start: startTime,
                                end: t0,
                                confidence: Double(tokenData.p)
                            ))
                        }
                        // Start new word
                        currentWord = tokenText.trimmingCharacters(in: .whitespaces)
                        wordStartTime = t0
                    } else {
                        // Continue current word
                        currentWord += tokenText
                        if wordStartTime == nil {
                            wordStartTime = t0
                        }
                    }

                    // Save last word at end of segment
                    if tokenIdx == numTokens - 1 && !currentWord.isEmpty, let startTime = wordStartTime {
                        words.append(TranscriptionWord(
                            word: currentWord.trimmingCharacters(in: .whitespacesAndNewlines),
                            start: startTime,
                            end: t1,
                            confidence: Double(tokenData.p)
                        ))
                    }
                }
            }
        }

        // Get detected language
        let langId = whisper_full_lang_id(ctx)
        let language = String(cString: whisper_lang_str(langId))

        return DetailedTranscriptionResult(
            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            words: words,
            language: language,
            duration: Double(samples.count) / 16000.0
        )
    }

    // MARK: - Helper Methods

    /// Convert PCM Int16 to Float32 for whisper.cpp
    private func convertToFloat32(_ audioData: Data) -> [Float] {
        let int16Count = audioData.count / 2
        var samples = [Float](repeating: 0, count: int16Count)

        audioData.withUnsafeBytes { bufferPointer in
            let int16Buffer = bufferPointer.bindMemory(to: Int16.self)
            for i in 0..<int16Count {
                samples[i] = Float(int16Buffer[i]) / 32768.0
            }
        }

        return samples
    }
}

