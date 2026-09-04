# scripts design system

## Overview

This repository provides terminal and machine interfaces in Bash, Python, and Node.js.
Each tool keeps its own focused contract instead of sharing one CLI framework.
Design changes must favor safe operation, readable output, and predictable automation.

## Colors

There is no shared color palette.
Most output is plain text.
The devbox bootstrap uses limited ANSI blue and yellow status text.
The CI cache health tool removes ANSI sequences from captured logs.
Never add styling to JSON or other machine-readable output.

## Typography

Use the host terminal's monospace font.
Represent structured results with plain tables, JSON, or Markdown when supported.
Do not depend on a custom font, terminal theme, or Unicode decoration.

## Layout

Many executables and their focused tests live at the repository root.
Hooks, templates, machine setup, and larger tools use named directories.
The remote cache Worker stays isolated under `turbo-remote-cache`.
Keep related tests beside their tool or within its directory.

## Elevation & Depth

Hierarchy is procedural, not visual.
Use headings, ordered steps, indentation, and exit status to show importance.
Do not simulate panels, shadows, or decorative depth in terminal output.

## Shapes

There is no repository logo or interface shape language.
Use stable ASCII rows, JSON objects, and Markdown blocks as structural forms.
Keep output usable in narrow terminals, logs, pipes, and CI annotations.

## Components

Common components include usage text, input validation, results, diagnostics, and exit codes.
Use JSON only where a command defines a JSON interface.
Use dry-run or confirmation modes only where the command defines them.
Add a focused test beside every changed behavior.

## Do's and Don'ts

- Do read a command's help and prerequisites before execution.
- Do validate inputs before any mutation.
- Do preserve stable machine-readable output.
- Do document side effects and required credentials.
- Do send actionable diagnostics to standard error where appropriate.
- Don't log secrets, tokens, or credential values.
- Don't claim that every script supports the same flags.
- Don't add color or prose to structured output.
- Don't hide failures behind silent fallbacks.
