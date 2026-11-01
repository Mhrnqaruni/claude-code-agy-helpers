#Requires -Version 7.0
<#
.SYNOPSIS
    Runs Google's agy CLI (Gemini 3.8 Flash High) as parallel helper agents for Claude Code.

.DESCRIPTION
    run       Run one task (-Prompt) or a batch (-TasksFile) in parallel and print a compact summary.
    followup  Send a follow-up message to an earlier helper (-Conversation <id> -Message <text>).
    sync      Install the helper agents and copy Claude Code's MCP servers and plugins into agy.
    doctor    Check agy, the model, the helper agents and the MCP sync (-Smoke also runs a tiny task).
    clean     Delete run folders older than -OlderThanDays days.

    Every run and follow-up starts with a quick sync, so helpers see the caller's current MCP servers.

.LINK
    https://github.com/Mhrnqaruni/claude-code-agy-helpers
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('run', 'followup', 'sync', 'doctor', 'clean')]
    [string]$Command = 'run',
    [string]$TasksFile,
    [string]$Prompt,
    [string]$Id = 'task',
    [ValidateSet('read', 'commands', 'edit')]
    [string]$Access = 'read',
    [string]$AllowCommands,
    [string]$AddDir,
    [string]$Files,
    [string]$WorkDir,
    [ValidateSet('on', 'off')]
    [string]$Web = 'on',
    [ValidateSet('on', 'off')]
    [string]$Mcp = 'on',
    [string]$Schema,
    [ValidateRange(1, 20)]
    [int]$MaxParallel = 6,
    [ValidateRange(30, 3600)]
    [int]$TimeoutSec = 300,
    [ValidateRange(0, 3)]
    [int]$Retries = 1,
    [ValidateRange(80, 20000)]
    [int]$AnswerChars = 600,
    [string]$OutDir,
    [string]$Conversation,
    [string]$Message,
    [string]$ProjectDir = (Get-Location).Path,
    [switch]$ShareClaudeSkills,
    [switch]$Force,
    [switch]$Smoke,
    [ValidateRange(0, 365)]
    [int]$OlderThanDays = 7
)

$ErrorActionPreference = 'Stop'
$SkillDir = Split-Path -Parent $PSScriptRoot
$Model = if ($env:AGY_HELPER_MODEL) { $env:AGY_HELPER_MODEL } else { 'gemini-3.8-flash-high' }
$ModelName = if ($env:AGY_HELPER_MODEL) { $env:AGY_HELPER_MODEL } else { 'Gemini 3.8 Flash (High)' }
$AgyConfig = Join-Path $HOME '.gemini/config'
$StateFile = Join-Path $AgyConfig 'claude-sync-state.json'
$RunsRoot = Join-Path ([IO.Path]::GetTempPath()) 'agy-runs'
$DefaultSchema = Join-Path $SkillDir 'schemas/answer.json'
$HelperAgents = 'claude-helper', 'claude-helper-cmd', 'claude-helper-edit'
$script:ExitCode = 0

# ---------------------------------------------------------------- helpers

function Find-Agy {
    $cmd = Get-Command agy -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $candidates = @()
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'agy/bin/agy.exe' }
    $candidates += Join-Path $HOME '.local/bin/agy'
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    throw 'agy was not found. Install the Antigravity CLI (agy), then run agy once in a terminal to sign in.'
}

function Split-List($Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    return @($Value | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}

function Test-On($Value) { -not ("$Value" -match '^(off|false|no|0)$') }

function Read-JsonFile([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
        if ($raw -and $raw.Trim()) { return ($raw | ConvertFrom-Json -AsHashtable -Depth 100) }
    } catch { }
    return $null
}

function Write-JsonFile([string]$Path, $Value) {
    ConvertTo-Json -InputObject $Value -Depth 50 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Start-Agy([string]$Exe, [string[]]$ArgList, [string]$Cwd) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new($Exe)
    foreach ($a in $ArgList) { $psi.ArgumentList.Add([string]$a) }
    $psi.WorkingDirectory = $Cwd
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $proc = [System.Diagnostics.Process]::Start($psi)
    try { $proc.StandardInput.Close() } catch { }
    [pscustomobject]@{
        Process = $proc
        Out     = $proc.StandardOutput.ReadToEndAsync()
        Err     = $proc.StandardError.ReadToEndAsync()
        Started = [datetime]::Now
    }
}

function Get-Text($Task) { try { return [string]$Task.GetAwaiter().GetResult() } catch { return '' } }

function Invoke-AgyQuick([string]$Exe, [string[]]$ArgList, [int]$Seconds = 60) {
    $h = Start-Agy $Exe $ArgList $HOME
    if (-not $h.Process.WaitForExit($Seconds * 1000)) { try { $h.Process.Kill($true) } catch { }; return '(timed out)' }
    ((Get-Text $h.Out) + "`n" + (Get-Text $h.Err)).Trim()
}

# ---------------------------------------------------------------- sync

function Expand-Vars([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $v = [Environment]::GetEnvironmentVariable($m.Groups[1].Value)
        if (-not [string]::IsNullOrEmpty($v)) { $v } elseif ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Value }
    }
    [regex]::Replace($Text, '\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}', $evaluator)
}

