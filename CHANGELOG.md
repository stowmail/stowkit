# Changelog

Changes to StowKit and the `stowmail` command-line tool, newest first. Security fixes rated Medium or worse also get a GitHub security advisory; Low ones are listed here only (see [SECURITY.md](SECURITY.md)).

## Unreleased

### Security

- **Low:** the sign-in listener on 127.0.0.1 ended the sign-in on the first `GET /` it received, whatever it carried, so a web page in any browser that sent `http://127.0.0.1:<port>/?error=x` across the port range could cancel a sign-in in progress (second review A-06). No token could be obtained this way (PKCE). Only a reply carrying the sign-in's `state`, compared in constant time, now ends it, with its code or the provider's own error; any other request gets a 400 page that says nothing about the sign-in and echoes nothing, and the listener keeps waiting until its 5-minute timeout. A connection that has not sent its request within 10 s is closed. `LoopbackError.stateMismatch` is no longer produced.

## 0.1.2 (29 October 2026)

### Security

- **Medium:** making a new recovery key (`stowmail recovery-key rotate`, `create`, `init`) replaced the archive's recovery bundle, `keys.recovery`, before the new key had been confirmed. Stopping at the prompt (Ctrl-C, a closed terminal, three mistyped groups) left a bundle that only the unsaved key opened, and sync paused (second review A-04). A new key is now written as `keys.recovery.pending` and replaces `keys.recovery` only after it is confirmed; the confirmation is committed durably first, and both files and the folder are flushed to the drive (`F_FULLFSYNC`). A confirmation stopped before the rename is finished by the next writer. Until then the old key keeps working and sync carries on. A pending key nobody confirmed is deleted when the prompt gives up, and `status` and `doctor` mention one that is left. The file format is unchanged. [GHSA-89jf-8jp8-689x](https://github.com/stowmail/stowkit/security/advisories/GHSA-89jf-8jp8-689x).
- **Low:** two `stowmail init` runs at once, or the app and the CLI, could both find no archive keys in the Keychain and both save a pair, the second replacing the first (second review A-09). Archive keys are now added with `KeychainStore.add`, which never replaces an item: one caller makes the pair and the other is refused. `rotate` also refuses keys other than the ones the archive was opened with, and `confirm` refuses a bundle whose keys differ from them, compared by a SHA-256 digest in constant time rather than by keeping a copy of the keys. Existing Keychain items are not changed.
- **Medium:** encrypted message and attachment files were renamed into place without being flushed to disk, and a file already at its content address was reused without a check (second review A-05, first review L-5). After a power cut or kernel panic, a torn or empty attachment could be linked from every later message carrying it, so those messages could not be rebuilt, and a torn message file stopped that message from ever being archived. Each new file and its folder are now handed to the drive (`fsync`) and one write barrier (`F_BARRIERFSYNC`) per message puts them on disk before the rows that use them. An existing file is reused only if it authenticates (an attachment must also have its exact sealed size); a damaged one is replaced atomically, and the warning logs only a hash prefix and sizes. A first sync's import step takes about 1 ms longer per message. `EncryptedFileStore.write` gains `replacingDamaged`; `EncryptedFileStore` and `Archive.open` take a `DiskSync`. [GHSA-9gcv-3mm3-hw86](https://github.com/stowmail/stowkit/security/advisories/GHSA-9gcv-3mm3-hw86).
- **Low:** removing mail from the archive committed each batch of 200 and deleted its files straight away, while the commit reached the disk only at the next checkpoint (second review A-11). After a power cut the removed rows could come back pointing at deleted files. Each batch's commit is now synced with `F_FULLFSYNC` (`synchronous = FULL` for that transaction) before its first file is deleted. Removing 10,000 messages took 11.6 s before and 12.6 s after.
- **Low:** `stowmail archive-move` released the writer lock before asking whether to delete the old copy, so a background sync that had opened the old folder could sync mail into it, which the deletion then destroyed (second review A-10). The command now holds the lock until it ends, and leaves `moved-to.json` in the old folder, flushed, before switching. `Archive.open`, `createArchive` and `archive-location` refuse a folder with it and name the new place. The scheduler checks for it after opening and again after taking the lock, and `stowmail daemon run` then exits with status 75 so launchd starts it afresh at the new place. A background sync installed with `STOW_ARCHIVE_DIR` pinned to another folder is warned about before the switch. The move itself is now `ArchiveRelocation.move` in StowEngine; `Scheduler.run` returns why it stopped.
- **Low:** an mbox export that stopped part way (a missing or damaged stored file, a full disk, a kill) left a partial file under its final name, and the retry then failed because the file existed; "Export everything" stayed blocked until the user deleted it (second review A-20). `MboxExport.export` now writes under a hidden temporary name, flushes it and renames it into place without replacing anything (`RENAME_EXCL`), and removes the temporary file on any error. `SafeFile` gains `openTemporary(in:)` and `publishExclusively(_:as:)`.

