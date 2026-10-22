import Foundation
import Testing
@testable import StowCore

@Suite struct ContractTests {
    @Test func emailAddressParts() {
        let address = EmailAddress(name: "Sam", address: " Sam.Taylor@Mail.Example.COM ")
        #expect(address.normalised == "sam.taylor@mail.example.com")
        #expect(address.domain == "mail.example.com")
        #expect(address.localPart == "sam.taylor")
        #expect(EmailAddress(address: "no-at-sign").domain == "")
    }

    @Test func headerLookupIsCaseInsensitive() {
        let headers = MessageHeaders(fields: [
            HeaderField(name: "List-Unsubscribe", value: "<mailto:u@example.com>"),
            HeaderField(name: "Received", value: "one"),
            HeaderField(name: "RECEIVED", value: "two"),
        ])
        #expect(headers.value(named: "list-unsubscribe") == "<mailto:u@example.com>")
        #expect(headers.values(named: "Received") == ["one", "two"])
        #expect(headers.value(named: "Precedence") == nil)
    }

    @Test func recipientCountIgnoresDuplicates() {
        let headers = MessageHeaders(
            to: [EmailAddress(address: "a@example.com"), EmailAddress(address: "B@example.com")],
            cc: [EmailAddress(address: "b@example.com")],
            bcc: [EmailAddress(address: "c@example.com")]
        )
        #expect(headers.recipientCount == 3)
    }

    @Test func rawMessageKeyDescriptionLeavesOutFolderName() {
        let key = RawMessageKey(accountID: AccountID(rawValue: "a1"), folder: "Private/Medical", uidValidity: 3, uid: 9)
        #expect(key.description == "a1/v3/9")
    }

    @Test func accountIDsAreRandomAndCodableAsPlainStrings() throws {
        let id = AccountID.generate()
        #expect(id != AccountID.generate())
        let json = try JSONEncoder().encode(id)
        #expect(String(decoding: json, as: UTF8.self) == "\"\(id.rawValue)\"")
        #expect(try JSONDecoder().decode(AccountID.self, from: json) == id)
    }

    @Test func searchQueryDefaults() {
        let query = SearchQuery(text: "invoice")
        #expect(query.limit == 50)
        #expect(query.accounts.isEmpty)
        #expect(query.hasAttachment == nil)
    }
}
