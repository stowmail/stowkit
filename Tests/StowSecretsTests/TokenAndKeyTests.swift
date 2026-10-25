import CryptoKit
import Foundation
import StowCore
import Testing
@testable import StowSecrets

@Suite struct TokenStoreTests {
    @Test func tokensRoundTripPerAccount() throws {
        let keychain = makeTestKeychain()
        defer { try? keychain.deleteAll() }
        let store = TokenStore(keychain: keychain)
        let alice = AccountID.generate()
        let bob = AccountID.generate()

        let tokens = OAuthTokens(accessToken: "fake-access", refreshToken: "fake-refresh",
                                 expiresAt: Date(timeIntervalSince1970: 2_000_000_000), scope: "https://mail.google.com/")
        try store.save(tokens, for: alice)
        #expect(try store.tokens(for: alice) == tokens)
        #expect(try store.tokens(for: bob) == nil)

        try store.delete(for: alice)
        #expect(try store.tokens(for: alice) == nil)
        #expect(try keychain.items().isEmpty)
    }

    @Test func keychainItemNameHoldsNoEmailAddress() {
        let id = AccountID(rawValue: "1234")
        #expect(TokenStore.itemName(for: id) == "oauth.1234")
    }

    @Test func descriptionHidesTokens() {
        let tokens = OAuthTokens(accessToken: "fake-access-value", refreshToken: "fake-refresh-value", expiresAt: nil)
        for text in [tokens.description, tokens.debugDescription, "\(tokens)", String(reflecting: tokens)] {
            #expect(!text.contains("fake-access-value"))
            #expect(!text.contains("fake-refresh-value"))
        }
    }

    @Test func refreshIsDueShortlyBeforeExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(200))
        #expect(tokens.needsRefresh(at: now))
        #expect(!tokens.needsRefresh(at: now.addingTimeInterval(-1_000)))
        #expect(!OAuthTokens(accessToken: "a", refreshToken: nil, expiresAt: nil).needsRefresh(at: now))
    }
}

@Suite struct KeyManagerTests {
    @Test func missingKeysSayWhereStowLookedAndNeverSuggestInit() {
        let wrongKeychain = KeyManagerError.keysMissing(backend: .dataProtection, service: KeychainStore.defaultService).description
        #expect(wrongKeychain.contains("data protection keychain"))
        #expect(wrongKeychain.contains("STOW_KEYCHAIN=file"))
        let testService = KeyManagerError.keysMissing(backend: .file, service: "ee.getstow.stow.dev").description
        #expect(testService.contains("STOW_KEYCHAIN_SERVICE"))
        for text in [wrongKeychain, testService] {
            #expect(text.contains("stowmail recover"))
            #expect(!text.contains("init"))
            #expect(!text.lowercased().contains("setup"))
        }
    }

    @Test func createThenLoadGivesTheSameKeys() throws {
        let keychain = makeTestKeychain()
        defer { try? keychain.deleteAll() }
        let manager = KeyManager(keychain: keychain)

        #expect(try !manager.keysExist())
        #expect(throws: KeyManagerError.keysMissing(backend: keychain.backend, service: keychain.service)) { try manager.loadKeys() }

        let created = try manager.createKeys()
        let loaded = try manager.loadKeys()
        #expect(try manager.keysExist())
        #expect(created.databaseKeyData == loaded.databaseKeyData)
        #expect(created.databaseKeyData.count == 32)
        #expect(loaded.fileKey.bitCount == 256)
        #expect(created.fileEncryptionKey == loaded.fileEncryptionKey)
    }

    @Test func existingKeysAreNeverReplaced() throws {
        let keychain = makeTestKeychain()
        defer { try? keychain.deleteAll() }
        let manager = KeyManager(keychain: keychain)
        let original = try manager.createKeys()
        #expect(throws: KeyManagerError.keysAlreadyExist) { try manager.createKeys() }
        #expect(try manager.loadKeys().databaseKeyData == original.databaseKeyData)
    }

    @Test func halfMissingKeysAreReported() throws {
        let keychain = makeTestKeychain()
        defer { try? keychain.deleteAll() }
        let manager = KeyManager(keychain: keychain)
        try manager.createKeys()
        try keychain.delete(KeyManager.fileKeyItem)
        #expect(throws: KeyManagerError.keysIncomplete) { try manager.loadKeys() }
        #expect(throws: KeyManagerError.keysIncomplete) { try manager.keysExist() }
    }

    @Test func derivedKeysDifferFromEachOtherAndFromTheirSource() {
        let keys = ArchiveKeys(databaseKey: SymmetricKey(size: .bits256), fileKey: SymmetricKey(size: .bits256))
        let raw = { (key: SymmetricKey) in key.withUnsafeBytes { Data($0) } }
        let all = [raw(keys.fileKey), raw(keys.fileEncryptionKey), raw(keys.fileNamingKey), keys.databaseKeyData]
        #expect(Set(all).count == 4)
        #expect(raw(keys.fileEncryptionKey).count == 32)
        // Derivation is deterministic: the same file key always gives the same subkeys.
        let again = ArchiveKeys(databaseKey: keys.databaseKey, fileKey: keys.fileKey)
        #expect(raw(again.fileNamingKey) == raw(keys.fileNamingKey))
    }
}
