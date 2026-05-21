# Dspeech - aviation cockpit / ATC transcription (iOS) - per-run agent logs

Each substantive agent run gets a subdirectory:

    .ai/runs/<YYYY-MM-DD-HHMMSS>-<short-slug>/
        plan.md           # the plan the lead followed
        handoff.md        # structured handoffs between roles
        mission-report.md # final report

Logs are append-only. Do not edit historical runs - rotate by adding a new
directory. The `knowledge-curator` distils these into `docs/ai-kb/`.
