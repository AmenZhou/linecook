<!--
Provenance: extracted from the private ai-toolbox repository (https://github.com/AmenZhou/ai-toolbox),
which is not publicly available. Embedded in linecook under this repo's MIT license — see /LICENSE.
Adapted for this repo: only the "File & Destructive Operation Safety" section is included — the
source file's "Canonical Orchestrate Inbox" section documented a private, author-specific inbox
routing convention with no equivalent in linecook's current scope, and was excluded rather than
scrubbed (path substitution would leave a section with no transferable meaning).
-->

## File & Destructive Operation Safety

- **ALWAYS ask the user for confirmation before deleting any files**, regardless of context or purpose
- NEVER use destructive commands (rm, del, rmdir, etc.) without explicit user confirmation
- ALWAYS ask for confirmation before any overwrite or file system modification
- NEVER overwrite important files without backup or confirmation
- ALWAYS preserve existing code unless explicitly requested to change
- When proposing file deletions, clearly explain what will be deleted and why, and wait for confirmation before proceeding
- If asked to delete files, always double-check with user
- If unsure about any destructive operation, ask for clarification
- Prioritize data safety over convenience — when in doubt, preserve rather than delete
