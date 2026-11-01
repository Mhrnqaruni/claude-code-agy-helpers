# agy helper notes

Tested with agy 1.4.12 on Windows 10 with PowerShell 7.6, November 2026.

## How a run works

- Each task is one headless `agy -p` process with `--agent claude-helper[-cmd|-edit]`, `--model gemini-3.8-flash-high`, `--output-format json`, `--json-schema`, a per-task `--settings` permissions file, `--print-timeout`, `--add-dir` for extra folders, and `--mode accept-edits` for edit tasks.
- Up to `-MaxParallel` processes run at once (default 6). A run that fails without a permission, timeout, quota or sign-in problem is retried once.
- Each run writes to `%TEMP%\agy-runs\<timestamp>\`: one folder per task (prompt, settings, raw agy output, `task.json`), plus `results.json` for the whole batch.
- The token numbers in the summary are agy's (Gemini) tokens, not Claude's.
- The model is Gemini 3.8 Flash High. The `AGY_HELPER_MODEL` environment variable can name another agy model, such as `gemini-3.8-flash-low`.

## Permissions in headless mode

- Headless agy cannot ask for approval. Any action that needs approval is refused, and the run then ends with an empty answer. That is why each helper agent has a fixed tool list and each task gets exact allow rules.
- Per-run rules via `--settings` work. Formats tested:
  - `command(npm test)`: that exact command text only.
  - `read_url(*)`: all web pages. `read_url(example.com)`: one domain.
  - `mcp(*)`: all MCP tools. `mcp(server/tool)`: one tool. `mcp(server)` alone does NOT work.
- Web search needs no rule. Opening the result pages needs `read_url`.
- `--mode accept-edits` lets a helper create and edit files in its workspace.
- On the Windows test machine, `--mode auto` and `--sandbox` were not available: agy reported that its terminal sandbox is not available on the host.

## Helper agents

`sync` installs these into `~/.gemini/config/agents/`. Each has `subagent: false`, so agy's own agents don't call them.

| Agent | Tools |
|---|---|
| `claude-helper` | search_web, read_url_content, view_file, list_dir, find_by_name, grep_search, finish |
| `claude-helper-cmd` | the above plus run_command, command_status |
| `claude-helper-edit` | the above plus write_to_file, replace_file_content, multi_replace_file_content |

They have no browser, subagent or image tools, so helpers can't open windows or start more agents. MCP tools are available to all three when `mcp` is on. Don't list MCP tool names such as `call_mcp_tool` in an agent's `tools`: agy refuses to start the agent.

Keep `finish` in every agent's tools. With `--json-schema`, agy hands back the structured answer through `finish`. Without it the model repeated its answer until stopped: the same six-task test used 975k tokens and took 137 s, against 232k tokens and 60 s with `finish`.

## MCP and plugin sync

- Sources: user-scope `mcpServers` in `~/.claude.json`, the current project's `mcpServers` there, and the project's `.mcp.json` servers the user approved in Claude Code (`enabledMcpjsonServers` or `enableAllProjectMcpServers`).
- Target: `~/.gemini/config/mcp_config.json`, agy's global MCP file; agy has no per-folder MCP config. Synced names are tracked in `~/.gemini/config/claude-sync-state.json`. A server removed from Claude Code is removed from agy, and agy's own entries are never touched.
- `${VAR}` and `${VAR:-default}` placeholders are filled from the environment when syncing. `npx`, `npm`, `pnpm`, `yarn` and `bunx` commands are wrapped in `cmd /c` on Windows.
- Not shareable: legacy SSE servers, servers that sign in with OAuth inside Claude Code (sign in again in agy), and the claude.ai connectors of the desktop app.
- Claude Code plugins are copied with `agy plugin import claude` whenever `~/.claude/plugins/installed_plugins.json` changes.
- `sync -ShareClaudeSkills` points agy at `~/.claude/skills` (this skill excluded), so helpers can use the user's personal skills.

## Measured on the test machine

- Simple research task (3 searches): about 25-45 s and 35k-45k agy tokens. Five ran in parallel in 53 s.
- agy's web search takes 2-6 s per search.
- agy does not cache prompts: each model call resends a setup of about 7k tokens.
- When a conversation is resumed, agy reports usage and duration for the whole conversation. `followup` subtracts the earlier turns.

## Caveats

- Google's terms for scripting agy on consumer plans are unclear. A Google forum thread from September-October 2026 has no official answer. Keep usage personal and reasonable.
- Gemini 3.8 Flash trails Claude Opus 5.5 on most benchmarks (Vals.ai: 22 of 24 shared tests) but is close to Opus 5 on some coding tests. It made a date mistake in testing, so verify what matters.
