# Changelog

## 1.0.0 (2026-11-01)

First public release.

- `agy` skill for Claude Code that runs agy helpers on Gemini 3.8 Flash High in parallel and returns a compact summary.
- Script commands: `run`, `followup`, `sync`, `doctor` and `clean`.
- Three agy helper agents with fixed tool lists: read-only, commands, and edit.
- Per-task permissions through agy's `--settings`: web pages, MCP tools, exact commands, and file edits.
- Sync of Claude Code's MCP servers (user scope, project scope and approved `.mcp.json` servers) and plugins into agy on every run.
- Structured answers with status, sources, confidence and notes.
- Installer with a health check, plus an uninstaller.
- 32 offline unit tests (CI on Windows, macOS and Linux) and a live end-to-end test suite.
