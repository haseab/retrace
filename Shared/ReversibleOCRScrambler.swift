import CoreGraphics
import CryptoKit
import Foundation

/// Deterministic block-permutation scrambler for OCR regions.
/// The same key + frameID + nodeID always produces the same permutation.
public enum ReversibleOCRScrambler {
    private static let legacyProtectedTextPrefix = "rtx1."
    private static let currentProtectedTextPrefix = "rtx2."
    public static let settingsSuiteName = "io.retrace.app"

    /// Returns the current scramble secret derived from the Keychain-backed
    /// master key. Protected features must provision the master key before
    /// calling into scrambling.
    public static func currentAppWideSecret() -> String? {
        MasterKeyManager.currentScrambleSecret()
    }

    public static func legacyAppWideSecret() -> String? {
        MasterKeyManager.legacyScrambleSecret()
    }

    public static func shouldUseLegacySecret(for encryptedText: String?) -> Bool {
        guard let encryptedText else { return false }
        return !encryptedText.hasPrefix(currentProtectedTextPrefix)
    }

    public static func appWideSecret() -> String {
        guard let masterKeySecret = currentAppWideSecret() else {
            preconditionFailure("Master key must exist before OCR scrambling is used.")
        }
        return masterKeySecret
    }

    public static func scramblePatchBGRA(
        _ patch: inout Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        frameID: Int64,
        nodeID: Int,
        secret: String
    ) {
        applyPermutation(
            patch: &patch,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            frameID: frameID,
            nodeID: nodeID,
            secret: secret,
            inverse: false
        )
    }

    public static func descramblePatchBGRA(
        _ patch: inout Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        frameID: Int64,
        nodeID: Int,
        secret: String
    ) {
        applyPermutation(
            patch: &patch,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            frameID: frameID,
            nodeID: nodeID,
            secret: secret,
            inverse: true
        )
    }

    /// Backward-compatible descramble for patches scrambled by the original
    /// fixed block-size permutation implementation.
    public static func descramblePatchBGRALegacy(
        _ patch: inout Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        frameID: Int64,
        nodeID: Int,
        secret: String
    ) {
        applyPermutationLegacy(
            patch: &patch,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            frameID: frameID,
            nodeID: nodeID,
            secret: secret,
            inverse: true
        )
    }

    public static func encryptOCRText(
        _ text: String,
        frameID: Int64,
        nodeOrder: Int,
        secret: String
    ) -> String? {
        guard !text.isEmpty else { return text }

        do {
            let sealedBox = try AES.GCM.seal(
                Data(text.utf8),
                using: textProtectionKey(frameID: frameID, nodeOrder: nodeOrder, secret: secret)
            )
            guard let combined = sealedBox.combined else { return nil }
            return currentProtectedTextPrefix + base64URLEncode(combined)
        } catch {
            return nil
        }
    }

    public static func decryptOCRText(
        _ encryptedText: String,
        frameID: Int64,
        nodeOrder: Int,
        secret: String,
        legacySecret: String? = nil
    ) -> String? {
        let secretsToTry = candidateSecrets(
            for: encryptedText,
            currentSecret: secret,
            legacySecret: legacySecret
        )
        let candidateFrameIDs: [Int64] = frameID == 0 ? [0] : [frameID, 0]
        for candidateFrameID in candidateFrameIDs {
            for candidateSecret in secretsToTry {
                if let plaintext = decryptOCRText(
                    encryptedText,
                    exactFrameID: candidateFrameID,
                    nodeOrder: nodeOrder,
                    secret: candidateSecret
                ) {
                    return plaintext
                }
            }
        }
        return nil
    }

