import CryptoKit
import Foundation

public enum ContentHasher {
    static let chunkSize = 1 << 20  // 1 MiB

    /// Streaming SHA-256 (CryptoKit, 1 MiB chunks), lowercase hex. Never loads the whole file.
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk: Data? = try autoreleasepool {
                try handle.read(upToCount: chunkSize)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
