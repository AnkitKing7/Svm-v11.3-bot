# Troubleshooting

- `svm doctor` / `install.sh ai-doctor` — first stop.
- LocalAI unreachable → `install.sh ai-status`, check `LOCALAI_BASE_URL`.
- Model not ready → `install.sh ai-models` and set `LOCALAI_MODEL` to an installed model.
- No PNG → install `cairosvg` or `librsvg2-bin`.
- Sandbox unavailable → install Docker and `docker pull` the sandbox image.
- Webhooks → `!gateways`, and your HTTPS proxy must reach the webhook port.