### Added

- `stowmail doctor` prints the archive's schema version and the newest this build knows (`ArchiveSchema.versionSummary`); an archive written by a newer build is shown as such.

### Fixed

- `swift test -c release -Xswiftc -enable-testing` compiles again, so the benchmarks run. The iCloud sign-in tests, which need a debug-only plain-text test endpoint (D-471), are left out of release builds. `scripts/check.sh` now builds the tests in release too (locally only; on the CI runner it took over 4 minutes).

## 0.1.1 (29 October 2026)

### Security

- **Medium:** one attachment that crashed or hung Apple's image or PDF readers stopped text recognition (OCR) for good, and an email whose reading crashed or hung Stow was tried again on every sync (second review A-03, the part not in 0.1.0). Each import and each OCR item is now counted before it is read. After three tries that never finished, an email is stored whole exactly as received and marked "couldn't read all of this email", and an attachment is marked unreadable; archiving and OCR move on. Reading one email has a 5-minute limit and one OCR item a 10-minute limit. Marked text is tried again only by a newer version. `stowmail status`, `doctor` and `verify` count these emails, and `MessageDetail.textIncomplete` and `AttachmentInfo.textUnreadable` carry the mark. [GHSA-39ch-8w9v-qg3p](https://github.com/stowmail/stowkit/security/advisories/GHSA-39ch-8w9v-qg3p).

- **Low:** `AddressListParser.parse` and `AddressListParser.messageIDs` never returned when the string held a CR LF (`"a\r\nb"` was enough), and used memory until the process was stopped. Swift reads CR LF as one character, which the tokeniser did not move past. Email could not trigger this: header values never contain a line feed by the time they reach the parser. Only code calling these functions directly could. Found by fuzzing (second review A-22).

### Added

- GitHub Actions: build, tests and gitleaks on every push to `main` (the required `check`), CodeQL, and a short fuzzing pass.
- Fuzz targets for HTML to text, encoded words and address lists, the search query parser, the ZIP reader and IMAP reply assembly, with 1 MB inputs (`scripts/fuzz.sh`).
- Archive schema `v2`: columns for marking an email whose text could not all be read, and for counting import, re-parse and text extraction attempts. Opening an archive with this version upgrades it in place, adding columns only (about 2 seconds for 40,000 emails); every stored email keeps its meaning, and older versions still open an upgraded archive.

## 0.1.0 (28 October 2026)

First tagged release.

### Security

- **High:** a crafted email could stop archiving: converting its HTML to text, or decoding its headers' encoded words, took time proportional to the square of its size. [GHSA-xhg9-88xv-2q76](https://github.com/stowmail/stowkit/security/advisories/GHSA-xhg9-88xv-2q76).
- **Low:** a mail server could hold sync without limit. Each IMAP command now has a byte limit and a deadline, replies for messages not asked for are dropped, and one stuck account no longer holds up the others.
- Text read from each part of an email is capped at 10 MB, and PDF text extraction has a 30-second limit.
