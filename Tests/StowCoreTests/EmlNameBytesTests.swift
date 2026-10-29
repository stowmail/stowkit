import Foundation
import StowCore
import Testing

/// A-21: `.eml` names are measured in bytes, since the file system's limit is
/// 255 bytes of UTF-8, not 120 characters.
@Suite struct EmlNameBytesTests {
    static let subjects: [String] = [
        String(repeating: "請求書の確認", count: 20),                          // 120 CJK characters, 360 bytes
        String(repeating: "👨‍👩‍👧‍👦🎉", count: 40),                              // 80 emoji, ZWJ families among them
        String(repeating: "a", count: 300),
    ]

    @Test(arguments: subjects)
    func longSubjectsAreSavedUnderABoundedName(subject: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stow-eml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = EmlFileName.make(date: Date(timeIntervalSince1970: 1_790_000_000), subject: subject,
                                    sender: EmailAddress(name: "Sender", address: "s@example.com"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(name.utf8.count <= 240)
        #expect(name.hasSuffix(".eml"))
        // Cut between characters: the name before ".eml" starts with the subject's own characters
        // (as file names already show them: a joiner becomes a dash), never part of one.
        let shown = String(String.UnicodeScalarView(subject.unicodeScalars.map { $0 == "\u{200D}" ? "-" : $0 }))
        let stem = String(name.dropFirst("2026-09-21 ".count).dropLast(".eml".count))
        #expect(shown.hasPrefix(stem) || stem.hasPrefix(shown), "name: \(name)")
        // Written, and again under a numbered name that also fits.
        for _ in 0..<12 {
            let url = try await SafeFile.write(into: folder, name: name) { try $0.write(contentsOf: Data("x".utf8)) }
            #expect(url.lastPathComponent.utf8.count <= 240)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".eml") }.count == 12)
    }

    @Test func numberedNamesStayWithinTheLimit() {
        let long = String(repeating: "請", count: 78) + ".eml"   // 238 bytes
        for number in [2, 10, 999] {
            let numbered = SafeFile.numbered(long, number)
            #expect(numbered.utf8.count <= 240)
            #expect(numbered.hasSuffix(" \(number).eml"))
        }
        #expect(SafeFile.numbered("Invoice.eml", 2) == "Invoice 2.eml")
    }
}
