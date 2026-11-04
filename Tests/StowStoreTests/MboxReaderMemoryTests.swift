import Darwin
import Foundation
import Testing
@testable import StowStore

/// QA item "memory stays flat on a multi-GB file" (D-559). Opt in, since it
/// writes and reads a file of several GB: `STOW_MBOX_MEMORY_GB=3 swift test
/// --filter MboxReaderMemoryTests`. A synthetic Takeout file (D-018) goes in
/// the temporary folder and is removed afterwards.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STOW_MBOX_MEMORY_GB"] != nil))
struct MboxReaderMemoryTests {
    @Test func memoryStaysFlatOnAMultiGigabyteFile() throws {
        let gigabytes = Double(ProcessInfo.processInfo.environment["STOW_MBOX_MEMORY_GB"] ?? "") ?? 3
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stow-mbox-memory-\(UUID().uuidString).mbox")
        defer { try? FileManager.default.removeItem(at: url) }

        // Write the file a block at a time: 2,000 synthetic messages repeated.
        let block = SyntheticTakeout.mbox(SyntheticTakeout.messages(count: 2_000, seed: 7))
        let target = Int64(gigabytes * 1_073_741_824)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let writer = try FileHandle(forWritingTo: url)
        var written: Int64 = 0
        while written < target {
            try writer.write(contentsOf: block)
            written += Int64(block.count)
        }
        try writer.close()

        var reader = MboxReader(try MboxFile(url: url))
        var messages = 0
        var bytes: Int64 = 0
        var peak: UInt64 = 0
        var baseline: UInt64 = 0
        while let message = try autoreleasepool(invoking: { try reader.next() }) {
            messages += 1
            bytes += Int64(message.size)
            if messages == 2_000 { baseline = footprint() }
            if messages % 20_000 == 0 { peak = max(peak, footprint()) }
        }
        peak = max(peak, footprint())
        let blocks = Int(written / Int64(block.count))
        #expect(messages == blocks * 2_000)
        #expect(reader.counts.bytesRead == written)
        // Flat: after the first block, growth stays under 32 MB however big the file.
        let growth = Int64(peak) - Int64(baseline)
        print("mbox memory: \(written / 1_048_576) MB file, \(messages) messages, footprint \(baseline / 1_048_576) MB after the first block, peak \(peak / 1_048_576) MB")
        #expect(growth < 32 * 1_048_576)
    }

    /// The process's physical footprint, as Activity Monitor's Memory column shows it.
    func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
