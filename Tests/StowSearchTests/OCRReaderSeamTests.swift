import Foundation
import StowCore
import Testing
@testable import StowSearch
@testable import StowStore

/// Security review L-2: the OCR queue reaches Vision only through the reader seam, and a
/// reader that fails, times out, cannot be reached or answers nothing never wedges the
/// queue (the outcomes the Mac app's helper can give, D-824). Uses `OCRAttemptTests`'
/// archive: one message with two scanned images waiting for OCR.
@Suite(.serialized) struct OCRReaderSeamTests {
    /// The first request gets `first`, every later one reads "Teal statement".
    final class FirstThenText: AttachmentTextReading, @unchecked Sendable {
        let first: AttachmentTextOutcome
        private let lock = NSLock()
        private var count = 0
        private(set) var types: [String] = []

        init(_ first: AttachmentTextOutcome) { self.first = first }

        func read(_ request: AttachmentTextRequest) -> AttachmentTextOutcome {
            lock.withLock {
                count += 1
                types.append(request.type)
                precondition(request.purpose == .recognition)
                return count == 1 ? first : .finished(ExtractionResult(status: .ocrDone, text: "Teal statement", method: .ocr))
            }
        }
    }

    @Test(arguments: [AttachmentTextOutcome.failed, .finished(ExtractionResult(status: .ocrDone, text: "", method: .ocr))])
    func aFailedOrEmptyAnswerMovesOnInTheSameRun(_ outcome: AttachmentTextOutcome) async throws {
        let fixture = OCRAttemptTests()
        let archive = try fixture.archive()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reader = FirstThenText(outcome)
        let processed = try await OCRQueue(archive: archive, reader: reader).run()
        #expect(processed == 2)
        #expect(reader.types == ["image/png", "image/png"])
        let expected = outcome == .failed ? "ocr_failed" : "ocr_done"
        #expect(try fixture.count(archive, "text_status = '\(expected)'") == (expected == "ocr_done" ? 2 : 1))
        #expect(try fixture.count(archive, "text_status = 'ocr_pending'") == 0)
    }

    @Test func aTimeOutMarksTheItemAndTheNextRunMovesOn() async throws {
        let fixture = OCRAttemptTests()
        let archive = try fixture.archive()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reader = FirstThenText(.timedOut)
        let queue = OCRQueue(archive: archive, reader: reader)
        #expect(throws: OCRQueue.OCRError.self) { try queue.runNext() }
        #expect(try fixture.count(archive, "text_status = 'ocr_failed' AND text_failed_version = 1") == 1)
        #expect(try queue.runNext())
        #expect(try fixture.count(archive, "text_status = 'ocr_done'") == 1)
        #expect(try queue.runNext() == false)
    }

    @Test func anUnreachableReaderTakesTheTryBackAndMarksNothing() throws {
        let fixture = OCRAttemptTests()
        let archive = try fixture.archive()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let queue = OCRQueue(archive: archive, reader: FirstThenText(.unavailable))
        #expect(throws: OCRQueue.OCRError.self) { try queue.runNext() }
        #expect(try fixture.count(archive, "text_status = 'ocr_pending' AND text_attempts = 0") == 2)
        #expect(try queue.runNext())
        #expect(try fixture.count(archive, "text_status = 'ocr_done'") == 1)
    }
}
