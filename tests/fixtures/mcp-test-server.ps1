#Requires -Version 7.0
# Minimal MCP server (stdio, newline-delimited JSON-RPC) used by tests/live.ps1.
# It has one tool, get_secret_word, which always returns "pineapple-42".

$ErrorActionPreference = 'Stop'
try { [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

while ($null -ne ($line = [Console]::In.ReadLine())) {
    if (-not $line.Trim()) { continue }
    try { $msg = $line | ConvertFrom-Json -AsHashtable } catch { continue }
    if (-not $msg.Contains('id')) { continue }   # notifications get no reply
    $result = switch ($msg['method']) {
        'initialize' {
            $version = if ($msg['params'] -and $msg['params']['protocolVersion']) { $msg['params']['protocolVersion'] } else { '2025-03-26' }
            @{ protocolVersion = $version; capabilities = @{ tools = @{} }; serverInfo = @{ name = 'agy-helpers-test'; version = '1.0.0' } }
        }
        'tools/list' { @{ tools = @(@{ name = 'get_secret_word'; description = 'Returns the secret test word.'; inputSchema = @{ type = 'object'; properties = @{} } }) } }
        'tools/call' { @{ content = @(@{ type = 'text'; text = 'pineapple-42' }) } }
        default { @{} }
    }
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject @{ jsonrpc = '2.0'; id = $msg['id']; result = $result } -Depth 10 -Compress))
    [Console]::Out.Flush()
}
