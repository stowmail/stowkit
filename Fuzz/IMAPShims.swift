// Stand-in for the one IMAPSession constant FetchAssembler.swift names, so the
// IMAP fuzz target does not need the session, the connection or the network.
enum IMAPSession {
    static let nonBodyReplyBytes = 64 << 20
}
