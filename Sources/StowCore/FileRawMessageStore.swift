import Foundation

/// A folder of `.eml` files that is both a `RawMessageSink` and a `RawMessageSource`.
///
/// Lets sync (Track A) and storage (Track B) meet on disk before Phase 2 joins
/// them directly. Files are **not encrypted**: this store is for development with
/// a short-lived output folder outside any repo (D-015). Directories are created
/// 0700 and files 0600 so other users on the Mac cannot read them.
///
/// Layout:
///
///     <root>/<account id>/<folder, percent-encoded>/<uidvalidity>/<uid>.eml
///     <root>/<account id>/<folder, percent-encoded>/<uidvalidity>/<uid>.json   (metadata)
///     <root>/<account id>/<folder, percent-encoded>/checkpoint.json
///
/// The `.json` file is written after the `.eml`, and both are written to a
/// temporary name and renamed into place, so a message only appears in
/// `listKeys()` once it is complete.
public actor FileRawMessageStore: RawMessageSink, RawMessageSource, SyncCheckpointStore {
    public nonisolated let root: URL
    private let fileManager = FileManager.default

    public init(root: URL) throws {
        self.root = root
        try Self.makeDirectory(root)
    }

    // MARK: RawMessageSink

    public func write(_ message: RawMessage) async throws {
        let metadataURL = metadataURL(for: message.key)
        if fileManager.fileExists(atPath: metadataURL.path) {
            return // Already stored: writes are idempotent by key.
        }
        try Self.makeDirectory(metadataURL.deletingLastPathComponent())
        try Self.writeAtomically(message.bytes, to: emlURL(for: message.key))
        let metadata = Metadata(message)
        try Self.writeAtomically(try Self.encoder.encode(metadata), to: metadataURL)
    }

    /// Every write is synced to disk before it returns, so there is nothing left to flush.
    public func flush() async throws {}

    // MARK: RawMessageSource

    public func listKeys() async throws -> [RawMessageKey] {
        var keys: [RawMessageKey] = []
        for url in Self.files(under: root)
        where url.pathExtension == "json" && url.lastPathComponent != Self.checkpointFileName {
            let metadata = try Self.decoder.decode(Metadata.self, from: Data(contentsOf: url))
            keys.append(metadata.key)
        }
        return keys.sorted()
    }

    /// Every file below `directory`. Synchronous because FileManager's
    /// enumerator cannot be iterated from async code.
    private static func files(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }
    }

    public func read(_ key: RawMessageKey) async throws -> RawMessage {
        let metadataURL = metadataURL(for: key)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw FileRawMessageStoreError.notFound(key)
        }
        let metadata = try Self.decoder.decode(Metadata.self, from: Data(contentsOf: metadataURL))
        let bytes = try Data(contentsOf: emlURL(for: key))
        return metadata.message(bytes: bytes)
    }

    // MARK: SyncCheckpointStore

    public func checkpoint(accountID: AccountID, folder: String) async throws -> SyncCheckpoint? {
        let url = folderURL(accountID: accountID, folder: folder).appendingPathComponent(Self.checkpointFileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder.decode(SyncCheckpoint.self, from: Data(contentsOf: url))
    }

    public func save(_ checkpoint: SyncCheckpoint) async throws {
        let directory = folderURL(accountID: checkpoint.accountID, folder: checkpoint.folder)
        try Self.makeDirectory(directory)
        try Self.writeAtomically(
            try Self.encoder.encode(checkpoint),
            to: directory.appendingPathComponent(Self.checkpointFileName)
        )
    }

    // MARK: Paths

    static let checkpointFileName = "checkpoint.json"

    private func folderURL(accountID: AccountID, folder: String) -> URL {
        root
            .appendingPathComponent(Self.safeComponent(accountID.rawValue), isDirectory: true)
            .appendingPathComponent(Self.safeComponent(folder), isDirectory: true)
    }

    private func messageDirectory(for key: RawMessageKey) -> URL {
        folderURL(accountID: key.accountID, folder: key.folder)
            .appendingPathComponent(String(key.uidValidity), isDirectory: true)
    }

    private func emlURL(for key: RawMessageKey) -> URL {
        messageDirectory(for: key).appendingPathComponent("\(key.uid).eml")
    }

    private func metadataURL(for key: RawMessageKey) -> URL {
        messageDirectory(for: key).appendingPathComponent("\(key.uid).json")
    }

    /// Percent-encodes everything except ASCII letters, digits, "-" and "_", so
    /// folder names such as "[Gmail]/All Mail" or "../x" become one safe path component.
    static func safeComponent(_ name: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return encoded.isEmpty ? "%" : encoded
    }

    // MARK: File helpers

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Writes to a temporary file with permissions 0600, syncs it to disk, then renames it into place.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw FileRawMessageStoreError.couldNotWrite(url.lastPathComponent)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard rename(temporary.path, url.path) == 0 else {
                throw FileRawMessageStoreError.couldNotWrite(url.lastPathComponent)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Everything in `RawMessage` except the bytes, which live in the `.eml` file.
    private struct Metadata: Codable {
        var key: RawMessageKey
        var labels: [String]
        var gmailMessageID: UInt64?
        var gmailThreadID: UInt64?
        var internalDate: Date
        var size: Int

        init(_ message: RawMessage) {
            key = message.key
            labels = message.labels
            gmailMessageID = message.gmailMessageID
            gmailThreadID = message.gmailThreadID
            internalDate = message.internalDate
            size = message.size
        }

        func message(bytes: Data) -> RawMessage {
            RawMessage(
                key: key,
                labels: labels,
                gmailMessageID: gmailMessageID,
                gmailThreadID: gmailThreadID,
                internalDate: internalDate,
                size: size,
                bytes: bytes
            )
        }
    }
}

public enum FileRawMessageStoreError: Error, CustomStringConvertible {
    case notFound(RawMessageKey)
    case couldNotWrite(String)

    public var description: String {
        switch self {
        case .notFound(let key): "No stored message for \(key)"
        case .couldNotWrite(let name): "Could not write \(name)"
        }
    }
}
