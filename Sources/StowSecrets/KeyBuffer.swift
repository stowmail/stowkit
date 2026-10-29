import CryptoKit
import Foundation

/// Key bytes in one place that is wiped when it is released (D-486, D-519).
///
/// The bytes live in a page of their own, locked in memory where macOS allows
/// it (`mlock`, so they are not written to swap), and are overwritten with
/// zeros by `memset_s`, which the compiler may not optimise away, before the
/// page is freed. Hand a `KeyBuffer` on rather than copying its bytes; read
/// them only inside `withUnsafeBytes`.
public final class KeyBuffer: @unchecked Sendable {
    public let count: Int
    private let page: UnsafeMutableRawPointer
    private let pageSize: Int
    private let locked: Bool

    /// Called after the bytes are zeroed and before the page is freed. Tests only.
    nonisolated(unsafe) static var releaseObserver: ((UnsafeRawBufferPointer) -> Void)?

    /// Allocates the page and lets `fill` write the `count` key bytes into it.
    private init(count: Int, fill: (UnsafeMutableRawBufferPointer) -> Void) {
        let system = Int(getpagesize())
        self.count = count
        pageSize = max(system, (count + system - 1) / system * system)
        page = UnsafeMutableRawPointer.allocate(byteCount: pageSize, alignment: system)
        page.initializeMemory(as: UInt8.self, repeating: 0, count: pageSize)
        locked = mlock(page, pageSize) == 0
        fill(UnsafeMutableRawBufferPointer(start: page, count: count))
    }

    public convenience init(copying bytes: UnsafeRawBufferPointer) {
        self.init(count: bytes.count) { $0.copyMemory(from: bytes) }
    }

    /// Copies a CryptoKit key in, without an intermediate `Data`.
    public convenience init(_ key: SymmetricKey) {
        self.init(count: key.bitCount / 8) { destination in key.withUnsafeBytes { destination.copyMemory(from: $0) } }
    }

    /// Copies `data` in. The caller still owns `data` and should wipe it
    /// (`resetBytes`) once it is no longer needed.
    public convenience init(_ data: Data) {
        self.init(count: data.count) { destination in data.withUnsafeBytes { destination.copyMemory(from: $0) } }
    }

    public func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        try body(UnsafeRawBufferPointer(start: page, count: count))
    }

    deinit {
        memset_s(page, pageSize, 0, pageSize)
        Self.releaseObserver?(UnsafeRawBufferPointer(start: page, count: count))
        if locked { munlock(page, pageSize) }
        page.deallocate()
    }
}
