# Security policy

## Reporting a vulnerability

Please [report vulnerabilities privately through GitHub](https://github.com/haseab/retrace/security/advisories/new) using **Security → Report a vulnerability**. Do not post sensitive details in public issues.

Include your Retrace version or commit, macOS version, reproduction steps, expected and actual behavior, and relevant settings such as encryption, exclusions, or keyword protection. Use a small, sanitized example where possible. Do not attach real recordings, private OCR text, passwords, encryption keys, or recovery phrases.

## Scope

Reports may cover unintended exposure of recordings, OCR text, URLs, window titles, or search queries; failures of exclusions or redaction; encryption or key-handling failures; and vulnerabilities in updates, diagnostics, feedback, or other network paths.

Scrambling is reversible by design; permanent redaction is a separate mode. Reversibility alone is not a vulnerability in scramble mode, but unintended disclosure or behavior that breaks the selected protection is worth reporting. Access that requires an already-compromised macOS account is generally outside scope, unless Retrace introduces an additional weakness.

## Supported versions and follow-up

Security fixes target the latest release and `main`. Older versions may require an upgrade; separate backports are not guaranteed.

We will review private reports and use the report thread for questions and updates. There is no guaranteed response or resolution deadline. Please coordinate public disclosure there so a fix can be prepared. Let us know whether and how you would like to be credited.

For ordinary bugs and feature requests, use [GitHub Issues](https://github.com/haseab/retrace/issues).
