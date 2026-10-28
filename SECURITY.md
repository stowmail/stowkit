# Security

Stow holds years of people's email, so we take reports seriously and answer them quickly.

## Reporting a vulnerability

Please report privately, not in a public issue:

- **GitHub:** use "Report a vulnerability" on this repository's Security tab (private vulnerability reporting), or
- **Email:** security@getstow.ee

Include what you found, how to reproduce it, and the version or commit. We will acknowledge your report within three working days, keep you informed while we fix it, and credit you when the fix is published unless you would rather stay anonymous. Please give us a reasonable time to release a fix before you disclose it.

Never send real email content or anyone's credentials in a report. A synthetic message that triggers the problem is ideal.

## How fixes are disclosed

A fix is released first and disclosed second, never the other way round:

- **Medium or worse:** a GitHub security advisory on this repository, with a CVE requested through GitHub, published once the fix is on `main`.
- **Low:** a line in the changelog.

Reporters are credited in both, as above. An advisory says who found the problem and how, including when it came from our own AI-assisted review rather than an independent one.

## Scope

In scope: this engine (`StowKit` and the `stowmail` command-line tool), including sync, the encrypted archive, search, the recovery key, the OAuth sign-in and the local MCP server.

What the engine promises, and where to look:

- **Read-only towards mail servers.** The IMAP layer cannot express a write command (`ReadOnlyCommand`); folders are opened with EXAMINE and messages fetched with `BODY.PEEK[]`.
- **Encrypted at rest.** The database is SQLCipher; message and attachment files are AES-256-GCM, named by keyed hashes. Keys live only in the macOS Keychain.
- **Recovery key.** A random 256-bit key wraps the archive keys in `keys.recovery`; Stow never stores the recovery key itself.
- **Nothing personal in logs.** No tokens, subjects, bodies or unhashed addresses; log text is scrubbed before it reaches a file or standard error.
- **Local MCP server.** Read-only, off until enabled per account, standard input and output only (no network socket), results capped, every call in an audit log without mail content.

The Stow app built on this engine is a separate product; report issues in it to the same address.

## Signed commits

Commits to `main` from 25 October 2026 onwards are signed by Toby Treacher (`tobyt@getstow.ee`) with the SSH key `SHA256:gjaPQISqRw9oQxgVWNFL8g+KaKpdeXZAsiX+2+MYxw0`, and GitHub marks them Verified. Earlier commits are unsigned. A commit on `main` after that date without a valid signature did not come from us; please report it.

## Security review

What was checked before the engine was published, what was found and fixed, and what is still open: [docs/security-review.md](docs/security-review.md).

## Prompt injection

The MCP server returns email written by other people to an AI assistant. An email can contain text meant to steer the assistant. Stow's tools can only read, mark email content as data, and keep each body between lines carrying a random code. That lowers the risk; it cannot remove it. If your assistant also has tools that can send email, fetch web pages or write files, an injected instruction could try to use them. Reports of ways around Stow's markings are welcome.
