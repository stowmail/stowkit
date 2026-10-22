// Generates synthetic .eml fixtures into Tests/Fixtures/eml/ (Phase 0, step 7; D-018).
//
// Every message is invented. Addresses use the reserved example.com,
// example.org and example.net domains. Run through scripts/make-fixtures.
//
// Output:
//   Tests/Fixtures/eml/*.eml          one file per case
//   Tests/Fixtures/eml/manifest.json  what each file covers, for tests

import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// MARK: - Setup

let engineRoot = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let outputDirectory = engineRoot.appendingPathComponent("Tests/Fixtures/eml", isDirectory: true)

/// The archive owner in every fixture.
let owner = "sam@example.com"
let ownerHeader = "Sam Taylor <\(owner)>"
let crlf = "\r\n"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-fixtures: \(message)\n".utf8))
    exit(1)
}

/// Deterministic random bytes (SplitMix64), so the large attachment is the same on every run.
struct SeededGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func bytes(_ count: Int) -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            var value = next()
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0.prefix(count - data.count)) }
        }
        return data
    }
}

// MARK: - MIME building

/// A MIME entity: headers plus a body that is already encoded for transfer.
struct Part {
    var headers: [(String, String)]
    var body: Data

    func serialised() -> Data {
        var data = Data()
        for (name, value) in headers {
            data.append(Data("\(name): \(value)\(crlf)".utf8))
        }
        data.append(Data(crlf.utf8))
        data.append(body)
        return data
    }
}

func base64Body(_ data: Data) -> Data {
    Data((data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + crlf).utf8)
}

func crlfText(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: crlf)
}

func textPart(_ text: String, subtype: String = "plain", charset: String = "utf-8") -> Part {
    Part(headers: [
        ("Content-Type", "text/\(subtype); charset=\(charset)"),
        ("Content-Transfer-Encoding", subtype != "plain" ? "quoted-printable" : text.allSatisfy(\.isASCII) ? "7bit" : "8bit"),
    ], body: Data(crlfText(subtype == "plain" ? text : quotedPrintable(text)).utf8))
}

/// Minimal quoted-printable encoding for UTF-8 text (RFC 2045 section 6.7).
func quotedPrintable(_ text: String) -> String {
    var lines: [String] = []
    for line in text.components(separatedBy: "\n") {
        var encoded = ""
        var length = 0
        for byte in Array(line.utf8) {
            let piece: String
            if (byte >= 33 && byte <= 126 && byte != 61) || byte == 32 {
                piece = String(UnicodeScalar(byte))
            } else {
                piece = String(format: "=%02X", byte)
            }
            if length + piece.count > 75 {
                encoded += "=\n"
                length = 0
            }
            encoded += piece
            length += piece.count
        }
        if encoded.hasSuffix(" ") { encoded = String(encoded.dropLast()) + "=20" }
        lines.append(encoded)
    }
    return lines.joined(separator: "\n")
}

func attachmentPart(_ data: Data, mimeType: String, filename: String, disposition: String = "attachment", extraHeaders: [(String, String)] = []) -> Part {
    Part(headers: [
        ("Content-Type", "\(mimeType); name=\"\(filename)\""),
        ("Content-Disposition", "\(disposition); filename=\"\(filename)\""),
        ("Content-Transfer-Encoding", "base64"),
    ] + extraHeaders, body: base64Body(data))
}

var boundaryCounter = 0
func multipart(_ subtype: String, _ parts: [Part], extraParameters: String = "") -> Part {
    boundaryCounter += 1
    let boundary = "=_stow_fixture_boundary_\(boundaryCounter)"
    var body = Data("This is a multi-part message in MIME format.\(crlf)".utf8)
    for part in parts {
        body.append(Data("--\(boundary)\(crlf)".utf8))
        body.append(part.serialised())
        if body.last != 0x0A { body.append(Data(crlf.utf8)) }
    }
    body.append(Data("--\(boundary)--\(crlf)".utf8))
    return Part(headers: [("Content-Type", "multipart/\(subtype); boundary=\"\(boundary)\"\(extraParameters)")], body: body)
}