# Converts one Claude Code MCP server entry to agy's mcp_config.json format, or $null if agy can't run it.
function Convert-Server($Cfg) {
    if ($null -eq $Cfg) { return $null }
    if ("$($Cfg['type'])" -eq 'sse') { return $null }
    if ($Cfg['url']) {
        $out = [ordered]@{ url = Expand-Vars ([string]$Cfg['url']) }
        if ($Cfg['headers']) {
            $headers = [ordered]@{}
            foreach ($k in $Cfg['headers'].Keys) { $headers[$k] = Expand-Vars ([string]$Cfg['headers'][$k]) }
            $out['headers'] = $headers
        }
        return $out
    }
    if ($Cfg['command']) {
        $command = Expand-Vars ([string]$Cfg['command'])
        $argv = @(@($Cfg['args']) | Where-Object { $null -ne $_ } | ForEach-Object { Expand-Vars ([string]$_) })
        if ($IsWindows -and $command -match '^(npx|npm|pnpm|yarn|bunx)$') { $argv = @('/c', $command) + $argv; $command = 'cmd' }
        $out = [ordered]@{ command = $command }
        if ($argv.Count) { $out['args'] = $argv }
        if ($Cfg['env']) {
            $envMap = [ordered]@{}
            foreach ($k in $Cfg['env'].Keys) { $envMap[$k] = Expand-Vars ([string]$Cfg['env'][$k]) }
            $out['env'] = $envMap
        }
        return $out
    }
    return $null
}

# The MCP servers Claude Code would use in $Project: user scope, the project's own entries,
# and the project's .mcp.json servers that the user approved.
function Get-ClaudeMcpServers(
    [string]$Project,
    [string]$ClaudeJson = (Join-Path $HOME '.claude.json'),
    [string]$UserSettings = (Join-Path $HOME '.claude/settings.json')
) {
    $servers = [ordered]@{}
    $entry = $null
    $cj = Read-JsonFile $ClaudeJson
    if ($cj) {
        if ($cj['mcpServers']) { foreach ($k in $cj['mcpServers'].Keys) { $servers[$k] = $cj['mcpServers'][$k] } }
        $want = ($Project -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
        if ($cj['projects']) {
            foreach ($pk in $cj['projects'].Keys) {
                if (($pk -replace '\\', '/').TrimEnd('/').ToLowerInvariant() -eq $want) { $entry = $cj['projects'][$pk] }
            }
        }
        if ($entry -and $entry['mcpServers']) { foreach ($k in $entry['mcpServers'].Keys) { $servers[$k] = $entry['mcpServers'][$k] } }
    }
    $pj = Read-JsonFile (Join-Path $Project '.mcp.json')
    if ($pj -and $pj['mcpServers']) {
        $approved = @(); $disabled = @(); $all = $false
        if ($entry) { $approved += @($entry['enabledMcpjsonServers']); $disabled += @($entry['disabledMcpjsonServers']) }
        foreach ($sf in (Join-Path $Project '.claude/settings.json'), (Join-Path $Project '.claude/settings.local.json'), $UserSettings) {
            $s = Read-JsonFile $sf
            if ($s) {
                if ($s['enableAllProjectMcpServers'] -eq $true) { $all = $true }
                $approved += @($s['enabledMcpjsonServers']); $disabled += @($s['disabledMcpjsonServers'])
            }
        }
        foreach ($k in $pj['mcpServers'].Keys) {
            if (($all -or $approved -contains $k) -and $disabled -notcontains $k) { $servers[$k] = $pj['mcpServers'][$k] }
        }
    }
    return $servers
}

# Merges Claude Code's servers into agy's config. Entries this skill did not create are never changed.
function Merge-McpServers($Config, $ClaudeServers, [string[]]$PreviouslySynced) {
    if ($null -eq $Config) { $Config = [ordered]@{} }
    if ($null -eq $Config['mcpServers']) { $Config['mcpServers'] = [ordered]@{} }
    $prev = @($PreviouslySynced | Where-Object { $_ })
    $synced = [System.Collections.Generic.List[string]]::new()
    $changes = [System.Collections.Generic.List[string]]::new()
    $info = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($ClaudeServers.Keys)) {
        $conv = Convert-Server $ClaudeServers[$name]
        if ($null -eq $conv) { $info.Add("skipped MCP server $name (agy does not support its transport)"); continue }
        if ($Config['mcpServers'].Contains($name) -and $prev -notcontains $name) { $info.Add("kept agy's own MCP server $name (same name as in Claude Code)"); continue }
        $Config['mcpServers'][$name] = $conv
        $synced.Add($name)
    }
    foreach ($name in $prev) {
        if (-not $synced.Contains($name) -and $Config['mcpServers'].Contains($name)) {
            $Config['mcpServers'].Remove($name)
            $changes.Add("removed MCP server $name (no longer in Claude Code)")
        }
    }
    [pscustomobject]@{ Config = $Config; Synced = [string[]]$synced.ToArray(); Changes = $changes; Info = $info }
}