    private static func decryptOCRText(
        _ encryptedText: String,
        exactFrameID frameID: Int64,
        nodeOrder: Int,
        secret: String
    ) -> String? {
        if let prefix = protectedTextPrefix(for: encryptedText) {
            return decryptProtectedOCRText(
                encryptedText,
                prefix: prefix,
                exactFrameID: frameID,
                nodeOrder: nodeOrder,
                secret: secret
            )
        }

        // Backward compatibility for permutation-only payloads written by
        // earlier local iterations of this change before AES-GCM was restored.
        return revealOCRText(
            encryptedText,
            frameID: frameID,
            nodeOrder: nodeOrder,
            secret: secret
        )
    }

    private static func concealOCRText(
        _ text: String,
        frameID: Int64,
        nodeOrder: Int,
        secret: String
    ) -> String? {
        let characters = Array(text)
        let count = characters.count
        guard count > 1 else { return text }

        let permutation = textPermutation(
            count: count,
            frameID: frameID,
            nodeOrder: nodeOrder,
            secret: secret
        )
        var concealed = Array(repeating: Character(" "), count: count)
        for (sourceIndex, destinationIndex) in permutation.enumerated() {
            concealed[destinationIndex] = characters[sourceIndex]
        }
        return String(concealed)
    }

    private static func revealOCRText(
        _ concealedText: String,
        frameID: Int64,
        nodeOrder: Int,
        secret: String
    ) -> String? {
        let characters = Array(concealedText)
        let count = characters.count
        guard count > 1 else { return concealedText }

        let permutation = textPermutation(
            count: count,
            frameID: frameID,
            nodeOrder: nodeOrder,
            secret: secret
        )
        var plaintext = Array(repeating: Character(" "), count: count)
        for (sourceIndex, destinationIndex) in permutation.enumerated() {
            plaintext[sourceIndex] = characters[destinationIndex]
        }
        return String(plaintext)
    }

