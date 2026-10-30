# Security review, October 2026

A summary of the security review of the Stow engine carried out before it was published. It says what was checked, what was found, what was fixed and what is still open.

## Who did it, and how

The review was done by Stow's developer with AI assistance (Anthropic's Claude, in Claude Code). To keep it from simply confirming how the code was built, it ran in a fresh session with none of the build history, and a second AI reviewer, given the code and none of the first reviewer's conclusions, read the parts that handle hostile input or the file system. Every finding below was checked by hand against the code and reproduced where possible.

This is not an independent third-party audit, and it is not a certification. We publish it so you can judge the work for yourself, and we would welcome an outside review.

- **Engine reviewed:** commit 676daa7; fixes in dc21137.
- **Date:** 25 October 2026.
- **Not covered:** the Stow app (its sandbox, signing, the email reader and in-app sign-in), which is reviewed separately before release.

## What we protect against

- **Another app or user on the same Mac.** Archive folders and files are readable only by your macOS user; the archive is ciphertext without the keys, and the keys are in the Keychain.
- **Someone with a copy of your disk or backup.** Every file is encrypted, and the recovery key needed to open a copied archive on another Mac is never stored by Stow.
- **A malicious email.** Every byte of every message is written by a stranger, and Stow parses all of it.
- **A compromised dependency.** Few dependencies, each pinned and recorded.
- **Prompt injection.** An email written to steer an AI assistant that reads the archive through Stow's MCP server.

## What was checked

- **Encryption at rest:** the database (SQLCipher 4.19.0, AES-256, refusing to run on unencrypted SQLite), message and attachment files (AES-256-GCM, named by keyed hashes), temporary files kept in memory.
- **Keys:** only in the Keychain, never synchronised; never generated when loading; the MCP server loads only the database key.
- **The recovery key:** made and confirmed before any mail is imported.
- **Logs:** no secrets or mail content in logs, crash messages, test fixtures or git history (gitleaks over the whole history), checked in the code and against a real archive's log files.
- **File permissions:** folders 0700 and files 0600, checked on a real archive.
- **OAuth sign-in:** PKCE, a 256-bit `state` compared in constant time, a listener on 127.0.0.1 only that ends only on the reply carrying the sign-in's `state`, token refresh and failure handling.
- **Read-only towards mail servers:** the IMAP code cannot express a write; the release binary contains no IMAP write command at all.
- **Fuzzing:** the MIME parser, the stored message format and the Word-document reader, fuzzed for an hour with libFuzzer and AddressSanitizer: 2.27 million inputs, no crashes or memory errors (`scripts/fuzz-mime.sh`).
- **Dependencies:** versions, licences, and the GitHub Advisory Database; none affected.
- **The MCP server:** read-only, off until enabled per account, results capped, an audit log without mail content, and no network socket: checked with `lsof` on the release build while it ran, although the MCP SDK compiles HTTP transports in.

## Findings

No High findings. Five Medium findings, all fixed with tests:

