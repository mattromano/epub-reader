import CryptoKit
import Foundation
import Testing
@testable import Importing

@Suite struct ContentHasherTests {
    private func tempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    @Test func sha256OfABC() throws {
        let url = try tempFile(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ContentHasher.sha256Hex(fileAt: url)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func sha256OfEmptyFile() throws {
        let url = try tempFile(Data())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ContentHasher.sha256Hex(fileAt: url)
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func sha256SpanningMultipleChunks() throws {
        // NIST vector: 1,000,000 x "a" (under one chunk).
        let data = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        let url = try tempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ContentHasher.sha256Hex(fileAt: url)
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")

        let big = Data(repeating: 0x5A, count: ContentHasher.chunkSize * 2 + 17)
        let bigURL = try tempFile(big)
        defer { try? FileManager.default.removeItem(at: bigURL) }
        // Crosses two 1 MiB chunk boundaries; must equal a single-shot hash of the same bytes.
        let oneShot = SHA256.hash(data: big).map { String(format: "%02x", $0) }.joined()
        #expect(try ContentHasher.sha256Hex(fileAt: bigURL) == oneShot)
    }

    @Test func missingFileThrows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { try ContentHasher.sha256Hex(fileAt: url) }
    }
}

@Suite struct BookPathsTests {
    @Test func relativePaths() {
        #expect(BookPaths.booksDirectory == "Books")
        #expect(BookPaths.coversDirectory == "Covers")
        #expect(BookPaths.databaseRelpath == "Database/margins.sqlite")
        #expect(BookPaths.bookRelpath(contentHash: "deadbeef") == "Books/deadbeef.epub")
        #expect(BookPaths.coverRelpath(contentHash: "deadbeef") == "Covers/deadbeef.png")
    }

    @Test func resolveAgainstContainer() {
        let container = URL(fileURLWithPath: "/tmp/group.container", isDirectory: true)
        let url = BookPaths.resolve("Books/deadbeef.epub", in: container)
        #expect(url.path == "/tmp/group.container/Books/deadbeef.epub")
    }
}
