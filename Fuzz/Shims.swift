import Foundation

// Stand-ins for the parts of EncryptedFileStore.swift that RawCompaction.swift
// names, so the fuzz target does not need the whole archive (the Keychain,
// file locations and SQLCipher). The fuzz target never calls them except `hex`,
// which is the same one-liner as the original.

struct EncryptedFileStore {
    func read(_ hash: Data) throws -> Data { Data() }
}

extension Data {
    init?(hex: String) { return nil }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
