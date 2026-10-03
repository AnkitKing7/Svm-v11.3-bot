# Security

- Secrets only in `.env` (chmod 600); packages and docs never include them.
- Uploaded files are validated, extracted safely (no traversal/links/bombs) and never executed on the host.
- Sandbox: Docker, no network, read-only root, dropped capabilities, CPU/RAM/time limits, command allowlist.
- File edits: main admin only, diff preview, confirmation, backup, syntax check.
- Payments: only the gateway webhook/API can mark an order paid.
- Audit log: `ai_audit_logs` (secrets redacted).
