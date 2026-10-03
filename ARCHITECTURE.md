# Architecture

```
Discord → AI Gateway → Task queue → LocalAI
                   └→ Tool registry → existing SVM services (VPS, nodes, IPAM, ports, billing)
StatusService → Discord status channel • presence • SVG • PNG
```
