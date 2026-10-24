import Foundation

/// Everything the MCP tools read from the archive (D-081).
///
/// The CLI's `stowmail mcp` opens the database directly (read-only, database
/// key only). Phase 5 can put the login item behind this protocol over XPC
/// (D-060) without touching the tools.
///
/// Implementations return every account's data. Which accounts the assistant
/// may see is decided by `StowMCP`'s `ArchiveTools`, from `mcpEnabledAccounts()`, on every
/// call, so `stowmail mcp disable` takes effect at once.
public protocol MCPArchive: MessageSearching, MessageReading {
    /// The accounts the user has opened to MCP (`stowmail mcp enable`).
    func mcpEnabledAccounts() async throws -> [Account]
}
