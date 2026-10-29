# Changelog

Changes to StowKit and the `stowmail` command-line tool, newest first. Security fixes rated Medium or worse also get a GitHub security advisory; Low ones are listed here only (see [SECURITY.md](SECURITY.md)).

## 0.1.1 (29 October 2026)

### Security

- **Medium:** one attachment that crashed or hung Apple's image or PDF readers stopped text recognition (OCR) for good, and an email whose reading crashed or hung Stow was tried again on every sync (second review A-03, the part not in 0.1.0). Each import and each OCR item is now counted before it is read. After three tries that never finished, an email is stored whole exactly as received and marked "couldn't read all of this email", and an attachment is marked unreadable; archiving and OCR move on. Reading one email has a 5-minute limit and one OCR item a 10-minute limit. Marked text is tried again only by a newer version. `stowmail status`, `doctor` and `verify` count these emails, and `MessageDetail.textIncomplete` and `AttachmentInfo.textUnreadable` carry the mark.

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
