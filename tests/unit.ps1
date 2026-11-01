#Requires -Version 7.0
<#
.SYNOPSIS
    Offline unit tests for skills/agy/scripts/agy.ps1. They never call agy, so they run anywhere (CI included).

.EXAMPLE
    pwsh ./tests/unit.ps1
#>
$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0

function Check([string]$Name, [scriptblock]$Test) {
    try {
        if (& $Test) { $script:Passed++; "  PASS  $Name" } else { $script:Failed++; "  FAIL  $Name" }
    } catch {
        $script:Failed++; "  FAIL  $Name  ($($_.Exception.Message))"
    }
}

function New-FakeJob([string]$Json, [string]$StdErr = '') {
    $dir = Join-Path $temp ('job-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $out = [System.Threading.Tasks.TaskCompletionSource[string]]::new(); $out.SetResult($Json)
    $err = [System.Threading.Tasks.TaskCompletionSource[string]]::new(); $err.SetResult($StdErr)
    [pscustomobject]@{
        Id = 'fake'; Index = 1; Dir = $dir; Cwd = $dir; Access = 'read'; Timeout = 60; Prompt = ''; BaseArgs = @(); Warnings = @()
        Attempt = 1; Label = ''; Tokens = 0; LastTokens = 0
        Handle = [pscustomobject]@{ Out = $out.Task; Err = $err.Task; Started = [datetime]::Now; Process = $null }
    }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('agy-unit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $temp | Out-Null

# Load the functions only (the script skips its main block when dot-sourced).
. (Join-Path $PSScriptRoot '../skills/agy/scripts/agy.ps1')

'Input helpers'
Check 'Split-List splits on semicolons and trims' { ((Split-List ' a ; b;;c ') -join '|') -eq 'a|b|c' }
Check 'Split-List keeps array items' { ((Split-List @('x', ' y ')) -join '|') -eq 'x|y' }
Check 'Split-List handles null' { (Split-List $null).Count -eq 0 }
Check 'Test-On reads on/off values' { (Test-On 'on') -and (Test-On $true) -and (Test-On $null) -and -not (Test-On 'off') -and -not (Test-On $false) -and -not (Test-On 'no') }

'MCP conversion'
$env:AGY_UNIT_TEST_VAR = 'hello'
Check 'Expand-Vars fills ${VAR}' { (Expand-Vars 'x-${AGY_UNIT_TEST_VAR}-y') -eq 'x-hello-y' }
Check 'Expand-Vars uses ${VAR:-default}' { (Expand-Vars '${AGY_UNIT_MISSING:-fallback}') -eq 'fallback' }
Check 'Expand-Vars leaves unknown ${VAR} alone' { (Expand-Vars '${AGY_UNIT_MISSING}') -eq '${AGY_UNIT_MISSING}' }
Check 'Convert-Server converts stdio servers' {
    $c = Convert-Server @{ type = 'stdio'; command = 'node'; args = @('server.js', '${AGY_UNIT_TEST_VAR}'); env = @{ TOKEN = '${AGY_UNIT_TEST_VAR}' } }
    $c['command'] -eq 'node' -and $c['args'][1] -eq 'hello' -and $c['env']['TOKEN'] -eq 'hello'
}
Check 'Convert-Server wraps npx in cmd /c on Windows only' {
    $c = Convert-Server @{ command = 'npx'; args = @('-y', 'pkg') }
    if ($IsWindows) { $c['command'] -eq 'cmd' -and ($c['args'] -join ' ') -eq '/c npx -y pkg' } else { $c['command'] -eq 'npx' }
}
Check 'Convert-Server converts http servers with headers' {
    $c = Convert-Server @{ type = 'http'; url = 'https://example.com/mcp'; headers = @{ Authorization = 'Bearer ${AGY_UNIT_TEST_VAR}' } }
    $c['url'] -eq 'https://example.com/mcp' -and $c['headers']['Authorization'] -eq 'Bearer hello'
}
Check 'Convert-Server skips legacy SSE servers' { $null -eq (Convert-Server @{ type = 'sse'; url = 'https://example.com/sse' }) }

'MCP merge'
Check 'Merge-McpServers adds servers and keeps agy-only ones' {
    $cfg = [ordered]@{ mcpServers = [ordered]@{ mine = [ordered]@{ command = 'x' } } }
    $m = Merge-McpServers $cfg ([ordered]@{ a = @{ command = 'node' } }) @()
    $m.Config['mcpServers'].Contains('mine') -and $m.Config['mcpServers'].Contains('a') -and ($m.Synced -join ',') -eq 'a'
}
Check 'Merge-McpServers removes servers that left Claude Code' {
    $cfg = [ordered]@{ mcpServers = [ordered]@{ old = [ordered]@{ command = 'x' }; mine = [ordered]@{ command = 'y' } } }
    $m = Merge-McpServers $cfg ([ordered]@{}) @('old')
    -not $m.Config['mcpServers'].Contains('old') -and $m.Config['mcpServers'].Contains('mine') -and $m.Changes.Count -eq 1
}
Check 'Merge-McpServers never overwrites an entry it did not create' {
    $cfg = [ordered]@{ mcpServers = [ordered]@{ same = [ordered]@{ command = 'agy-own' } } }
    $m = Merge-McpServers $cfg ([ordered]@{ same = @{ command = 'claude' } }) @()
    $m.Config['mcpServers']['same']['command'] -eq 'agy-own' -and $m.Synced.Count -eq 0
}
Check 'Merge-McpServers starts from an empty config' {
    $m = Merge-McpServers $null ([ordered]@{ a = @{ url = 'https://example.com/mcp' } }) @()
    $m.Config['mcpServers']['a']['url'] -eq 'https://example.com/mcp'
}

'Reading Claude Code MCP settings'
$proj = Join-Path $temp 'project'
New-Item -ItemType Directory -Force -Path (Join-Path $proj '.claude') | Out-Null
'{"mcpServers":{"approved":{"command":"node"},"other":{"command":"node"}}}' | Set-Content -LiteralPath (Join-Path $proj '.mcp.json')
$fakeClaude = Join-Path $temp 'claude.json'
$projKey = $proj -replace '\\', '/'
ConvertTo-Json -Depth 10 -InputObject @{
    mcpServers = @{ userwide = @{ command = 'u' } }
    projects   = @{ $projKey = @{ enabledMcpjsonServers = @('approved'); mcpServers = @{ local = @{ command = 'l' } } } }
} | Set-Content -LiteralPath $fakeClaude
$noSettings = Join-Path $temp 'no-settings.json'
Check 'Get-ClaudeMcpServers reads user, project and approved .mcp.json servers' {
    $s = Get-ClaudeMcpServers -Project $proj -ClaudeJson $fakeClaude -UserSettings $noSettings
    ((@($s.Keys) | Sort-Object) -join ',') -eq 'approved,local,userwide'
}
Check 'Get-ClaudeMcpServers honours enableAllProjectMcpServers' {
    '{"enableAllProjectMcpServers": true}' | Set-Content -LiteralPath (Join-Path $proj '.claude/settings.local.json')
    $s = Get-ClaudeMcpServers -Project $proj -ClaudeJson $fakeClaude -UserSettings $noSettings
    $s.Contains('other')
}
Check 'Get-ClaudeMcpServers honours disabledMcpjsonServers' {
    '{"enableAllProjectMcpServers": true, "disabledMcpjsonServers": ["other"]}' | Set-Content -LiteralPath (Join-Path $proj '.claude/settings.local.json')
    $s = Get-ClaudeMcpServers -Project $proj -ClaudeJson $fakeClaude -UserSettings $noSettings
    -not $s.Contains('other') -and $s.Contains('approved')
}

'Preparing helper jobs'
$runDir = Join-Path $temp 'run'
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
function Get-Allow($Job) { @((Get-Content -LiteralPath (Join-Path $Job.Dir 'agy-settings.json') -Raw | ConvertFrom-Json).permissions.allow) }
Check 'read task: read-only agent, web and MCP rules, default schema' {
    $j = New-Job @{ id = 'r1'; prompt = 'hello' } @{} $runDir 1 @{}
    $allow = Get-Allow $j
    (($j.BaseArgs -join ' ') -match '--agent claude-helper ') -and ($allow -contains 'read_url(*)') -and ($allow -contains 'mcp(*)') -and ($j.BaseArgs -contains '--json-schema') -and ($j.BaseArgs -contains $Model)
}
Check 'allowCommands: command agent with exact rules, web off' {
    $j = New-Job @{ id = 'c1'; prompt = 'run'; allowCommands = @('npm test'); web = 'off' } @{} $runDir 2 @{}
    $allow = Get-Allow $j
    ($j.BaseArgs -contains 'claude-helper-cmd') -and ($allow -contains 'command(npm test)') -and -not ($allow -contains 'read_url(*)')
}
Check 'edit task: edit agent with accept-edits' {
    $j = New-Job @{ id = 'e1'; prompt = 'edit'; access = 'edit' } @{} $runDir 3 @{}
    ($j.BaseArgs -contains 'claude-helper-edit') -and ($j.BaseArgs -contains 'accept-edits')
}
Check 'schema none: plain text answer' {
    $j = New-Job @{ id = 'n1'; prompt = 'x'; schema = 'none' } @{} $runDir 4 @{}
    -not ($j.BaseArgs -contains '--json-schema')
}
Check 'defaults merge with the task, files are copied, folders added' {
    $f = Join-Path $temp 'ctx.txt'; 'context' | Set-Content -LiteralPath $f
    $j = New-Job @{ id = 'd1'; prompt = 'x'; files = @($f) } @{ addDirs = @($temp) } $runDir 5 @{}
    (Test-Path -LiteralPath (Join-Path $j.Dir 'context/ctx.txt')) -and (($j.BaseArgs -join ' ') -match [regex]::Escape((Split-Path -Leaf $temp))) -and ($j.Prompt -match 'Context files')
}
Check 'very long prompts move into task.md' {
    $j = New-Job @{ id = 'l1'; prompt = ('x' * 13000) } @{} $runDir 6 @{}
    (Test-Path -LiteralPath (Join-Path $j.Dir 'task.md')) -and $j.Prompt.Length -lt 3000
}
Check 'duplicate ids get a suffix' {
    $used = @{}
    $a = New-Job @{ id = 'dup'; prompt = 'x' } @{} $runDir 7 $used
    $b = New-Job @{ id = 'dup'; prompt = 'x' } @{} $runDir 8 $used
    $a.Id -ne $b.Id
}
Check 'a task without a prompt is rejected' {
    try { New-Job @{ id = 'empty'; prompt = ' ' } @{} $runDir 9 @{} | Out-Null; $false } catch { $_.Exception.Message -match 'no prompt' }
}

'Reading agy results'
Check 'structured output is read' {
    $r = Complete-Job (New-FakeJob '{"conversation_id":"c1","status":"SUCCESS","response":"x","structured_output":{"status":"done","answer":"42","confidence":"high"},"usage":{"total_tokens":1234}}') $false
    $r.ok -and $r.answer['answer'] -eq '42' -and $r.agy_tokens -eq 1234 -and $r.conversation_id -eq 'c1'
}
Check 'refused actions fail with a hint and are not retried' {
    $r = Complete-Job (New-FakeJob '{"status":"SUCCESS","response":"","denied_actions":[{"action":"command"}],"usage":{"total_tokens":10}}' 'no output produced') $false
    -not $r.ok -and -not $r.retryable -and $r.hint -match 'allowCommands'
}
Check 'an empty answer is retried' {
    $r = Complete-Job (New-FakeJob '{"status":"SUCCESS","response":"","usage":{"total_tokens":10}}') $false
    -not $r.ok -and $r.retryable
}
Check 'a timed-out run is not retried' {
    $r = Complete-Job (New-FakeJob '{"status":"SUCCESS","response":"partial","finished_reason":"print_timeout","usage":{"total_tokens":10}}') $false
    -not $r.ok -and -not $r.retryable -and $r.hint -match 'timeoutSec'
}
Check 'quota errors are explained and not retried' {
    $r = Complete-Job (New-FakeJob '' 'RESOURCE_EXHAUSTED: quota') $false
    -not $r.ok -and -not $r.retryable -and $r.hint -match 'quota'
}
Check 'Format-Answer shows status, confidence, sources and truncates' {
    $t = Format-Answer @{ status = 'partial'; answer = ('word ' * 200); confidence = 'low'; sources = @('https://a.example', 'https://b.example') } 100
    $t -match 'status: partial' -and $t -match 'confidence: low' -and $t -match 'https://a\.example' -and $t -match 'full answer in results\.json'
}

Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:AGY_UNIT_TEST_VAR -ErrorAction SilentlyContinue
''
"$script:Passed passed, $script:Failed failed"
exit ([int]($script:Failed -gt 0))