    private static func decryptProtectedOCRText(
        _ encryptedText: String,
        prefix: String,
        exactFrameID frameID: Int64,
        nodeOrder: Int,
        secret: String
    ) -> String? {
        let encodedPayload = String(encryptedText.dropFirst(prefix.count))
        guard let combined = base64URLDecode(encodedPayload) else { return nil }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(
                sealedBox,
                using: textProtectionKey(frameID: frameID, nodeOrder: nodeOrder, secret: secret)
            )
            return String(data: plaintext, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func applyPermutation(
        patch: inout Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        frameID: Int64,
        nodeID: Int,
        secret: String,
        inverse: Bool
    ) {
        guard width > 1, height > 1, bytesPerRow >= width * 4 else { return }
        guard let blockLayout = blockLayoutForPatch(width: width, height: height) else { return }

        let blockWidth = blockLayout.width
        let blockHeight = blockLayout.height
        let blocksX = width / blockWidth
        let blocksY = height / blockHeight
        let blockCount = blocksX * blocksY
        guard blockCount > 1 else { return }

        let seed = seededValue(
            frameID: frameID,
            nodeID: nodeID,
            width: width,
            height: height,
            blockWidth: blockWidth,
            blockHeight: blockHeight,
            secret: secret
        )
        let permutation = shuffledIndices(count: blockCount, seed: seed)
        let mapping: [Int]
        if inverse {
            var inverseMap = Array(repeating: 0, count: blockCount)
            for (source, destination) in permutation.enumerated() {
                inverseMap[destination] = source
            }
            mapping = inverseMap
        } else {
            mapping = permutation
        }

        let rowBytes = blockWidth * 4
        let blockBufferSize = rowBytes * blockHeight
        guard blockBufferSize > 0 else { return }

        var output = patch
        patch.withUnsafeBytes { inputRaw in
            output.withUnsafeMutableBytes { outputRaw in
                guard let inputBase = inputRaw.baseAddress,
                      let outputBase = outputRaw.baseAddress else {
                    return
                }

                for blockIndex in 0..<blockCount {
                    let destinationIndex = mapping[blockIndex]
                    let srcBlockX = blockIndex % blocksX
                    let srcBlockY = blockIndex / blocksX
                    let dstBlockX = destinationIndex % blocksX
                    let dstBlockY = destinationIndex / blocksX

                    let srcX = srcBlockX * blockWidth
                    let srcY = srcBlockY * blockHeight
                    let dstX = dstBlockX * blockWidth
                    let dstY = dstBlockY * blockHeight

                    for row in 0..<blockHeight {
                        let srcOffset = (srcY + row) * bytesPerRow + (srcX * 4)
                        let dstOffset = (dstY + row) * bytesPerRow + (dstX * 4)
                        memcpy(
                            outputBase.advanced(by: dstOffset),
                            inputBase.advanced(by: srcOffset),
                            rowBytes
                        )
                    }
                }
            }
        }

        patch = output
    }

    private static func textProtectionKey(
        frameID: Int64,
        nodeOrder: Int,
        secret: String
    ) -> SymmetricKey {
        let material = Data("ocr-text|\(frameID)|\(nodeOrder)|\(secret)".utf8)
        let digest = SHA256.hash(data: material)
        return SymmetricKey(data: Data(digest))
    }

    private static func textPermutation(
        count: Int,
        frameID: Int64,
        nodeOrder: Int,
        secret: String
    ) -> [Int] {
        guard count > 1 else { return Array(0..<count) }

        let material = "ocr-conceal|\(frameID)|\(nodeOrder)|\(count)|\(secret)"
        let digest = SHA256.hash(data: Data(material.utf8))
        var seed: UInt64 = 0
        for (index, byte) in digest.prefix(8).enumerated() {
            seed |= UInt64(byte) << (UInt64(index) * 8)
        }

        var permutation = shuffledIndices(count: count, seed: seed)
        if permutation == Array(0..<count) {
            permutation = Array(1..<count) + [0]
        }
        return permutation
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        return Data(base64Encoded: base64)
    }

    private static func protectedTextPrefix(for encryptedText: String) -> String? {
        if encryptedText.hasPrefix(currentProtectedTextPrefix) {
            return currentProtectedTextPrefix
        }
        if encryptedText.hasPrefix(legacyProtectedTextPrefix) {
            return legacyProtectedTextPrefix
        }
        return nil
    }

    private static func candidateSecrets(
        for encryptedText: String,
        currentSecret: String,
        legacySecret: String?
    ) -> [String] {
        if encryptedText.hasPrefix(currentProtectedTextPrefix) {
            return [currentSecret]
        }

        if encryptedText.hasPrefix(legacyProtectedTextPrefix) {
            return [legacySecret ?? currentSecret]
        }

        var secrets = [currentSecret]
        if let legacySecret, legacySecret != currentSecret {
            secrets.append(legacySecret)
        }
        return secrets
    }

    private static func applyPermutationLegacy(
        patch: inout Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        frameID: Int64,
        nodeID: Int,
        secret: String,
        inverse: Bool
    ) {
        guard width > 1, height > 1, bytesPerRow >= width * 4 else { return }
        let blockSize = blockSizeForLegacyPatch(width: width, height: height)
        guard blockSize >= 2 else { return }

        let blocksX = width / blockSize
        let blocksY = height / blockSize
        let blockCount = blocksX * blocksY
        guard blockCount > 1 else { return }

        let seed = seededValueLegacy(
            frameID: frameID,
            nodeID: nodeID,
            width: width,
            height: height,
            blockSize: blockSize,
            secret: secret
        )
        let permutation = shuffledIndices(count: blockCount, seed: seed)
        let mapping: [Int]
        if inverse {
            var inverseMap = Array(repeating: 0, count: blockCount)
            for (source, destination) in permutation.enumerated() {
                inverseMap[destination] = source
            }
            mapping = inverseMap
        } else {
            mapping = permutation
        }

        let rowBytes = blockSize * 4
        guard rowBytes > 0 else { return }

        var output = patch
        patch.withUnsafeBytes { inputRaw in
            output.withUnsafeMutableBytes { outputRaw in
                guard let inputBase = inputRaw.baseAddress,
                      let outputBase = outputRaw.baseAddress else {
                    return
                }

                for blockIndex in 0..<blockCount {
                    let destinationIndex = mapping[blockIndex]
                    let srcBlockX = blockIndex % blocksX
                    let srcBlockY = blockIndex / blocksX
                    let dstBlockX = destinationIndex % blocksX
                    let dstBlockY = destinationIndex / blocksX

                    let srcX = srcBlockX * blockSize
                    let srcY = srcBlockY * blockSize
                    let dstX = dstBlockX * blockSize
                    let dstY = dstBlockY * blockSize

                    for row in 0..<blockSize {
                        let srcOffset = (srcY + row) * bytesPerRow + (srcX * 4)
                        let dstOffset = (dstY + row) * bytesPerRow + (dstX * 4)
                        memcpy(
                            outputBase.advanced(by: dstOffset),
                            inputBase.advanced(by: srcOffset),
                            rowBytes
                        )
                    }
                }
            }
        }

        patch = output
    }

    private static func blockLayoutForPatch(width: Int, height: Int) -> (width: Int, height: Int)? {
        let blockWidth = bestBlockDimension(for: width)
        let blockHeight = bestBlockDimension(for: height)
        let blocksX = width / blockWidth
        let blocksY = height / blockHeight
        guard blocksX * blocksY > 1 else { return nil }
        return (blockWidth, blockHeight)
    }

    private static func bestBlockDimension(for length: Int) -> Int {
        guard length > 1 else { return 1 }

        // Prefer block sizes that tend to preserve compression robustness.
        let preferred = [16, 12, 10, 8, 6, 5, 4, 3, 2]
        for candidate in preferred where length >= candidate && length.isMultiple(of: candidate) {
            return candidate
        }

        // Fall back to any divisor <= 16 before pixel-level blocks.
        let maxCandidate = min(16, length)
        guard maxCandidate >= 2 else { return 1 }
        for candidate in stride(from: maxCandidate, through: 2, by: -1) where length.isMultiple(of: candidate) {
            return candidate
        }

        return 1
    }

    private static func blockSizeForLegacyPatch(width: Int, height: Int) -> Int {
        let minDimension = min(width, height)
        if minDimension >= 32 { return 16 }
        if minDimension >= 16 { return 8 }
        if minDimension >= 8 { return 4 }
        if minDimension >= 4 { return 2 }
        return 1
    }

    private static func seededValue(
        frameID: Int64,
        nodeID: Int,
        width: Int,
        height: Int,
        blockWidth: Int,
        blockHeight: Int,
        secret: String
    ) -> UInt64 {
        let material = "\(secret)|\(frameID)|\(nodeID)|\(width)x\(height)|bw\(blockWidth)|bh\(blockHeight)"
        let digest = SHA256.hash(data: Data(material.utf8))
        var seed: UInt64 = 0
        for (index, byte) in digest.prefix(8).enumerated() {
            seed |= UInt64(byte) << (UInt64(index) * 8)
        }
        return seed
    }

    private static func seededValueLegacy(
        frameID: Int64,
        nodeID: Int,
        width: Int,
        height: Int,
        blockSize: Int,
        secret: String
    ) -> UInt64 {
        let material = "\(secret)|\(frameID)|\(nodeID)|\(width)x\(height)|b\(blockSize)"
        let digest = SHA256.hash(data: Data(material.utf8))
        var seed: UInt64 = 0
        for (index, byte) in digest.prefix(8).enumerated() {
            seed |= UInt64(byte) << (UInt64(index) * 8)
        }
        return seed
    }

    private static func shuffledIndices(count: Int, seed: UInt64) -> [Int] {
        guard count > 1 else { return Array(0..<count) }
        var result = Array(0..<count)
        var generator = SplitMix64(state: seed == 0 ? 0x9E3779B97F4A7C15 : seed)

        var i = count - 1
        while i > 0 {
            let j = Int(generator.next() % UInt64(i + 1))
            if i != j {
                result.swapAt(i, j)
            }
            i -= 1
        }

        return result
    }
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