function Invoke-Sync([switch]$Quiet) {
    $agy = Find-Agy
    $changes = [System.Collections.Generic.List[string]]::new()
    New-Item -ItemType Directory -Force -Path (Join-Path $AgyConfig 'agents') | Out-Null
    $state = Read-JsonFile $StateFile
    if ($null -eq $state) { $state = [ordered]@{} }

    # 1. Helper agents used by every run.
    foreach ($src in Get-ChildItem -LiteralPath (Join-Path $SkillDir 'agents') -Filter '*.md' -File) {
        $dst = Join-Path $AgyConfig "agents/$($src.Name)"
        if ($Force -or -not (Test-Path -LiteralPath $dst) -or (Get-FileHash -LiteralPath $src.FullName).Hash -ne (Get-FileHash -LiteralPath $dst).Hash) {
            Copy-Item -LiteralPath $src.FullName -Destination $dst -Force
            $changes.Add("installed helper agent $($src.BaseName)")
        }
    }

    # 2. MCP servers from Claude Code into agy's global config (agy has no per-folder MCP config).
    $mcpPath = Join-Path $AgyConfig 'mcp_config.json'
    $cfg = Read-JsonFile $mcpPath
    $before = if ($cfg) { ConvertTo-Json -InputObject $cfg -Depth 50 -Compress } else { '' }
    $merge = Merge-McpServers $cfg (Get-ClaudeMcpServers -Project $ProjectDir) ([string[]]@($state['mcpServers']))
    if ((ConvertTo-Json -InputObject $merge.Config -Depth 50 -Compress) -ne $before) {
        Write-JsonFile $mcpPath $merge.Config
        if ($merge.Synced.Count) { $changes.Add('MCP servers from Claude Code: ' + ($merge.Synced -join ', ')) }
    }
    foreach ($c in $merge.Changes) { $changes.Add($c) }
    $state['mcpServers'] = @($merge.Synced)

    # 3. Claude Code plugins (skills, agents, rules, MCP servers) into agy, when they change.
    $pluginsFile = Join-Path $HOME '.claude/plugins/installed_plugins.json'
    if (Test-Path -LiteralPath $pluginsFile) {
        $hash = (Get-FileHash -LiteralPath $pluginsFile).Hash
        if ($Force -or $state['pluginsHash'] -ne $hash) {
            $h = Start-Agy $agy @('plugin', 'import', 'claude') $HOME
            if ($h.Process.WaitForExit(120000)) {
                $msg = (((Get-Text $h.Out) + ' ' + (Get-Text $h.Err)) -replace '\s+', ' ').Trim()
                $changes.Add('Claude Code plugins imported: ' + $msg.Substring(0, [Math]::Min(200, $msg.Length)))
                if ($h.Process.ExitCode -eq 0) { $state['pluginsHash'] = $hash }
            } else {
                try { $h.Process.Kill($true) } catch { }
                $changes.Add('Claude Code plugin import timed out')
            }
        }
    }

    # 4. Optional: let agy discover Claude Code's personal skills (this skill excluded).
    if ($ShareClaudeSkills) {
        $skPath = Join-Path $AgyConfig 'skills.json'
        $sk = Read-JsonFile $skPath
        if ($null -eq $sk) { $sk = [ordered]@{} }
        $entries = @(@($sk['entries']) | Where-Object { $_ })
        if (-not ($entries | Where-Object { $_['path'] -eq '~/.claude/skills' })) {
            $sk['entries'] = @($entries) + @([ordered]@{ path = '~/.claude/skills'; exclude = @('^agy$', '^synced$') })
            Write-JsonFile $skPath $sk
            $changes.Add('Claude Code personal skills shared with agy (~/.claude/skills)')
        }
    }

    $state['lastSync'] = (Get-Date).ToString('o')
    Write-JsonFile $StateFile $state
    foreach ($c in $changes) { "sync: $c" }
    if (-not $Quiet) {
        foreach ($i in $merge.Info) { "sync: $i" }
        if (-not $changes.Count) { 'sync: up to date (MCP servers from Claude Code: ' + $(if ($merge.Synced.Count) { $merge.Synced -join ', ' } else { 'none' }) + ')' }
    }
}

