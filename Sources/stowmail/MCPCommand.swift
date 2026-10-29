import ArgumentParser
import Foundation
import StowCore
import StowEngine
import StowMCP
import StowStore

/// `stowmail mcp`: the local MCP server, and turning it on per account (Phase 3, D-081).
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Let an AI assistant (Claude Desktop, Claude Code or another MCP client) search the archive, read-only.",
        discussion: """
            Off for every account until you turn it on with `stowmail mcp enable <account>`. With no subcommand, \
            serves MCP over standard input and output: that is what the assistant app runs, not something to type. \
            `stowmail mcp config` prints the settings to paste into the assistant app.
            """,
        subcommands: [Serve.self, Enable.self, Disable.self, Status.self, Log.self, Config.self],
        defaultSubcommand: Serve.self
    )

    static var auditLog: MCPAuditLog { MCPAuditLog(directory: LaunchAgent.logDirectory) }

    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Serve MCP over standard input and output (run by the assistant app)."
        )

        func run() async throws {
            // Standard output belongs to the protocol: nothing here may print. Logs go to standard error and the log file.
            CLI.bootstrapLogging()
            let archive = DirectMCPArchive(location: CLIArchive.location(), keys: CLI.keyManager())
            try await StowMCPServer(archive: archive, audit: MCPCommand.auditLog, version: StowVersion.current).runOverStdio()
        }
    }

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Let assistants search and read one account's archived mail.")

        @Argument(help: "Account ID, ID prefix, address or name.") var account: String

        func run() async throws {
            CLI.bootstrapLogging()
            let (archive, lock) = try CLIArchive.openForWriting(requireRecovery: false)
            defer { lock.release() }
            let accounts = CLIArchive.accounts(archive)
            let record = try accounts.find(account)
            try accounts.setMCPEnabled(record.account.id, true)
            print("Assistants connected to Stow can now search and read mail archived from \(record.account.email).")
            print("What they find is sent to the assistant's provider (for example Anthropic for Claude) when you ask a question.")
            print("Every request is listed in \(MCPCommand.auditLog.url.path) (search terms and counts, never mail).")
            print("Turn it off again with `stowmail mcp disable \(record.account.id)`.")
        }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Hide one account from assistants again. Takes effect at once.")

        @Argument(help: "Account ID, ID prefix, address or name.") var account: String

        func run() async throws {
            CLI.bootstrapLogging()
            let (archive, lock) = try CLIArchive.openForWriting(requireRecovery: false)
            defer { lock.release() }
            let accounts = CLIArchive.accounts(archive)
            let record = try accounts.find(account)
            try accounts.setMCPEnabled(record.account.id, false)
            print("Assistants can no longer see mail from \(record.account.email), from their next request.")
            print("Anything they were already sent stays with the assistant's provider.")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show which accounts assistants can see.")

        func run() async throws {
            let archive = try CLIArchive.open(readOnly: true)
            let accounts = CLIArchive.accounts(archive)
            let enabled = Set(try accounts.mcpEnabled().map(\.id))
            for record in try accounts.all() {
                print("\(enabled.contains(record.account.id) ? "on " : "off")  \(record.account.id)  \(record.account.email)  \"\(record.account.displayName)\"")
            }
            if enabled.isEmpty { print("Assistants see nothing until you run `stowmail mcp enable <account>`.") }
            print("Audit log: \(MCPCommand.auditLog.url.path)")
        }
    }

    struct Log: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the latest requests assistants made.")

        @Option(help: "How many to show.") var last = 20

        func run() async throws {
            let entries = try await MCPCommand.auditLog.recent(last)
            if entries.isEmpty { print("No requests yet.") }
            for entry in entries {
                print(entry.printedLine(time: CLI.time(entry.at)))
            }
        }
    }

    struct Config: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the settings to add Stow to Claude Desktop and Claude Code.",
            discussion: """
                Uses the background sync's copy of stowmail when it is installed: macOS already lets that copy read \
                the archive key, so the assistant does not trigger a Keychain prompt (D-044).
                """
        )

        func run() async throws {
            let executable = FileManager.default.isExecutableFile(atPath: LaunchAgent.installedExecutable.path)
                ? LaunchAgent.installedExecutable
                : URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
            let environment = ProcessInfo.processInfo.environment
            let kept = ["STOW_KEYCHAIN", "STOW_ARCHIVE_DIR", "STOW_KEYCHAIN_SERVICE"]
                .compactMap { key in environment[key].flatMap { $0.isEmpty ? nil : (key, $0) } }
            print(MCPConfigSnippets.claudeDesktop(executable: executable.path, environment: kept))
            print("")
            print(MCPConfigSnippets.claudeCode(executable: executable.path, environment: kept))
            if !kept.contains(where: { $0.0 == "STOW_KEYCHAIN" }) {
                print("")
                print("Note: STOW_KEYCHAIN is not set here. Unsigned development builds need STOW_KEYCHAIN=file (D-012).")
            }
        }
    }
}

/// The text `stowmail mcp config` prints, kept apart so tests can check it is valid JSON.
enum MCPConfigSnippets {
    static func server(executable: String, environment: [(String, String)]) -> [String: Any] {
        var server: [String: Any] = ["command": executable, "args": ["mcp"]]
        if !environment.isEmpty { server["env"] = Dictionary(environment, uniquingKeysWith: { $1 }) }
        return server
    }

    static func claudeDesktop(executable: String, environment: [(String, String)]) -> String {
        """
        Claude Desktop: add this to ~/Library/Application Support/Claude/claude_desktop_config.json, then quit and reopen it.
        (If the file already has "mcpServers", add the "stow" entry inside it.)
        \(json(["mcpServers": ["stow": server(executable: executable, environment: environment)]]))
        """
    }

    static func claudeCode(executable: String, environment: [(String, String)]) -> String {
        var server = server(executable: executable, environment: environment)
        server["type"] = "stdio"
        let entry = json(server, pretty: false)
        return """
            Claude Code: run this once in Terminal (--scope user makes it available in every project).
            claude mcp add-json --scope user stow \(shellQuoted(entry))
            """
    }

    static func json(_ object: [String: Any], pretty: Bool = true) -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: options)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func shellQuoted(_ text: String) -> String {
        text.allSatisfy { $0.isLetter || $0.isNumber || "/._-=".contains($0) } ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
