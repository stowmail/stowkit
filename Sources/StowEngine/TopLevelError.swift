import Foundation
import StowCore

/// The line `stowmail` prints for an error that reaches the top of a command
/// (A-14, D-514). Errors can carry server text, paths and parts of requests,
/// so the message goes through `Redact.scrub` (tokens and addresses) and
/// then `Redact.oneLine`, so nothing in it can start a second line.
public enum TopLevelError {
    public static func line(for error: any Error) -> String {
        "Error: " + Redact.oneLine(Redact.scrub(message(for: error)))
    }

    static func message(for error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