# ---------------------------------------------------------------- run

function Get-TaskSpec {
    $defaults = @{}
    $tasks = @()
    if ($TasksFile) {
        if (-not (Test-Path -LiteralPath $TasksFile)) { throw "Tasks file not found: $TasksFile" }
        $data = Get-Content -LiteralPath $TasksFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 50
        if ($data -is [System.Collections.IDictionary]) {
            if ($data['defaults']) { $defaults = $data['defaults'] }
            if ($data['tasks']) { $tasks = @($data['tasks']) } elseif ($data['prompt']) { $tasks = @($data) }
        } else { $tasks = @($data) }
    } elseif ($Prompt) {
        $tasks = @(@{ id = $Id; prompt = $Prompt })
    } else {
        throw 'Give -TasksFile <tasks.json> or -Prompt "<task>".'
    }
    if (-not $tasks.Count) { throw 'No tasks to run.' }
    [pscustomobject]@{ Tasks = $tasks; Defaults = $defaults }
}

# Prepares one helper: its folder, context files, permission file, prompt and agy arguments.
function New-Job($T, $Defaults, [string]$RunDir, [int]$Index, [hashtable]$UsedIds) {
    function Opt([string]$Key, $Cli) {
        $v = $T[$Key]
        if ($null -eq $v -or "$v" -eq '') { $v = $Defaults[$Key] }
        if ($null -eq $v -or "$v" -eq '') { $v = $Cli }
        return $v
    }
    function Union([string]$Key, $Cli) {
        @(@(Split-List $Defaults[$Key]) + @(Split-List $T[$Key]) + @(Split-List $Cli) | Where-Object { $_ } | Select-Object -Unique)
    }

    $jobId = ([string](Opt 'id' "task$Index")) -replace '[^\w.-]', '_'
    if ($UsedIds.ContainsKey($jobId)) { $jobId = "$jobId-$Index" }
    $UsedIds[$jobId] = $true
    $taskPrompt = [string]$T['prompt']
    if (-not $taskPrompt.Trim()) { throw "Task '$jobId' has no prompt." }
    $access = ([string](Opt 'access' $Access)).ToLowerInvariant()
    if ($access -notin 'read', 'commands', 'edit') { throw "Task '$jobId': access must be read, commands or edit." }
    $cmds = Union 'allowCommands' $AllowCommands
    if ($cmds.Count -and $access -eq 'read') { $access = 'commands' }
    $webOn = Test-On (Opt 'web' $Web)
    $mcpOn = Test-On (Opt 'mcp' $Mcp)
    $timeout = [int](Opt 'timeoutSec' $TimeoutSec)
    $warnings = [System.Collections.Generic.List[string]]::new()

    $addDirs = [System.Collections.Generic.List[string]]::new()
    foreach ($d in (Union 'addDirs' $AddDir)) {
        if (Test-Path -LiteralPath $d -PathType Container) { $addDirs.Add((Resolve-Path -LiteralPath $d).Path) } else { $warnings.Add("folder not found: $d") }
    }

    $dir = Join-Path $RunDir $jobId
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $ctxDir = Join-Path $dir 'context'
    $copied = 0
    foreach ($f in (Union 'files' $Files)) {
        if (Test-Path -LiteralPath $f) {
            New-Item -ItemType Directory -Force -Path $ctxDir | Out-Null
            Copy-Item -LiteralPath $f -Destination $ctxDir -Recurse -Force
            $copied++
        } else { $warnings.Add("file not found: $f") }
    }

    $wd = [string](Opt 'workDir' $WorkDir)
    if ($wd) {
        if (-not (Test-Path -LiteralPath $wd -PathType Container)) { throw "Task '$jobId': workDir not found: $wd" }
        $cwd = (Resolve-Path -LiteralPath $wd).Path
    } else { $cwd = $dir }

    $schemaOpt = [string](Opt 'schema' $Schema)
    $schemaPath = if ($schemaOpt -eq 'none') { $null } elseif ($schemaOpt) { (Resolve-Path -LiteralPath $schemaOpt).Path } else { $DefaultSchema }

    # Per-task permissions: headless agy refuses anything not allowed here.
    $allow = [System.Collections.Generic.List[string]]::new()
    if ($webOn) { $allow.Add('read_url(*)') }
    if ($mcpOn) { $allow.Add('mcp(*)') }
    foreach ($c in $cmds) { $allow.Add("command($c)") }
    $settingsPath = Join-Path $dir 'agy-settings.json'
    Write-JsonFile $settingsPath @{ permissions = @{ allow = @($allow) } }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("[Helper task '$jobId' from Claude Code. Today is $((Get-Date).ToString('yyyy-MM-dd')).]")
    if ($copied) { $lines.Add("Context files for this task are in: $ctxDir . Read them first.") }
    if ($addDirs.Count) { $lines.Add('You may read these folders: ' + ($addDirs -join '; ')) }
    $lines.Add($(if ($webOn) { 'You may search the web and read web pages.' } else { 'Do not use the web for this task.' }))
    if ($cmds.Count) { $lines.Add("You may run only these exact commands, character for character, in ${cwd}: " + (($cmds | ForEach-Object { "[$_]" }) -join ' ') + '. Any other command is refused and your answer is lost.') }
    if ($access -eq 'edit') { $lines.Add("You may create and edit files only inside: $cwd") }
    if ($schemaPath) { $lines.Add('Return status (done, partial or blocked), answer, sources (URLs with publication dates, or file paths), confidence (high, medium or low) and notes (caveats or what is missing).') }
    $lines.Add('')
    if ($taskPrompt.Length -gt 12000) {
        $taskFile = Join-Path $dir 'task.md'
        Set-Content -LiteralPath $taskFile -Value $taskPrompt -Encoding utf8NoBOM
        $lines.Add("TASK: the full task is in $taskFile . Read it first.")
    } else {
        $lines.Add('TASK:')
        $lines.Add($taskPrompt)
    }
    $fullPrompt = $lines -join "`n"
    Set-Content -LiteralPath (Join-Path $dir 'prompt.txt') -Value $fullPrompt -Encoding utf8NoBOM

    $agent = switch ($access) { 'commands' { 'claude-helper-cmd' } 'edit' { 'claude-helper-edit' } default { 'claude-helper' } }
    $base = [System.Collections.Generic.List[string]]::new()
    $base.AddRange([string[]]@('--agent', $agent, '--model', $Model, '--output-format', 'json', '--print-timeout', "$($timeout)s", '--settings', $settingsPath))
    if ($schemaPath) { $base.AddRange([string[]]@('--json-schema', $schemaPath)) }
    if ($access -eq 'edit') { $base.AddRange([string[]]@('--mode', 'accept-edits')) }
    foreach ($d in $addDirs) { $base.AddRange([string[]]@('--add-dir', $d)) }
    if ($cwd -ne $dir) { $base.AddRange([string[]]@('--add-dir', $dir)) }

    [pscustomobject]@{
        Id = $jobId; Index = $Index; Dir = $dir; Cwd = $cwd; Access = $access; Timeout = $timeout
        Prompt = $fullPrompt; BaseArgs = [string[]]$base.ToArray(); Warnings = [string[]]$warnings.ToArray()
        Attempt = 0; Label = ''; Handle = $null; Tokens = 0; LastTokens = 0
    }
}

