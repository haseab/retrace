import Foundation
import zlib

extension FeedbackService {
    static func gzipCompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            MAX_MEM_LEVEL,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )

        guard initStatus == Z_OK else {
            throw FeedbackError.invalidData
        }
        defer {
            deflateEnd(&stream)
        }

        let chunkSize = 64 * 1024
        var compressed = Data()
        compressed.reserveCapacity(Int(deflateBound(&stream, uLong(data.count))))
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)
        var compressionStatus: Int32 = Z_OK

        try data.withUnsafeBytes { rawInputBuffer in
            guard let inputBaseAddress = rawInputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                throw FeedbackError.invalidData
            }

            stream.next_in = UnsafeMutablePointer(mutating: inputBaseAddress)
            stream.avail_in = uInt(data.count)

            repeat {
                let produced: Int = try outputBuffer.withUnsafeMutableBytes { rawOutputBuffer in
                    guard let outputBaseAddress = rawOutputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                        throw FeedbackError.invalidData
                    }

                    stream.next_out = outputBaseAddress
                    stream.avail_out = uInt(chunkSize)
                    compressionStatus = deflate(&stream, Z_FINISH)

                    guard compressionStatus == Z_OK || compressionStatus == Z_STREAM_END else {
                        throw FeedbackError.invalidData
                    }

                    return chunkSize - Int(stream.avail_out)
                }

                if produced > 0 {
                    compressed.append(outputBuffer, count: produced)
                }
            } while compressionStatus != Z_STREAM_END
        }

        return compressed
    }
}