var messageCounter = 0
/// Wraps a body part in top-level message headers. Pass nil for a header to leave it out.
func message(
    from: String,
    to: String? = ownerHeader,
    subject: String,
    date: String? = nil,
    messageID: String?? = .none,
    extraHeaders: [(String, String)] = [],
    body: Part
) -> Data {
    messageCounter += 1
    let defaultDate = "Mon, \(String(format: "%02d", (messageCounter % 27) + 1)) Sep 2025 09:\(String(format: "%02d", messageCounter % 60)):00 +0100"
    var headers: [(String, String)] = [
        ("Return-Path", "<\(addressOnly(from))>"),
        ("Delivered-To", owner),
        ("From", from),
    ]
    if let to { headers.append(("To", to)) }
    headers.append(("Subject", subject))
    headers.append(("Date", date ?? defaultDate))
    switch messageID {
    case .none: headers.append(("Message-ID", "<fixture-\(messageCounter)@mail.example.org>"))
    case .some(.some(let id)): headers.append(("Message-ID", id))
    case .some(.none): break
    }
    headers += extraHeaders
    headers.append(("MIME-Version", "1.0"))
    return Part(headers: headers + body.headers, body: body.body).serialised()
}

func addressOnly(_ header: String) -> String {
    if let open = header.lastIndex(of: "<"), let close = header.lastIndex(of: ">") {
        return String(header[header.index(after: open)..<close])
    }
    return header
}

func encodedWord(_ text: String, charset: String = "UTF-8", encoding: String.Encoding = .utf8) -> String {
    guard let data = text.data(using: encoding) else { fail("cannot encode \(text) as \(charset)") }
    return "=?\(charset)?B?\(data.base64EncodedString())?="
}

// MARK: - Attachment content

func makeTextPDF() -> Data {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, [kCGPDFContextCreator: "Stow fixtures"] as CFDictionary)
    else { fail("cannot create PDF context") }
    context.beginPDFPage(nil)
    let lines = [
        "Quarterly Report: Q3 2025",
        "Prepared for the Stow fixture set. Entirely synthetic.",
        "Revenue grew in the period; the harbour project completed on schedule.",
        "Keyword for search tests: PERIWINKLE-LEDGER-4471",
    ]
    for (index, line) in lines.enumerated() {
        draw(line, in: context, at: CGPoint(x: 56, y: 760 - CGFloat(index) * 28), size: index == 0 ? 20 : 13)
    }
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

/// A PDF whose only content is a picture of text, like a scanned letter. No text layer.
func makeScannedPDF() -> Data {
    let width = 1240, height = 1754 // A4 at 150 dpi
    guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { fail("cannot create bitmap") }
    bitmap.setFillColor(gray: 0.97, alpha: 1)
    bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let lines = [
        "Harbour Lane Surgery",
        "Dear Sam Taylor,",
        "Your appointment is confirmed for Tuesday.",
        "Reference: SCANNED-HERON-2208",
    ]
    for (index, line) in lines.enumerated() {
        draw(line, in: bitmap, at: CGPoint(x: 120, y: 1550 - CGFloat(index) * 70), size: 40, gray: 0.1)
    }
    guard let image = bitmap.makeImage() else { fail("cannot render scan") }

    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else { fail("cannot create PDF context") }
    context.beginPDFPage(nil)
    context.draw(image, in: mediaBox)
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

func draw(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat, gray: CGFloat = 0) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let color = CGColor(gray: gray, alpha: 1)
    let attributed = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = point
    CTLineDraw(line, context)
}

func makePNG() -> Data {
    let size = 48
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("cannot create PNG context") }
    context.setFillColor(CGColor(red: 0.12, green: 0.42, blue: 0.67, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fillEllipse(in: CGRect(x: 12, y: 12, width: 24, height: 24))
    guard let image = context.makeImage() else { fail("cannot render PNG") }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot create PNG destination") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write PNG") }
    return data as Data
}

