# AI Agent

All of `!aiask`, `!ask`, `!ai`, `!askai` use the same gateway → task queue → LocalAI.

## Commands
- `!aiask|!ask|!ai|!askai <message>`
- `!askai start|stop|restart|status|models|help|capabilities`
- `!askai new|clear|history|session`
- `!askai tasks|task <id>|cancel [id]`
- `!askai vps|nodes|node <id>|resources|network|ports|ipam`
- `!askai live|status svg|status png|generate svg|generate png`
- `!askai analyze (attach file)|project|package|create README|create documentation`
- `!askai edit <file> <instruction>  (main admin)`
- `!askai run python <file>  (sandbox)`
- `!askai image <prompt>|learn <topic> [beginner|intermediate|advanced]`
- `!askai usage|config|diagnostics|payment summary  (admin)`
- `!askai channel enable|disable  (admin)`
- `!status-channel set <id>|show|disable  (admin)`

## Safety model
Discord permission → SVM authorization → AI gateway → tool permission → existing SVM service. The model can never grant permissions, execute a shell, mark a payment paid, or see another customer's data. Destructive actions need a Confirm button that expires after 60 seconds.
