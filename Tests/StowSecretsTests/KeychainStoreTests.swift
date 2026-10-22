import Foundation
import Security
import Testing
@testable import StowSecrets

/// A Keychain store under a throwaway service name. Tests delete everything
/// under it afterwards, and check that nothing is left behind.
func makeTestKeychain(_ backend: KeychainBackend = .file) -> KeychainStore {
    KeychainStore(service: "uk.getstow.stow.tests.\(UUID().uuidString)", backend: backend)
}

/// True when this binary may use the data protection keychain (it is signed
/// with a keychain entitlement). Unsigned `swift test` runs are not (D-012).
let dataProtectionAvailable: Bool = {
    let probe = makeTestKeychain(.dataProtection)
    defer { try? probe.deleteAll() }
    do {
        try probe.set(Data("probe".utf8), for: "probe")
        return true
    } catch {
        return false
    }
}()

@Suite struct KeychainStoreTests {
    @Test func roundTripLeavesNothingBehind() throws {
        let keychain = makeTestKeychain()
        defer { try? keychain.deleteAll() }

        #expect(try keychain.get("item") == nil)
        try keychain.set(Data("first".utf8), for: "item")
        #expect(try keychain.get("item") == Data("first".utf8))

        try keychain.set(Data("second".utf8), for: "item")
        #expect(try keychain.get("item") == Data("second".utf8))
        #expect(try keychain.items() == ["item"])

        try keychain.delete("item")
        #expect(try keychain.get("item") == nil)
        try keychain.delete("item") // Deleting twice is fine.

        try keychain.set(Data("a".utf8), for: "a")
        try keychain.set(Data("b".utf8), for: "b")
        try keychain.deleteAll()
        #expect(try keychain.items().isEmpty)
    }

    @Test func servicesAreIsolated() throws {
        let one = makeTestKeychain()
        let two = makeTestKeychain()
        defer { try? one.deleteAll(); try? two.deleteAll() }
        try one.set(Data("x".utf8), for: "shared-name")
        #expect(try two.get("shared-name") == nil)
    }

    /// Security checklist: items are ThisDeviceOnly and never synchronisable,
    /// whichever backend is used.
    @Test(arguments: KeychainBackend.allCases)
    func newItemsAreThisDeviceOnlyAndNotSynchronisable(backend: KeychainBackend) {
        let attributes = KeychainStore(service: "x", backend: backend).addAttributes(item: "i", data: Data())
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect((attributes[kSecUseDataProtectionKeychain as String] as? Bool ?? false) == (backend == .dataProtection))
    }

    @Test func backendDefaultsToDataProtection() {
        #expect(KeychainBackend.fromEnvironment([:]) == .dataProtection)
        #expect(KeychainBackend.fromEnvironment(["STOW_KEYCHAIN": "file"]) == .file)
        #expect(KeychainBackend.fromEnvironment(["STOW_KEYCHAIN": "anything-else"]) == .dataProtection)
    }

    @Test func unsignedBuildsGetAClearError() throws {
        guard !dataProtectionAvailable else { return }
        let keychain = makeTestKeychain(.dataProtection)
        #expect(throws: KeychainError.missingEntitlement) {
            try keychain.set(Data("x".utf8), for: "item")
        }
    }

    /// Runs only in a signed, entitled build (the Phase 5 app or a signed CLI).
    @Test(.enabled(if: dataProtectionAvailable, "needs a binary signed with a keychain entitlement (D-012)"))
    func dataProtectionRoundTripIsThisDeviceOnly() throws {
        let keychain = makeTestKeychain(.dataProtection)
        defer { try? keychain.deleteAll() }
        try keychain.set(Data("secret".utf8), for: "item")
        #expect(try keychain.get("item") == Data("secret".utf8))

        var query = keychain.baseQuery(item: "item")
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let stored = result as? [String: Any]
        #expect(stored?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(stored?[kSecAttrSynchronizable as String] as? Bool != true)
    }
}