/// A minimal valid .docx: the three parts Word needs, zipped with /usr/bin/zip.
func makeDocx() -> Data {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("stow-docx-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: work) }
    let files: [String: String] = [
        "[Content_Types].xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """,
        "_rels/.rels": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """,
        "word/document.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
        <w:p><w:r><w:t>Meeting notes: allotment committee</w:t></w:r></w:p>
        <w:p><w:r><w:t xml:space="preserve">Agreed to repaint the shed. Keyword for search tests: </w:t></w:r><w:r><w:t>MARIGOLD-MINUTES-9031</w:t></w:r></w:p>
        </w:body>
        </w:document>
        """,
    ]
    for (path, contents) in files {
        let url = work.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? contents.write(to: url, atomically: true, encoding: .utf8)) != nil else { fail("cannot write \(path)") }
    }
    let output = work.appendingPathComponent("out.docx")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = work
    zip.arguments = ["-q", "-X", "-r", output.path, "[Content_Types].xml", "_rels", "word"]
    do { try zip.run() } catch { fail("cannot run zip: \(error)") }
    zip.waitUntilExit()
    guard zip.terminationStatus == 0, let data = try? Data(contentsOf: output) else { fail("zip failed") }
    return data
}

// MARK: - Fixtures

struct Fixture {
    var file: String
    /// Case identifiers from the Phase 0 brief that this file covers.
    var cases: [String]
    /// Personal mail the rules engine should not flag. False for bulk-signal fixtures.
    var personal: Bool
    var note: String
    var attachments: [(filename: String, mimeType: String, data: Data)] = []
    var data: Data
}

var fixtures: [Fixture] = []
func add(_ file: String, cases: [String], personal: Bool = true, note: String,
         attachments: [(filename: String, mimeType: String, data: Data)] = [], _ data: Data) {
    fixtures.append(Fixture(file: file, cases: cases, personal: personal, note: note, attachments: attachments, data: data))
}

let alex = "Alex Morgan <alex@example.org>"
let textPDF = makeTextPDF()
let scannedPDF = makeScannedPDF()
let png = makePNG()
let docx = makeDocx()
var generator = SeededGenerator(state: 0x5704_F1C7)
let largeBlob = generator.bytes(15 * 1024 * 1024)

