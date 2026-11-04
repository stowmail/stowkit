import CryptoKit
import Foundation
import StowCore
import StowSecrets
import StowSync
import Testing
@testable import StowEngine
@testable import StowStore

/// Import-only accounts never sync, have no sign-in and no mailbox (D-568),
/// and imported mail is left out of the mailbox size (D-567).
@Suite(.serialized) struct ImportOnlyAccountTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stow-import-only-\(UUID().uuidString)")
    let gmail = Account(id: .generate(), provider: .gmail, email: "sam@example.com", displayName: "Sam")
    let closed = Account(id: .generate(), provider: .imported, email: "old@example.com", displayName: "Old")

    func archive() throws -> Archive {
        let archive = try Archive.open(ArchiveLocation(root: root),
                                       keys: ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256)))
        try archive.register(gmail)
        try archive.register(closed)
        return archive
    }

    @Test func itIsNeverPickedToSyncAndHasNoMailbox() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = ArchiveAccounts(archive: try archive())
        #expect(try accounts.connected().map(\.account.id) == [gmail.id])
        #expect(try accounts.all().count == 2)
        #expect(Provider.imported.rawValue == "import")
        #expect(Provider.imported.credentialKind == .none && Provider.imported.oauth == nil && !Provider.imported.syncs)
        #expect(RetentionGuide.kind(provider: .imported, email: closed.email) == nil)
        #expect(throws: SyncError.importOnly) { try ProviderProfile.forProvider(.imported) }
        #expect(throws: SyncError.importOnly) {
            try FolderPlanner.plan(provider: .imported, folders: [], capabilities: [])
        }
    }

    @Test func signingInRefusesIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = ArchiveAccounts(archive: try archive())
        let keychain = KeychainStore(service: "ee.getstow.stow.tests.\(UUID().uuidString)", backend: .file, fileVaultIsOn: { true })
        defer { try? keychain.deleteAll() }
        let tokens = TokenProvider(tokenStore: TokenStore(keychain: keychain), registry: accounts,
                                   clientFor: { _ in throw SyncError.importOnly })
        await #expect(throws: SyncError.importOnly) { _ = try await tokens.credential(for: closed.id) }
    }

    @Test func importedMailIsLeftOutOfTheMailboxSize() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try archive()
        let file = root.appendingPathComponent("Takeout.mbox")
        try Data("From 1@xxx Mon Sep 18 10:12:13 +0000 2023\r\nSubject: one\r\nMessage-ID: <one@example.org>\r\n\r\nbody\r\n\r\n".utf8).write(to: file)
        _ = try MboxImporter(archive: archive, importer: Importer(archive: archive)).run(file, account: gmail.id)
        #expect(try MailboxSize.totals(archive, account: gmail.id).messages == 0)
    }
}
