import Foundation

/// Relative paths inside the App Group container. Only relative paths are ever stored;
/// they are resolved against the container at runtime because container paths change.
public enum BookPaths {
    public static let booksDirectory = "Books"
    public static let coversDirectory = "Covers"
    public static let databaseRelpath = "Database/margins.sqlite"

    /// "Books/<hash>.epub"
    public static func bookRelpath(contentHash: String) -> String {
        "\(booksDirectory)/\(contentHash).epub"
    }

    /// "Covers/<hash>.png"
    public static func coverRelpath(contentHash: String) -> String {
        "\(coversDirectory)/\(contentHash).png"
    }

    public static func resolve(_ relpath: String, in container: URL) -> URL {
        container.appendingPathComponent(relpath, isDirectory: false)
    }
}
