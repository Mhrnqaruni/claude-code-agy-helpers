#Requires -Version 7.0
<#
.SYNOPSIS
    Installs, updates or removes the agy helpers skill for Claude Code.

.EXAMPLE
    pwsh ./install.ps1
    Installs the skill for your user (all projects), then runs a health check and a tiny test task.

.EXAMPLE
    pwsh ./install.ps1 -Project C:/code/my-app
    Installs the skill into one project's .claude/skills folder, for example to commit it with the project.

.EXAMPLE
    pwsh ./install.ps1 -Uninstall
    Removes the skill, the helper agents it added to agy, and the MCP servers it copied into agy.
#>
[CmdletBinding()]
param(
    [string]$Project,
    [switch]$Uninstall,
    [switch]$SkipCheck
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'skills/agy'
$claudeDir = if ($Project) { Join-Path (Resolve-Path -LiteralPath $Project).Path '.claude' } else { Join-Path $HOME '.claude' }
$target = Join-Path $claudeDir 'skills/agy'
$agyConfig = Join-Path $HOME '.gemini/config'

if ($Uninstall) {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force; "Removed the skill from $target" }
    else { "No skill found at $target" }
    foreach ($agent in 'claude-helper', 'claude-helper-cmd', 'claude-helper-edit') {
        $file = Join-Path $agyConfig "agents/$agent.md"
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force; "Removed agy helper agent $agent" }
    }
    $stateFile = Join-Path $agyConfig 'claude-sync-state.json'
    $mcpFile = Join-Path $agyConfig 'mcp_config.json'
    if (Test-Path -LiteralPath $stateFile) {
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json -AsHashtable
        if ($state['mcpServers'] -and (Test-Path -LiteralPath $mcpFile)) {
            $cfg = Get-Content -LiteralPath $mcpFile -Raw | ConvertFrom-Json -AsHashtable
            foreach ($name in @($state['mcpServers'])) {
                if ($cfg['mcpServers'] -and $cfg['mcpServers'].Contains($name)) { $cfg['mcpServers'].Remove($name); "Removed MCP server $name from agy" }
            }
            ConvertTo-Json -InputObject $cfg -Depth 50 | Set-Content -LiteralPath $mcpFile -Encoding utf8NoBOM
        }
        Remove-Item -LiteralPath $stateFile -Force
    }
    'Claude Code plugins imported into agy stay installed. Remove one with: agy plugin uninstall <name>'
    return
}

if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md'))) { throw "Can't find the skill files next to this script: $source" }
$verb = if (Test-Path -LiteralPath $target) { 'Updated' } else { 'Installed' }
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
"$verb the agy skill in $target"
if ($SkipCheck) { return }

''
'Checking agy and running a tiny test task (about 10 seconds)...'
''
$pwsh = (Get-Process -Id $PID).Path
& $pwsh -NoProfile -File (Join-Path $target 'scripts/agy.ps1') doctor -Smoke
if ($LASTEXITCODE -ne 0) {
    ''
    'The check did not pass. Fix the problem shown above (usually: install agy and run it once in a terminal to sign in), then run this installer again.'
    exit 1
}
''
'All set. Open Claude Code and try:'
'  Use agy helpers to find the latest stable versions of React and Vue, with release dates and official sources.'