function Get-Hint([string[]]$Denied, [string]$StdErr, [string]$Finished) {
    if ($Denied -contains 'command') { return 'needs a command permission: add the exact command to allowCommands' }
    if ($Denied -contains 'read_url') { return 'needs web page access: set web to on' }
    if ($Denied -contains 'mcp') { return 'needs MCP access: set mcp to on' }
    if ($Denied.Count) { return 'refused actions: ' + ($Denied -join ', ') + ' (file edits need access: edit)' }
    if ($Finished -in 'print_timeout', 'killed_after_timeout') { return 'timed out: raise timeoutSec or split the task' }
    if ($StdErr -match '(?i)quota|resource_exhausted|rate.?limit|\b429\b') { return 'agy quota or rate limit: wait, then rerun with a lower -MaxParallel' }
    if ($StdErr -match '(?i)sign in|log ?in|authenticat|credential') { return 'agy is not signed in: ask the user to run agy once in a terminal and sign in' }
    $first = @($StdErr -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($first.Count) { $t = $first[0].Trim(); return 'agy error: ' + $t.Substring(0, [Math]::Min(200, $t.Length)) }
    return 'empty answer: rerun once; if it repeats, simplify the prompt'
}

# Reads one finished agy process: saves its raw output and turns it into a result record.
function Complete-Job($Job, [bool]$Killed) {
    $h = $Job.Handle
    $stdout = Get-Text $h.Out
    $stderr = Get-Text $h.Err
    $secs = [int][Math]::Round(([datetime]::Now - $h.Started).TotalSeconds)
    $label = if ($Job.Label) { $Job.Label } else { "$($Job.Attempt)" }
    Set-Content -LiteralPath (Join-Path $Job.Dir "agy-output-$label.json") -Value $stdout -Encoding utf8NoBOM
    if ($stderr.Trim()) { Set-Content -LiteralPath (Join-Path $Job.Dir "agy-stderr-$label.txt") -Value $stderr -Encoding utf8NoBOM }
    $j = $null
    if ($stdout.Trim()) { try { $j = $stdout | ConvertFrom-Json -AsHashtable -Depth 50 } catch { $j = $null } }
    $denied = [string[]]@()
    if ($j -and $j['denied_actions']) { $denied = [string[]]@(@($j['denied_actions']) | ForEach-Object { [string]$_['action'] } | Sort-Object -Unique) }
    $answer = $null
    if ($j) {
        if ($null -ne $j['structured_output']) { $answer = $j['structured_output'] }
        elseif ("$($j['response'])".Trim()) { $answer = "$($j['response'])".Trim() }
    }
    $finished = if ($Killed) { 'killed_after_timeout' } elseif ($j) { [string]$j['finished_reason'] } else { 'no_output' }
    $tokens = if ($j -and $j['usage']) { [int]$j['usage']['total_tokens'] } else { 0 }
    $Job.LastTokens = $tokens
    $Job.Tokens = $Job.Tokens + $tokens
    $ok = [bool]((-not $Killed) -and $j -and ($j['status'] -eq 'SUCCESS') -and (-not $finished) -and ($null -ne $answer))
    $blockedByAccount = $stderr -match '(?i)quota|resource_exhausted|rate.?limit|sign in|log ?in|authenticat'
    [pscustomobject]@{
        id              = $Job.Id
        index           = $Job.Index
        ok              = $ok
        status          = $(if ($j) { $j['status'] } else { 'NO_OUTPUT' })
        finished_reason = $finished
        seconds         = $secs
        agy_tokens      = $Job.Tokens
        attempts        = $Job.Attempt
        denied          = $denied
        hint            = $(if ($ok) { $null } else { Get-Hint $denied $stderr $finished })
        conversation_id = $(if ($j) { $j['conversation_id'] } else { $null })
        answer          = $answer
        access          = $Job.Access
        cwd             = $Job.Cwd
        dir             = $Job.Dir
        warnings        = $Job.Warnings
        retryable       = [bool]((-not $ok) -and (-not $Killed) -and ($denied.Count -eq 0) -and ($finished -ne 'print_timeout') -and (-not $blockedByAccount))
    }
}

function Save-Meta($Job, $Result) {
    Write-JsonFile (Join-Path $Job.Dir 'task.json') ([ordered]@{
            id                  = $Job.Id
            conversation_id     = $Result.conversation_id
            conversation_tokens = $Job.LastTokens
            cwd                 = $Job.Cwd
            dir                 = $Job.Dir
            access              = $Job.Access
            base_args           = $Job.BaseArgs
        })
}

function Format-Answer($Answer, [int]$Max) {
    $extra = [System.Collections.Generic.List[string]]::new()
    if ($Answer -is [System.Collections.IDictionary]) {
        $text = [string]$Answer['answer']
        if ($Answer['status'] -and $Answer['status'] -ne 'done') { $extra.Add("status: $($Answer['status'])") }
        if ($Answer['confidence']) { $extra.Add("confidence: $($Answer['confidence'])") }
        $src = @(@($Answer['sources']) | Where-Object { $_ } | Select-Object -First 3)
        if ($src.Count) { $extra.Add('sources: ' + ($src -join ' , ')) }
        if ($Answer['notes']) { $n = ([string]$Answer['notes'] -replace '\s+', ' ').Trim(); $extra.Add('notes: ' + $n.Substring(0, [Math]::Min(250, $n.Length))) }
    } else { $text = [string]$Answer }
    $text = ($text -replace '\s+', ' ').Trim()
    if ($text.Length -gt $Max) { $text = $text.Substring(0, $Max) + ' ...[full answer in results.json]' }
    $out = "    $text"
    if ($extra.Count) { $out += "`n    " + ($extra -join ' | ') }
    $out
}

function Format-Result($R) {
    $tries = if ($R.attempts -gt 1) { ", $($R.attempts) tries" } else { '' }
    $conv = if ($R.conversation_id) { $R.conversation_id } else { '-' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(('[{0}] {1}  ({2}s, {3:N0} agy tokens{4}, conversation {5})' -f $(if ($R.ok) { 'ok' } else { 'FAILED' }), $R.id, $R.seconds, $R.agy_tokens, $tries, $conv))
    if ($R.hint) { $lines.Add("    why: $($R.hint)") }
    if ($null -ne $R.answer) { $lines.Add((Format-Answer $R.answer $AnswerChars)) }
    if ($R.access -ne 'read') { $lines.Add("    folder: $($R.cwd)") }
    foreach ($w in @($R.warnings)) { if ($w) { $lines.Add("    warning: $w") } }
    $lines -join "`n"
}

function Invoke-Run([object[]]$Tasks, $Defaults) {
    $agy = Find-Agy
    try { Invoke-Sync -Quiet } catch { "sync warning: $($_.Exception.Message)" }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + (Get-Random -Minimum 1000 -Maximum 9999)
    $runDir = if ($OutDir) { $OutDir } else { Join-Path $RunsRoot $stamp }
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $used = @{}
    $jobs = for ($i = 0; $i -lt $Tasks.Count; $i++) { New-Job $Tasks[$i] $Defaults $runDir ($i + 1) $used }

    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($jb in @($jobs)) { $queue.Enqueue($jb) }
    $running = [System.Collections.Generic.List[object]]::new()
    $results = [System.Collections.Generic.List[object]]::new()
    $t0 = [datetime]::Now
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $MaxParallel) {
            $jb = $queue.Dequeue()
            $jb.Attempt = $jb.Attempt + 1
            $jb.Handle = Start-Agy $agy (@('-p', $jb.Prompt) + $jb.BaseArgs) $jb.Cwd
            $running.Add($jb)
        }
        Start-Sleep -Milliseconds 250
        foreach ($jb in @($running)) {
            $proc = $jb.Handle.Process
            $killed = $false
            if (-not $proc.HasExited) {
                if (([datetime]::Now - $jb.Handle.Started).TotalSeconds -lt ($jb.Timeout + 45)) { continue }
                try { $proc.Kill($true) } catch { }
                $null = $proc.WaitForExit(10000)
                $killed = $true
            }
            [void]$running.Remove($jb)
            $r = Complete-Job $jb $killed
            if (-not $r.ok -and $r.retryable -and $jb.Attempt -le $Retries) { $queue.Enqueue($jb); continue }
            $results.Add($r)
            Save-Meta $jb $r
        }
    }

    $sorted = @($results | Sort-Object index)
    $okCount = @($sorted | Where-Object { $_.ok }).Count
    $tokSum = ($sorted | Measure-Object -Property agy_tokens -Sum).Sum
    $resultsPath = Join-Path $runDir 'results.json'
    Write-JsonFile $resultsPath @($sorted | Select-Object -Property * -ExcludeProperty index, retryable)
    'agy helpers on {0}: {1} task(s), {2} ok, {3} failed, {4}s, {5:N0} agy tokens' -f $ModelName, $sorted.Count, $okCount, ($sorted.Count - $okCount), [int]([datetime]::Now - $t0).TotalSeconds, $tokSum
    "full results: $resultsPath"
    foreach ($r in $sorted) { ''; Format-Result $r }
    $script:ExitCode = if ($okCount -eq $sorted.Count) { 0 } else { 1 }
}

