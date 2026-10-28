import Foundation
import Testing
@testable import StowStore

/// A-01 (security sweep 1): hostile HTML must become text in linear time.
/// The old tag scanner took minutes or more on each of these inputs; the
/// one-second bound leaves a wide gap between linear and quadratic. If a
/// slower machine needs it, shrink the input, not the bound.
@Suite(.timeLimit(.minutes(1))) struct HTMLTextTimingTests {
    static let size = 2 << 20

    /// A `<` that never meets a `>`, repeated: every one used to scan to the end.
    @Test func unclosedTags() {
        let html = String(repeating: "<a", count: Self.size / 2)
        let (text, seconds) = timed { HTMLText.text(fromHTML: html) }
        #expect(seconds < 1, "took \(seconds) s")
        // No tag ever closes, so all of it is text, as before.
        #expect(text == html)
    }

    /// An unclosed quote hides every later `>` from the tags before it, so
    /// each of those used to scan to the end before giving up. The `<b>`
    /// tail is kept short: real tags cost a few microseconds each in a debug
    /// build, which is linear but would blur the bound.
    @Test func unclosedQuote() {
        let html = String(repeating: "<a b=\"c\"", count: Self.size / 2 / 8) + "<i title=\""
            + String(repeating: "<b>", count: (64 << 10) / 3) + "end"
        let (text, seconds) = timed { HTMLText.text(fromHTML: html) }
        #expect(seconds < 1, "took \(seconds) s")
        #expect(text.hasSuffix("end"))
        #expect(!text.contains("<b>"))
    }

    /// Inside a dropped element every `<` still looked for its `>`.
    @Test func unclosedScript() {
        let html = "Hello <script>" + String(repeating: "<a", count: (1 << 20) / 2)
        let (text, seconds) = timed { HTMLText.text(fromHTML: html) }
        #expect(seconds < 1, "took \(seconds) s")
        // The script never ends, so everything after it is script, as before.
        #expect(text == "Hello")
    }
}

func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let clock = ContinuousClock()
    let start = clock.now
    let result = try body()
    let elapsed = clock.now - start
    return (result, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
}
