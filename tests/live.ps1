#Requires -Version 7.0
<#
.SYNOPSIS
    Live end-to-end tests: real agy helpers on Gemini 3.8 Flash High.

.DESCRIPTION
    Needs agy installed and signed in. Takes about 2-4 minutes and uses roughly 250k agy (Gemini) tokens.
    It runs the scripts from this repository, not the installed copy. It adds a test MCP server to agy
    while it runs and removes it again at the end.

.EXAMPLE
    pwsh ./tests/live.ps1
#>
param([switch]$KeepFiles)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$agyScript = Join-Path $repo 'skills/agy/scripts/agy.ps1'
$pwsh = (Get-Process -Id $PID).Path
$script:Passed = 0
$script:Failed = 0

function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { $script:Passed++; "  PASS  $Name" } else { $script:Failed++; "  FAIL  $Name" }
}
function Invoke-Skill([string[]]$ArgList) {
    $text = & $pwsh -NoProfile -File $agyScript @ArgList 2>&1 | Out-String
    [pscustomobject]@{ Text = $text; Code = $LASTEXITCODE }
}
function Get-Results([string]$Text) {
    if ($Text -match 'full results: (.+results\.json)') { return @(Get-Content -LiteralPath $Matches[1].Trim() -Raw | ConvertFrom-Json -AsHashtable) }
    @()
}
function Get-AnswerText($Result) {
    if ($null -eq $Result) { return '' }
    $a = $Result['answer']
    if ($a -is [System.Collections.IDictionary]) { return ([string]$a['answer'] + ' ' + (@($a['sources']) -join ' ')) }
    [string]$a
}
function Get-Sources($Result) {
    $a = if ($Result) { $Result['answer'] } else { $null }
    if ($a -is [System.Collections.IDictionary]) { return @(@($a['sources']) | Where-Object { $_ }) }
    @()
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('agy-live-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$t0 = Get-Date
$log = [System.Collections.Generic.List[string]]::new()

'1. Health check'
$doctor = Invoke-Skill @('doctor', '-Smoke')
$log.Add($doctor.Text)
Check 'doctor finds agy and the model' (($doctor.Text -match 'model: ') -and ($doctor.Text -notmatch 'NOT available'))
Check 'helper agents are installed' (($doctor.Text -split "`n" | Where-Object { $_ -match '^helper agent .+: installed' }).Count -eq 3)
Check 'smoke task answers' ($doctor.Text -match '1 task\(s\), 1 ok, 0 failed')

'2. Six helpers in parallel'
# A throwaway project whose approved .mcp.json points at the PowerShell test MCP server.
$proj = Join-Path $work 'project'
New-Item -ItemType Directory -Force -Path (Join-Path $proj '.claude') | Out-Null
$fixture = Join-Path $PSScriptRoot 'fixtures/mcp-test-server.ps1'
ConvertTo-Json -Depth 5 -InputObject @{ mcpServers = @{ 'agy-helpers-test' = @{ type = 'stdio'; command = $pwsh; args = @('-NoProfile', '-File', $fixture) } } } |
    Set-Content -LiteralPath (Join-Path $proj '.mcp.json') -Encoding utf8NoBOM
'{"enableAllProjectMcpServers": true}' | Set-Content -LiteralPath (Join-Path $proj '.claude/settings.local.json') -Encoding utf8NoBOM
$pwshVersion = ((& $pwsh --version) | Out-String).Trim() -replace '^PowerShell\s+', ''
$skillDir = (Join-Path $repo 'skills/agy') -replace '\\', '/'
$tasks = @{ tasks = @(
        @{ id = 'research'; prompt = 'What is the latest stable release of PowerShell 7 (version number) and its release date? Use the official PowerShell GitHub releases page.' }
        @{ id = 'summary'; prompt = 'Summarize in 3 short bullets what this document says about permissions in headless mode.'; files = @("$skillDir/references/notes.md"); web = 'off' }
        @{ id = 'mcp'; prompt = 'Call the get_secret_word tool of the agy-helpers-test MCP server and report the word it returns.'; web = 'off' }
        @{ id = 'command'; prompt = 'Run the allowed command and report its output exactly.'; allowCommands = @('pwsh --version'); web = 'off'; mcp = 'off' }
        @{ id = 'edit'; prompt = 'Create a file named hello.md containing a two-line poem about cats. Report the file name.'; access = 'edit'; web = 'off'; mcp = 'off' }
        @{ id = 'folder'; prompt = "List the files inside the folder $skillDir and its subfolders, and say which file is the largest."; addDirs = @($skillDir); web = 'off'; mcp = 'off' }
    )
}
$tasksFile = Join-Path $work 'tasks.json'
ConvertTo-Json -InputObject $tasks -Depth 10 | Set-Content -LiteralPath $tasksFile -Encoding utf8NoBOM
$run = Invoke-Skill @('run', '-TasksFile', $tasksFile, '-ProjectDir', $proj)
$log.Add($run.Text)
$byId = @{}
foreach ($r in (Get-Results $run.Text)) { $byId[$r['id']] = $r }
Check 'all six helpers finished ok' ($run.Code -eq 0 -and $byId.Count -eq 6 -and @($byId.Values | Where-Object { -not $_['ok'] }).Count -eq 0)
Check 'research: answered with a source' ($byId['research'] -and $byId['research']['ok'] -and (Get-Sources $byId['research']).Count -gt 0)
Check 'summary: read the attached file' ($byId['summary'] -and $byId['summary']['ok'] -and ((Get-AnswerText $byId['summary']) -match '(?i)permission|allow|refus'))
Check 'mcp: used the MCP server synced from .mcp.json' ($byId['mcp'] -and $byId['mcp']['ok'] -and ((Get-AnswerText $byId['mcp']) -match 'pineapple-42'))
Check 'command: ran the allowed command' ($byId['command'] -and $byId['command']['ok'] -and ((Get-AnswerText $byId['command']) -match [regex]::Escape($pwshVersion)))
Check 'edit: created the file in its folder' ($byId['edit'] -and $byId['edit']['ok'] -and (Test-Path -LiteralPath (Join-Path $byId['edit']['cwd'] 'hello.md')))
Check 'folder: read the extra folder' ($byId['folder'] -and $byId['folder']['ok'] -and ((Get-AnswerText $byId['folder']) -match 'SKILL\.md'))

'3. Follow-up'
$conv = if ($byId['research']) { [string]$byId['research']['conversation_id'] } else { '' }
if ($conv) {
    $follow = Invoke-Skill @('followup', '-Conversation', $conv, '-Message', 'In one sentence: which PowerShell 7 release came just before the one you found?')
    $log.Add($follow.Text)
    Check 'follow-up answered in the same conversation' ($follow.Code -eq 0 -and $follow.Text -match '\[ok\] followup' -and $follow.Text -match [regex]::Escape($conv))
} else { Check 'follow-up answered in the same conversation' $false }

'4. MCP cleanup'
$sync = Invoke-Skill @('sync', '-ProjectDir', $work)
$log.Add($sync.Text)
$mcpCfg = Get-Content -LiteralPath (Join-Path $HOME '.gemini/config/mcp_config.json') -Raw | ConvertFrom-Json -AsHashtable
Check 'test MCP server removed from agy again' (-not ($mcpCfg['mcpServers'] -and $mcpCfg['mcpServers'].Contains('agy-helpers-test')))

''
'{0} passed, {1} failed, {2:N0}s' -f $script:Passed, $script:Failed, ((Get-Date) - $t0).TotalSeconds
if ($script:Failed -gt 0 -or $KeepFiles) {
    $log -join "`n" | Set-Content -LiteralPath (Join-Path $work 'output.log') -Encoding utf8NoBOM
    "Test files and output kept in: $work"
} else {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit ([int]($script:Failed -gt 0))
