# Contributing

Thank you for helping. Stow's engine is open source under the Apache License 2.0.

## Licence of contributions

Under section 5 of the Apache License 2.0, anything you intentionally submit for inclusion (a pull request, a patch, a suggested change) is licensed under the same Apache 2.0 terms, unless you clearly say otherwise when you submit it. There is no separate contributor licence agreement.

You may add a Developer Certificate of Origin sign-off (`git commit -s`, see https://developercertificate.org) to say you have the right to submit the work. It is welcome but not required.

## Before you open a pull request

- Run `scripts/install-hooks.sh` once per clone, then `scripts/check.sh`, which builds, runs the tests and scans for secrets with gitleaks. It must pass.
- Swift 6 language mode with strict concurrency; macOS 14 or later.
- Follow the module dependency rule in the README.
- Apple frameworks before third-party packages. A new dependency needs a good reason, stated in the pull request.

## Rules that are never relaxed

- **Never write to a mail server.** No IMAP command beyond those in `ReadOnlyCommand`.
- **No secrets anywhere but the Keychain.** Not in code, logs, tests, fixtures or commits.
- **No real email in the repository.** Test fixtures are synthetic (`scripts/make-fixtures`), using reserved domains such as `example.com`.
- **Never log message content, subject lines or tokens.** Email addresses only through `Redact`.

## Security issues

Please do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).
