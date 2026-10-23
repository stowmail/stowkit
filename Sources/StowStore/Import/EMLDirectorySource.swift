import Foundation
import StowCore

/// A `RawMessageSource` over a plain folder of `.eml` files, for development
/// and benchmarks (for example `stowmail import --eml engine/Tests/Fixtures/eml`).
///
/// Messages are assigned to one account and a folder named "Imported", with
/// UIDs in file name order. The arrival date is the Date header when it
/// parses, else the file's modification date.
public struct EMLDirectorySource: RawMessageSource {
    public let directory: URL
    public let accountID: AccountID
    public static let folder = "Imported"
    private let files: [URL]

    public init(directory: URL, accountID: AccountID) throws {
        self.directory = directory
        self.accountID = accountID
        files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension.lowercased() == "eml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func listKeys() async throws -> [RawMessageKey] {
        files.indices.map { RawMessageKey(accountID: accountID, folder: Self.folder, uidValidity: 1, uid: UInt32($0 + 1)) }
    }

    public func read(_ key: RawMessageKey) async throws -> RawMessage {
        let index = Int(key.uid) - 1
        guard key.accountID == accountID, files.indices.contains(index) else { throw CocoaError(.fileNoSuchFile) }
        let url = files[index]
        let bytes = try Data(contentsOf: url)
        let date = HeaderParser().parseHeaders(bytes).date
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date()
        return RawMessage(key: key, internalDate: date, size: bytes.count, bytes: bytes)
    }
}
