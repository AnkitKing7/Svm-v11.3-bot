# Install

1. `sudo bash install.sh` — dependencies, backup, venv, systemd, firewall, `svm` CLI.
2. `sudo bash install.sh --configure` — Discord token, gateways, IP pool, ports.
3. `sudo bash install.sh ai-install` — AI wizard (endpoint, model, streaming, sandbox, status channel). Models are never downloaded without a confirmation.
4. `sudo bash install.sh doctor` / `ai-doctor` — verify everything.

Rollback: `sudo bash install.sh --rollback`.
