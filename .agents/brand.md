# scripts brand

This repository is a public automation collection for personal agent operations.
It is not one product or one uniform command-line application.

The primary audience is the operator maintaining the workspace.
Agents and contributors are a secondary audience.

Commands must make prerequisites, side effects, and results clear.
Use direct, command-first language. Prefer exact actions over promotional claims.

Preserve each script's existing interface contract.
Some commands inspect state, while others change local or remote state.
Use dry-run, apply, or execute modes only where that command implements them.

Keep secrets and credentials out of output, examples, fixtures, and documentation.
Report errors explicitly and return meaningful exit codes.

The `turbo-remote-cache` Worker is an internal cache API.
It does not establish a public product website or shared visual identity.