# ---------------------------------------------------------------- followup

function Invoke-Followup {
    if (-not $Conversation -or -not $Message) { throw 'followup needs -Conversation <id> and -Message "<text>".' }
    $agy = Find-Agy
    try { Invoke-Sync -Quiet } catch { "sync warning: $($_.Exception.Message)" }
    $meta = $null; $metaPath = $null
    if (Test-Path -LiteralPath $RunsRoot) {
        foreach ($f in (Get-ChildItem -LiteralPath $RunsRoot -Recurse -Filter 'task.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
            $m = Read-JsonFile $f.FullName
            if ($m -and $m['conversation_id'] -eq $Conversation) { $meta = $m; $metaPath = $f.FullName; break }
        }
    }
    if ($meta) {
        $base = [string[]]@($meta['base_args']); $cwd = [string]$meta['cwd']; $dir = [string]$meta['dir']
        $prevTokens = [int]$meta['conversation_tokens']; $access = [string]$meta['access']
    } else {
        # A conversation this skill did not start: use the read-only helper with default permissions.
        $dir = Join-Path $RunsRoot 'followups'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $allow = @()
        if (Test-On $Web) { $allow += 'read_url(*)' }
        if (Test-On $Mcp) { $allow += 'mcp(*)' }
        $settingsPath = Join-Path $dir 'agy-settings.json'
        Write-JsonFile $settingsPath @{ permissions = @{ allow = @($allow) } }
        $base = [string[]]@('--agent', 'claude-helper', '--model', $Model, '--output-format', 'json', '--print-timeout', "$($TimeoutSec)s", '--settings', $settingsPath, '--json-schema', $DefaultSchema)
        $cwd = (Get-Location).Path; $prevTokens = 0; $access = 'read'
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $msg = "[Follow-up from Claude Code. Today is $((Get-Date).ToString('yyyy-MM-dd')).]`n$Message"
    $job = [pscustomobject]@{
        Id = 'followup'; Index = 0; Dir = $dir; Cwd = $cwd; Access = $access; Timeout = $TimeoutSec
        Prompt = $msg; BaseArgs = $base; Warnings = [string[]]@(); Attempt = 1; Label = 'followup-' + (Get-Date).ToString('HHmmss')
        Handle = $null; Tokens = 0; LastTokens = 0
    }
    $job.Handle = Start-Agy $agy (@('--conversation', $Conversation, '-p', $msg) + $base) $cwd
    $killed = -not $job.Handle.Process.WaitForExit(($TimeoutSec + 45) * 1000)
    if ($killed) { try { $job.Handle.Process.Kill($true) } catch { }; $null = $job.Handle.Process.WaitForExit(10000) }
    $r = Complete-Job $job $killed
    # agy reports usage for the whole conversation when resuming; show only this turn.
    $r.agy_tokens = [Math]::Max(0, $job.LastTokens - $prevTokens)
    if ($meta -and $r.ok) { $meta['conversation_tokens'] = $job.LastTokens; Write-JsonFile $metaPath $meta }
    Format-Result $r
    $script:ExitCode = if ($r.ok) { 0 } else { 1 }
}

# ---------------------------------------------------------------- doctor / clean

function Invoke-Doctor {
    $agy = Find-Agy
    "agy: $agy"
    'version: ' + (Invoke-AgyQuick $agy @('--version') 30)
    $models = Invoke-AgyQuick $agy @('models') 60
    'model: ' + $(if ($models -match [regex]::Escape($Model)) { "$ModelName available" } else { "$ModelName NOT available (check 'agy models' and that agy is signed in)" })
    Invoke-Sync
    foreach ($a in $HelperAgents) { 'helper agent {0}: {1}' -f $a, $(if (Test-Path -LiteralPath (Join-Path $AgyConfig "agents/$a.md")) { 'installed' } else { 'MISSING' }) }
    'agy MCP servers:'
    (Invoke-AgyQuick $agy @('mcp', 'list') 30) -split "`n" | ForEach-Object { '  ' + $_.TrimEnd() }
    if ($Smoke) {
        ''
        'smoke test:'
        Invoke-Run @(@{ id = 'smoke'; prompt = 'Reply with exactly: OK'; web = 'off'; mcp = 'off'; schema = 'none'; timeoutSec = 90 }) @{}
    }
}

function Invoke-Clean {
    if (-not (Test-Path -LiteralPath $RunsRoot)) { 'clean: no run folders yet'; return }
    $cut = (Get-Date).AddDays(-$OlderThanDays)
    $old = @(Get-ChildItem -LiteralPath $RunsRoot -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}' -and $_.LastWriteTime -lt $cut })
    foreach ($d in $old) { Remove-Item -LiteralPath $d.FullName -Recurse -Force }
    "clean: removed $($old.Count) run folder(s) older than $OlderThanDays day(s) from $RunsRoot"
}

# ---------------------------------------------------------------- main

# Dot-sourcing (". ./agy.ps1") only loads the functions; the unit tests rely on this.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        switch ($Command) {
            'sync' { Invoke-Sync }
            'doctor' { Invoke-Doctor }
            'clean' { Invoke-Clean }
            'followup' { Invoke-Followup }
            default { $spec = Get-TaskSpec; Invoke-Run $spec.Tasks $spec.Defaults }
        }
    } catch {
        "agy helper error: $($_.Exception.Message)"
        $script:ExitCode = 2
    }
    exit $script:ExitCode
}