// Self-checks: the text PDF must have a text layer, the scanned one must not.
guard let textLayer = PDFDocument(data: textPDF)?.string, textLayer.contains("PERIWINKLE-LEDGER-4471") else {
    fail("text PDF has no extractable text")
}
guard let scannedDocument = PDFDocument(data: scannedPDF), scannedDocument.pageCount == 1,
      (scannedDocument.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
else { fail("scanned PDF unexpectedly has a text layer") }

add("01-plain-text.eml", cases: ["plain-text"], note: "Plain UTF-8 text from a friend", message(
    from: alex, subject: "Walk on Saturday?",
    body: textPart("""
    Hi Sam,

    Are you still up for the coastal walk on Saturday? I'll bring the flask.
    Keyword for search tests: LANTERN-COAST-1150

    Alex
    """)))

add("02-html-only.eml", cases: ["html-only"], note: "Single text/html part, quoted-printable", message(
    from: alex, subject: "Photos from the weekend",
    body: textPart("""
    <html><body><p>Hi Sam,</p><p>The photos are <b>up</b> now &mdash; have a look when you get a moment.</p>
    <p>Keyword for search tests: <i>MAGPIE-GALLERY-3307</i></p></body></html>
    """, subtype: "html")))

add("03-multipart-alternative.eml", cases: ["multipart-alternative"], note: "text/plain and text/html alternatives", message(
    from: "Priya Shah <priya@example.net>", subject: "Dinner plans",
    body: multipart("alternative", [
        textPart("Shall we book the Italian place for Thursday?\nKeyword: OLIVE-TABLE-5512"),
        textPart("<p>Shall we book the <em>Italian place</em> for Thursday?</p><p>Keyword: OLIVE-TABLE-5512</p>", subtype: "html"),
    ])))

add("04-inline-image.eml", cases: ["inline-image"], note: "multipart/related with a cid: PNG",
    attachments: [("logo.png", "image/png", png)], message(
    from: alex, subject: "New club logo",
    body: multipart("related", [
        multipart("alternative", [
            textPart("What do you think of the new club logo? (see image)"),
            textPart("<p>What do you think of the new club logo?</p><img src=\"cid:club-logo@example.org\" alt=\"logo\">", subtype: "html"),
        ]),
        attachmentPart(png, mimeType: "image/png", filename: "logo.png", disposition: "inline",
                       extraHeaders: [("Content-ID", "<club-logo@example.org>")]),
    ], extraParameters: "; type=\"multipart/alternative\"")))

add("05-attachment-15mb.eml", cases: ["attachment-15mb"], note: "15 MiB binary attachment (deterministic bytes)",
    attachments: [("survey-dataset.bin", "application/octet-stream", largeBlob)], message(
    from: "Data Team <data@example.net>", subject: "Survey dataset",
    body: multipart("mixed", [
        textPart("The full survey dataset is attached (15 MB)."),
        attachmentPart(largeBlob, mimeType: "application/octet-stream", filename: "survey-dataset.bin"),
    ])))

add("06-text-pdf.eml", cases: ["text-pdf", "duplicate-pdf"], note: "PDF with a text layer; same bytes as 07",
    attachments: [("quarterly-report.pdf", "application/pdf", textPDF)], message(
    from: "Finance <finance@example.net>", subject: "Q3 report",
    body: multipart("mixed", [
        textPart("Please find the Q3 report attached."),
        attachmentPart(textPDF, mimeType: "application/pdf", filename: "quarterly-report.pdf"),
    ])))

add("07-duplicate-pdf.eml", cases: ["duplicate-pdf"], note: "Same PDF bytes as 06, different message and filename",
    attachments: [("Q3 report (copy).pdf", "application/pdf", textPDF)], message(
    from: alex, subject: "Fwd: Q3 report",
    body: multipart("mixed", [
        textPart("Sending this on in case you did not get it."),
        attachmentPart(textPDF, mimeType: "application/pdf", filename: "Q3 report (copy).pdf"),
    ])))

add("08-scanned-pdf.eml", cases: ["scanned-pdf"], note: "Image-only PDF, no text layer (OCR test)",
    attachments: [("scanned-letter.pdf", "application/pdf", scannedPDF)], message(
    from: "Harbour Lane Surgery <reception@surgery.example.org>", subject: "Your letter",
    body: multipart("mixed", [
        textPart("A scanned copy of your letter is attached."),
        attachmentPart(scannedPDF, mimeType: "application/pdf", filename: "scanned-letter.pdf"),
    ])))

add("09-docx.eml", cases: ["docx"], note: "Word document with known keyword",
    attachments: [("meeting-notes.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", docx)], message(
    from: "Allotment Committee <committee@example.org>", subject: "Minutes",
    body: multipart("mixed", [
        textPart("Minutes from last night attached."),
        attachmentPart(docx, mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                       filename: "meeting-notes.docx"),
    ])))

let innerMessage = message(
    from: "Jordan Lee <jordan@example.net>", to: alex, subject: "Boat trip details",
    body: multipart("mixed", [
        textPart("Departure 08:30 from the north quay. Keyword: GANNET-QUAY-6620"),
        attachmentPart(Data("Lifejackets: 6\nSnacks: yes\n".utf8), mimeType: "text/plain", filename: "checklist.txt"),
    ]))
add("10-nested-rfc822.eml", cases: ["nested-rfc822"], note: "Forwarded as attachment: message/rfc822 with its own attachment", message(
    from: alex, subject: "Fwd: Boat trip details",
    body: multipart("mixed", [
        textPart("Forwarding Jordan's message below."),
        Part(headers: [
            ("Content-Type", "message/rfc822"),
            ("Content-Disposition", "attachment; filename=\"Boat trip details.eml\""),
        ], body: innerMessage),
    ])))

let latin1Text = crlfText("Bonjour Sam,\n\nLe café est à côté de la gare. Ça coûte £4 le crème brûlée.\nKeyword: CREME-GARE-7781\n")
guard let latin1Body = latin1Text.data(using: .isoLatin1) else { fail("cannot encode ISO-8859-1") }
add("11-iso-8859-1.eml", cases: ["iso-8859-1"], note: "8bit ISO-8859-1 body (raw bytes, not UTF-8)", message(
    from: "=?ISO-8859-1?Q?Ren=E9e_Dupont?= <renee@example.net>", subject: "=?ISO-8859-1?Q?Caf=E9_pr=E8s_de_la_gare?=",
    body: Part(headers: [
        ("Content-Type", "text/plain; charset=ISO-8859-1"),
        ("Content-Transfer-Encoding", "8bit"),
    ], body: latin1Body)))

let japanese = crlfText("サムさん\n\n会議の資料を添付します。よろしくお願いします。\nKeyword: SAKURA-KAIGI-4402\n")
guard let shiftJIS = japanese.data(using: .shiftJIS) else { fail("cannot encode Shift_JIS") }
add("12-shift-jis.eml", cases: ["shift-jis"], note: "Shift_JIS body (base64) and encoded-word subject", message(
    from: "\(encodedWord("田中 健", charset: "Shift_JIS", encoding: .shiftJIS)) <tanaka@example.net>",
    subject: encodedWord("会議の資料", charset: "Shift_JIS", encoding: .shiftJIS),
    body: Part(headers: [
        ("Content-Type", "text/plain; charset=Shift_JIS"),
        ("Content-Transfer-Encoding", "base64"),
    ], body: base64Body(shiftJIS))))

add("13-rfc2047-subject.eml", cases: ["rfc2047-subject"],
    note: "Subject of adjacent B and Q encoded words folded across lines; whitespace between them must be dropped", message(
    from: "=?UTF-8?Q?Zo=C3=AB_=C3=85berg?= <zoe@example.org>",
    subject: "=?UTF-8?B?w5xiZXIgZGFzIFRyZWZmZW4g?=\r\n =?UTF-8?Q?=E2=80=94_n=C3=A4chste_Woche_?=\r\n =?UTF-8?B?8J+Rjw==?=",
    body: textPart("Subject decodes to: Über das Treffen — nächste Woche 👏")))

add("14-rfc2231-filename.eml", cases: ["rfc2231-filename"],
    note: "RFC 2231 extended filename and a filename split across continuations",
    attachments: [("résumé — final.txt", "text/plain", Data("CV text\n".utf8)),
                  ("very long name split across parameters.txt", "text/plain", Data("notes\n".utf8))], message(
    from: alex, subject: "Files with awkward names",
    body: multipart("mixed", [
        textPart("Two attachments with encoded names."),
        Part(headers: [
            ("Content-Type", "text/plain; charset=utf-8"),
            ("Content-Disposition", "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9%20%E2%80%94%20final.txt"),
            ("Content-Transfer-Encoding", "base64"),
        ], body: base64Body(Data("CV text\n".utf8))),
        Part(headers: [
            ("Content-Type", "text/plain; charset=utf-8"),
            ("Content-Disposition", "attachment;\r\n filename*0*=UTF-8''very%20long%20name%20;\r\n filename*1*=split%20across%20;\r\n filename*2=\"parameters.txt\""),
            ("Content-Transfer-Encoding", "base64"),
        ], body: base64Body(Data("notes\n".utf8))),
    ])))

add("15-missing-message-id.eml", cases: ["missing-message-id"], note: "No Message-ID header", message(
    from: alex, subject: "No ID on this one", messageID: .some(nil),
    body: textPart("This message has no Message-ID header.")))

add("16-malformed-date.eml", cases: ["malformed-date"], note: "Unparseable Date header", message(
    from: alex, subject: "Strange date", date: "Thursday, 32 Smarch 2025 25:61:00 +9900",
    body: textPart("The Date header on this message cannot be parsed.")))

let references = (1...40).map { "<thread-\($0)-reference@mail.example.org>" }.joined(separator: "\r\n ")
let overlong = Array(repeating: "lorem", count: 300).joined(separator: "-") // 1,799 characters, over RFC 5322's 998
add("17-long-header-lines.eml", cases: ["long-header-lines"],
    note: "Folded References with 40 IDs, a folded Subject and one unfolded header line over 998 characters", message(
    from: alex,
    subject: "A very long subject line that goes on and on about the allotment committee,\r\n the shed, the paint colours and the rota for watering in August",
    extraHeaders: [("References", references), ("X-Fixture-Overlong", overlong)],
    body: textPart("Long headers above.")))

add("18-list-unsubscribe.eml", cases: ["list-unsubscribe"], personal: false, note: "List-Unsubscribe with one-click POST and List-ID", message(
    from: "Garden Weekly <editor@news.example.com>", subject: "This week: autumn bulbs",
    extraHeaders: [
        ("List-Unsubscribe", "<mailto:unsubscribe@news.example.com?subject=unsubscribe>,\r\n <https://news.example.com/unsubscribe/opaque-id>"),
        ("List-Unsubscribe-Post", "List-Unsubscribe=One-Click"),
        ("List-ID", "Garden Weekly <weekly.news.example.com>"),
    ],
    body: textPart("Autumn bulbs, pruning roses, and readers' photos.")))

add("19-precedence-bulk.eml", cases: ["precedence-bulk"], personal: false, note: "Precedence: bulk", message(
    from: "Announcements <announce@corp.example.com>", subject: "Office closed on Monday",
    extraHeaders: [("Precedence", "bulk")],
    body: textPart("The office will be closed on Monday for maintenance.")))

add("20-noreply-sender.eml", cases: ["noreply-sender"], personal: false, note: "no-reply sender address", message(
    from: "Example Shop <no-reply@shop.example.com>", subject: "Your order has shipped",
    body: textPart("Your order 1001 has shipped.")))

add("21-reply-to-differs.eml", cases: ["reply-to-differs"], personal: false, note: "Reply-To domain differs from From domain", message(
    from: "Events <events@example.com>", subject: "Tickets for the autumn fair",
    extraHeaders: [("Reply-To", "Bookings <bookings@agency.example.net>")],
    body: textPart("Reply to this message to book tickets.")))

let toList = ([ownerHeader] + (1...29).map { "Member \($0) <member\($0)@example.org>" }).joined(separator: ",\r\n ")
let ccList = (30...59).map { "Member \($0) <member\($0)@example.org>" }.joined(separator: ",\r\n ")
add("22-sixty-recipients.eml", cases: ["sixty-recipients"], personal: false, note: "60 recipients across To and Cc, owner in To", message(
    from: "Club Secretary <secretary@example.org>", to: toList, subject: "AGM date",
    extraHeaders: [("Cc", ccList)],
    body: textPart("The AGM will be held on the 14th.")))

add("23-bcc-only.eml", cases: ["bcc-only"], personal: false, note: "Owner absent from To and Cc; Delivered-To shows the owner", message(
    from: "Parish Council <clerk@council.example.org>", to: "Residents <residents@council.example.org>", subject: "Road closure",
    extraHeaders: [("Cc", "Highways <highways@council.example.org>")],
    body: textPart("The high street will be closed on Sunday.")))

let ics = crlfText("""
BEGIN:VCALENDAR
PRODID:-//Stow//Fixtures//EN
VERSION:2.0
METHOD:REQUEST
BEGIN:VEVENT
UID:fixture-event-1@example.org
DTSTAMP:20250901T090000Z
DTSTART:20250915T130000Z
DTEND:20250915T140000Z
SUMMARY:Planning meeting
ORGANIZER;CN=Alex Morgan:mailto:alex@example.org
ATTENDEE;CN=Sam Taylor;RSVP=TRUE:mailto:sam@example.com
END:VEVENT
END:VCALENDAR

""")
add("24-calendar-invite.eml", cases: ["calendar-invite"], note: "text/calendar METHOD:REQUEST alternative plus .ics attachment",
    attachments: [("invite.ics", "application/ics", Data(ics.utf8))], message(
    from: alex, subject: "Invitation: Planning meeting",
    body: multipart("mixed", [
        multipart("alternative", [
            textPart("You are invited to: Planning meeting, 15 Sep 2025 14:00."),
            Part(headers: [
                ("Content-Type", "text/calendar; charset=utf-8; method=REQUEST"),
                ("Content-Transfer-Encoding", "7bit"),
            ], body: Data(ics.utf8)),
        ]),
        attachmentPart(Data(ics.utf8), mimeType: "application/ics", filename: "invite.ics"),
    ])))

add("25-newsletter-combined.eml", cases: ["list-unsubscribe", "precedence-bulk", "noreply-sender", "list-provider"], personal: false,
    note: "Several strong bulk signals at once, sent through a list provider (Mailchimp-style Return-Path)", message(
    from: "Deals <noreply@deals.example.com>", subject: "48 hours only",
    extraHeaders: [
        ("List-Unsubscribe", "<https://deals.example.com/u/opaque>"),
        ("Precedence", "bulk"),
        ("X-Mailer", "MailChimp Mailer"),
        ("Received", "from mail.mcsv.net (mail.mcsv.net [192.0.2.10])"),
    ],
    body: textPart("Everything must go.")).replacingFirst("Return-Path: <noreply@deals.example.com>", with: "Return-Path: <bounce-mc.us1_000.000-sam=example.com@mail.mcsv.net>"))

extension Data {
    func replacingFirst(_ target: String, with replacement: String) -> Data {
        guard let range = range(of: Data(target.utf8)) else { fail("replace target missing") }
        var copy = self
        copy.replaceSubrange(range, with: Data(replacement.utf8))
        return copy
    }
}

// MARK: - Write

let requiredCases = [
    "plain-text", "html-only", "multipart-alternative", "inline-image", "attachment-15mb", "duplicate-pdf",
    "text-pdf", "scanned-pdf", "docx", "nested-rfc822", "iso-8859-1", "shift-jis", "rfc2047-subject",
    "rfc2231-filename", "missing-message-id", "malformed-date", "long-header-lines", "list-unsubscribe",
    "precedence-bulk", "noreply-sender", "reply-to-differs", "sixty-recipients", "bcc-only", "calendar-invite",
]
let covered = Set(fixtures.flatMap(\.cases))
let missing = requiredCases.filter { !covered.contains($0) }
guard missing.isEmpty else { fail("cases not covered: \(missing)") }

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for old in try FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)
    where ["eml", "json"].contains(old.pathExtension) {
        try FileManager.default.removeItem(at: old)
    }
    for fixture in fixtures {
        try fixture.data.write(to: outputDirectory.appendingPathComponent(fixture.file))
    }
    let manifest: [String: Any] = [
        "generator": "scripts/make-fixtures",
        "manifestVersion": 1,
        "owner": owner,
        "requiredCases": requiredCases,
        "fixtures": fixtures.map { fixture in
            [
                "file": fixture.file,
                "cases": fixture.cases,
                "personal": fixture.personal,
                "note": fixture.note,
                "bytes": fixture.data.count,
                "attachments": fixture.attachments.map { attachment in
                    [
                        "filename": attachment.filename,
                        "mimeType": attachment.mimeType,
                        "bytes": attachment.data.count,
                        "sha256": SHA256.hash(data: attachment.data).map { String(format: "%02x", $0) }.joined(),
                    ] as [String: Any]
                },
            ] as [String: Any]
        },
    ]
    let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: outputDirectory.appendingPathComponent("manifest.json"))
} catch {
    fail("writing fixtures failed: \(error)")
}

print("Wrote \(fixtures.count) fixtures covering \(requiredCases.count) cases to \(outputDirectory.path)")
