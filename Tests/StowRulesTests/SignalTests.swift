import Foundation
import StowCore
import Testing
@testable import StowRules

private func addr(_ a: String) -> EmailAddress { EmailAddress(address: a) }
private let me: Set<String> = ["sam@example.com"]

private func run(_ s: any Signal, _ h: MessageHeaders, own: Set<String> = me, threshold: Int = 20) -> SignalResult {
    s.evaluate(h, context: SignalContext(ownAddresses: own, recipientThreshold: threshold))
}

@Test func everySignalHasAnImplementation() {
    #expect(Set(Signals.all.map(\.id)) == Set(SignalID.allCases))
    for id in SignalID.allCases { #expect(Signals.signal(id).id == id) }
}

@Test func listUnsubscribe() {
    var h = MessageHeaders()
    #expect(!run(ListUnsubscribeSignal(), h).fired)
    h.listUnsubscribe = "<https://x.example/u>"
    #expect(run(ListUnsubscribeSignal(), h).fired)
    h.listUnsubscribe = "  "
    #expect(!run(ListUnsubscribeSignal(), h).fired)
}

@Test(arguments: [("bulk", true), ("list", true), ("junk", true), ("first-class", false), ("", false)])
func precedence(value: String, fires: Bool) {
    #expect(run(PrecedenceBulkSignal(), MessageHeaders(precedence: value)).fired == fires)
}

@Test func userNotInTo() {
    let s = UserNotInToSignal()
    #expect(!run(s, MessageHeaders(to: [addr("SAM@example.com")])).fired)
    #expect(run(s, MessageHeaders(to: [addr("a@x.example")], cc: [addr("sam@example.com")])).fired)
    #expect(run(s, MessageHeaders(to: [addr("a@x.example")], bcc: [addr("sam@example.com")])).fired)
    #expect(run(s, MessageHeaders(to: [addr("a@x.example")], deliveredTo: [addr("sam@example.com")])).fired)
    #expect(!run(s, MessageHeaders(to: [addr("a@x.example")])).fired)
    #expect(!run(s, MessageHeaders(cc: [addr("sam@example.com")]), own: []).fired)
}

@Test func recipientCountUsesThreshold() {
    let many = (0..<20).map { addr("p\($0)@x.example") }
    #expect(run(RecipientCountSignal(), MessageHeaders(to: many)).fired)
    #expect(!run(RecipientCountSignal(), MessageHeaders(to: Array(many.dropLast()))).fired)
    #expect(run(RecipientCountSignal(), MessageHeaders(to: Array(many.prefix(5))), threshold: 5).fired)
    // Duplicates across To and Cc count once.
    #expect(!run(RecipientCountSignal(), MessageHeaders(to: many.prefix(15) + [], cc: Array(many.prefix(15)))).fired)
}

@Test(arguments: [("noreply", true), ("No-Reply", true), ("no_reply", true), ("do.not.reply", true),
                  ("noreply+abc123", true), ("norman", false), ("reply", false), ("sam", false)])
func noReply(local: String, fires: Bool) {
    #expect(run(SenderNoReplySignal(), MessageHeaders(from: [addr("\(local)@x.example")])).fired == fires)
}

@Test func listProvider() {
    let s = SenderListProviderSignal()
    #expect(run(s, MessageHeaders(from: [addr("a@mail.mcsv.net")])).fired)
    #expect(run(s, MessageHeaders(from: [addr("a@sendgrid.net")])).fired)
    #expect(!run(s, MessageHeaders(from: [addr("a@notmcsv.net")])).fired)
    #expect(!run(s, MessageHeaders(from: [addr("a@friend.example")])).fired)
    let rp = MessageHeaders(fields: [HeaderField(name: "Return-Path", value: "<bounce-1@mail.mcsv.net>")],
                            from: [addr("a@shop.example")])
    #expect(run(s, rp).fired)
}

@Test func replyToDiffers() {
    let s = ReplyToDiffersSignal()
    #expect(run(s, MessageHeaders(from: [addr("a@x.example")], replyTo: [addr("b@y.example")])).fired)
    #expect(!run(s, MessageHeaders(from: [addr("a@x.example")], replyTo: [addr("b@X.example")])).fired)
    #expect(!run(s, MessageHeaders(from: [addr("a@x.example")])).fired)
}

@Test func missingFieldsNeverCrash() {
    for s in Signals.all { _ = run(s, MessageHeaders()) }
}
