import Foundation
import Testing
@testable import StowCore

@Suite struct RedactionTests {
    @Test func addressesAreHashedNotShown() {
        let redacted = Redact.address("Sam.Taylor@Example.com")
        #expect(!redacted.contains("@"))
        #expect(!redacted.lowercased().contains("sam"))
        #expect(!redacted.lowercased().contains("example"))
        #expect(redacted.hasPrefix("addr:"))
        #expect(redacted.count == "addr:".count + 8)
    }

    @Test func addressHashIsStableWithinARunAndIgnoresCase() {
        #expect(Redact.address("sam@example.com") == Redact.address(" SAM@example.COM "))
        #expect(Redact.address("sam@example.com") != Redact.address("alex@example.com"))
        #expect(Redact.address(EmailAddress(name: "Sam", address: "sam@example.com")) == Redact.address("sam@example.com"))
    }

    @Test func tokensAreNeverShown() {
        let token = "ya29.a0AfB_byC-secret-value"
        let redacted = Redact.token(token)
        #expect(!redacted.contains("ya29"))
        #expect(!redacted.contains("secret"))
    }

    @Test func subjectsAreNeverShown() {
        #expect(Redact.subject("Your test results") == "[subject redacted]")
        #expect(Redact.subject(nil) == "[no subject]")
    }

    @Test func bodiesAreNeverShown() {
        let body = "Dear Sam, the password is hunter2"
        let redacted = Redact.body(body)
        #expect(!redacted.contains("hunter2"))
        #expect(!redacted.contains("Sam"))
        #expect(redacted == "[body redacted, \(body.utf8.count) bytes]")
    }

    @Test(arguments: [
        ("Authorization: Bearer ya29.a0AfB_byCsecret", "ya29"),
        ("Authorization: Bearer opaque-token-123", "opaque-token-123"),
        ("{\"access_token\": \"abc123secret\", \"expires_in\": 3599}", "abc123secret"),
        ("refresh_token=1//0gSecretRefresh&grant_type=refresh_token", "0gSecretRefresh"),
        ("error: invalid code=4/0AbCdEfSecret", "0AbCdEfSecret"), // gitleaks:allow (fake value)
        ("client_secret=GOCSPX-notreallysecret", "GOCSPX"),
        ("id eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJl", "eyJhbGci"),
        ("token 1//0gAbCdEfGhIjKlMnOp-rest", "AbCdEfGhIjKlMnOp"),
        ("A1 AUTHENTICATE XOAUTH2 dXNlcj1zYW1AZXhhbXBsZS5jb20BYXV0aD1CZWFyZXIgeWEyOS5zZWNyZXQBAQ==", "dXNlcj1z"),
        ("NO [AUTHENTICATIONFAILED] for sam@example.com", "sam@example.com"),
    ])
    func scrubRemovesSecretsAndAddresses(input: String, secret: String) {
        let scrubbed = Redact.scrub(input)
        #expect(!scrubbed.contains(secret), "\(scrubbed)")
    }

    @Test func scrubKeepsOrdinaryText() {
        let text = "Connection reset after 3 retries (timeout 30s); decode: ok"
        #expect(Redact.scrub(text) == text)
    }

    @Test func scrubReplacesAddressesWithTheirHash() {
        let scrubbed = Redact.scrub("from sam@example.com to alex@example.org")
        #expect(scrubbed == "from \(Redact.address("sam@example.com")) to \(Redact.address("alex@example.org"))")
    }
}