| | Finding | Fix |
|---|---|---|
| M-1 | Making a new recovery key wrote the new key file first and cleared the old "confirmed" mark second. If the second step failed, Stow kept saying the key was confirmed while the key file needed a key nobody had seen, so recovery on a new Mac would silently stop working. | A confirmation now records which key file it confirmed; any other key file counts as unconfirmed and syncing pauses until a new key is made and confirmed. The mark is cleared before the new file is written. |
| M-2 | Log lines were cleaned of addresses and tokens before reaching the log file, but not on standard error, which macOS's background service manager and assistant apps also save to files. No leak was found, but the safety net had a gap. | Standard error is cleaned the same way; the background sync logs only to its log file. |
| M-3 | An email could imitate the structure of Stow's replies to an AI assistant: the lines around an email's body were fixed text an email could copy, and a sender's name could contain a hidden line break that added a fake line to the reply. | The lines around each body carry a random code, new in every reply, and every short field a sender writes is kept to one line. |
| M-4 | A mail server could announce an absurdly large message and make sync stop dead on it every run. This needs a compromised provider or an intercepted connection. | Message sizes from the server are capped (256 MB, above any provider's limit), and memory is never reserved up front from the server's figure. |
| M-5 | A mail server could report message sizes large enough to overflow Stow's arithmetic and stall an account's sync. Same preconditions as M-4. | Reported sizes are bounded where they are read. |

Low findings fixed: a huge result offset requested through the MCP server could crash it; the mailbox export checked for an existing file and then created it, leaving a gap; a `%` typed into a tidy-up selector matched more mail than intended (the count was always shown before anything was removed).

## Second review, 28 October 2026

A second in-house, AI-assisted review read the engine at `711062a` with none of the first review's conclusions. As before, it is not an independent audit. Every High and Medium finding is fixed, released in a signed tag and disclosed as a GitHub security advisory. Low and Informational findings are fixed and listed in the [changelog](../CHANGELOG.md), or listed under "Still open" below. Each fix has a test that fails on the old code, and each row names the release that shipped it.

| | Severity | Finding | Fix |
|---|---|---|---|
| A-01 | High | Crafted HTML in an email made converting it to text take time proportional to the square of its size: 19 minutes for a 2 MB body. The email was never recorded, so it was fetched and parsed again on every sync and archiving stopped. Disclosed as [GHSA-xhg9-88xv-2q76](https://github.com/stowmail/stowkit/security/advisories/GHSA-xhg9-88xv-2q76). | The tag scanner only moves forward and stops looking for tags once none can close, so it runs in linear time (`d8bb7f0`, in 0.1.0). |
| A-02 | Medium | The same effect from a header full of `=?`: 195 s for a 1 MB Subject. Same advisory. | Encoded-word scans stop at 76 bytes (the RFC 2047 maximum is 75), and at most 16 KB of a header is decoded (`c6ed62c`, in 0.1.0). |
| A-03 | Medium | One attachment that hangs or crashes Apple's PDF or image readers could stall import or text recognition (OCR) for good: the OCR queue always restarted at the same item, and nothing counted tries. Disclosed as [GHSA-39ch-8w9v-qg3p](https://github.com/stowmail/stowkit/security/advisories/GHSA-39ch-8w9v-qg3p). | The text read from each part is capped at 10 MB, and PDFKit runs on its own thread with a 30-second limit (`dc530da`, in 0.1.0). Each import and each OCR item is now counted before it is read, so a crash still counts; after three unfinished tries an email is stored whole as received and marked "couldn't read all of this email", and an attachment is marked unreadable. Reading one email has a 5-minute limit and one OCR item a 10-minute limit; a stuck reader is abandoned and the background sync restarts. Marked text is tried again only by a newer version (in 0.1.1). |
| A-07 | Low | The Microsoft sign-in returned to `localhost` while the listener bound IPv4 only, so a browser trying `[::1]` first could hand the reply to any local process listening there. The sign-in failed; without the PKCE verifier no token could be taken. | The redirect is now `http://127.0.0.1`, as Google's already was (`711062a`, in 0.1.0; not in the changelog). |
| A-13 | Low | A mail server could hold sync without limit: replies for messages Stow had not asked for were kept in memory, a reply's size was bounded only by the server's own claims, and a server sending one byte every 89 seconds never tripped the idle timer, which also held up every other account. | Replies for messages not asked for are dropped as they arrive; each command has a byte limit (twice the expected size plus 16 MB, never over 1 GB) and a 5-minute deadline; the full flag check runs in windows; one stuck account no longer holds the others (`0fe59a0`, in 0.1.0). |
| A-22 | Low | The address parser never returned on a string holding a CR LF, using memory until stopped. No email could reach it (header values never hold a line feed); only code calling `AddressListParser` directly could. Found by the CI fuzz job. | CR LF counts as whitespace and every step of the tokeniser moves forward (in 0.1.1; in the changelog, no advisory). |
| A-04 | Medium | Making a new recovery key replaced the archive's recovery file before the new key had been typed back. Stopping at that point (Ctrl-C, a closed window, three mistyped groups) left a recovery file that only the unsaved key opened. Disclosed as [GHSA-89jf-8jp8-689x](https://github.com/stowmail/stowkit/security/advisories/GHSA-89jf-8jp8-689x). | A new key waits as `keys.recovery.pending` and replaces the live file only after it is confirmed; the confirmation is written firmly to disk first, files and folder are flushed, and a stop in between is finished by the next writer. The old key keeps working until then (in 0.1.2). |
| A-05, L-5 | Medium | Encrypted files were renamed into place without being flushed to disk, and a file already at its content address was reused without a check. After a power cut, a torn or empty attachment could be linked from every later message carrying it, and a torn message file stopped that message from ever being archived. Disclosed as [GHSA-9gcv-3mm3-hw86](https://github.com/stowmail/stowkit/security/advisories/GHSA-9gcv-3mm3-hw86). | Each new file is handed to the drive (`fsync`) before its rename and its folder after it, and one write barrier (`F_BARRIERFSYNC`) per message puts them on disk ahead of the rows that use them. An existing file is reused only if it opens with this key and address (an attachment must also have its exact sealed size); otherwise it is replaced in one rename. Costs about 1 ms per imported message (in 0.1.2). |
| A-09 | Low | Two processes creating the archive keys at once could both write them, the second replacing the first, and a recovery file could wrap keys other than the archive's. | Keys are added, never replaced, so one caller wins and the other is refused; making or confirming a recovery key checks a digest of the archive's own keys (in 0.1.2). |
| A-10 | Low | `archive-move` let go of the writer lock before asking whether to delete the old copy, so the background sync could save mail into it and the deletion then destroyed that mail. | The lock is held to the end; the old folder keeps `moved-to.json`, which every way of opening or creating an archive refuses; a background sync that finds it stops and restarts at the new place (in 0.1.2). |
| A-11 | Low | Removing mail deleted files straight after a commit that was not yet on disk, so a power cut could bring back rows pointing at deleted files. | Each batch's commit is fully flushed before its files are deleted (in 0.1.2). |
| A-20 | Low | An interrupted mbox export left a partial file under its final name, which then blocked the retry. | Exports are written under a hidden temporary name and renamed into place only when complete, never over an existing file (in 0.1.2). |
| A-06 | Low | The sign-in listener on 127.0.0.1 ended the sign-in on the first request to `/`, whatever it carried, so a web page that found the port could cancel a sign-in (no token could be taken; PKCE holds). | Only a reply carrying the sign-in's `state` ends it; anything else gets a page that says nothing and the listener keeps waiting until its timeout (in 0.1.3). |
| A-08 | Low | `stowmail` read its OAuth client IDs from a `.env` file in the current folder, and the background sync saved that path, so running it inside a downloaded folder could show someone else's consent screen. | Builds made for the app have the IDs built in and read no file; source builds read only `STOW_ENV_FILE` or `~/Library/Application Support/Stow/config.env` (in 0.1.3). |
| A-12 | Low | A token refresh in flight when an account was removed could save the account's tokens back into the Keychain. | A refresh only replaces an existing item, for an account still connected; removed accounts are refused (in 0.1.3). |
| A-14, A-15, A-16 | Low | Errors reaching the top of a command were printed unscrubbed; log lines could be split by line breaks in server text; `stowmail mcp log` printed an assistant's text raw, terminal escapes included. | Errors are scrubbed and kept to one line; every log line escapes control characters and the log folder is made private; `mcp log` cleans every field (in 0.1.3). |
| A-17 | Low | Characters that show as nothing (tag characters, variation selectors, Hangul fillers) could carry instructions to an assistant in bodies and attachment text. | They are removed from everything the assistant reads, with a visible marker in bodies; joiners that real text needs are kept. Stored mail is unchanged (in 0.1.3). |
| A-18 | Low | Searches had no limits on length, word count or one-letter prefixes. | 1 KB, 32 words and two characters before `*`; longer searches are cut and say so (in 0.1.3). |
| A-19 | Low | A missing or damaged rules data file silently emptied the protection lists. | The rules then suggest nothing for removal and say why (in 0.1.3). |
| A-21 | Low | Saved email file names were cut by characters, so some scripts overran a 255-byte name limit. | Names are cut to 240 bytes, between characters (in 0.1.3). |
| I-02, I-07, I-08 | Info | Key copies in memory; a stranger joining a conversation unnoticed; the billing-sender label trusting the From line. | One wiped key buffer and no key in SQL text; a flag for a sender new to the conversation; the label only when the provider's DMARC check passed, protection unchanged (in 0.1.3). The stored result per message and its backfill followed in 0.1.4 (D-521, D-522). |
| R-01 | | Nothing checked a push. | Every push to `main` builds, tests and scans the history with gitleaks on GitHub Actions, as the `check` job; CodeQL runs on pushes and weekly, and reads every engine and vendored source file. Actions are pinned to full commit SHAs, with a read-only token and no secrets. |
| R-02 | | Fuzzing covered only the MIME parser, with inputs too small to find slow code. | libFuzzer targets for the MIME parser, HTML to text, encoded words and address lists, the search query parser, the ZIP reader and IMAP reply assembly, with 1 MB inputs and a 5-second limit per input (`scripts/fuzz.sh`). Run against the old code, they found A-01 and A-02 within 30 seconds; on the fixed code each ran 10 minutes with no finding. A short pass runs on pushes to `main` and weekly. |

## Still open

- **Attachments are read by Apple's frameworks** (PDFKit, Vision, XMLParser) in the process that holds the keys. A flaw in one of those would run with access to the archive. The app's sandbox narrows this; moving text extraction into its own sandboxed process, holding no keys, is planned.
- **Removing an account does not revoke Stow's access at Google.** The tokens are deleted on the Mac and Stow tells you to remove its access in your Google account; calling Google's revoke service automatically is planned.
- **Prompt injection cannot be prevented by Stow alone.** Stow's tools can only read, mark email as data and keep each email's text between coded lines. If your assistant can also send email, browse or write files, a tricked assistant could try to use those. See [SECURITY.md](../SECURITY.md).

## Reporting a problem

See [SECURITY.md](../SECURITY.md): private vulnerability reporting on GitHub, or security@getstow.ee.
