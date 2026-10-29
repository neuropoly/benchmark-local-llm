<#
.SYNOPSIS
  Launch Claude Code on the lab model served by tassan (through tassan-tunnel.ps1).

.DESCRIPTION
  Same idea as ..\..\claude-local.ps1: the variables only live for this Claude Code session,
  plain `claude` stays on the normal Anthropic backend. vLLM and Ollama both speak the Anthropic API.

.EXAMPLE
  .\claude-tassan.ps1                       # vLLM (key in ~\.tassan_vllm_key or $env:TASSAN_VLLM_KEY)
  .\claude-tassan.ps1 -Backend ollama
  .\claude-tassan.ps1 -- -p "explain this repo"   # put -- before any dash option meant for claude
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet('vllm', 'ollama')]
    [string]$Backend = 'vllm',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ClaudeArgs
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'tassan_lib.ps1')

$vars = [ordered]@{
    ANTHROPIC_BASE_URL                       = $base
    ANTHROPIC_AUTH_TOKEN                     = $token
    ANTHROPIC_API_KEY                        = ''   # empty = unset in PowerShell
    ANTHROPIC_MODEL                          = $model
    ANTHROPIC_DEFAULT_OPUS_MODEL             = $model
    ANTHROPIC_DEFAULT_SONNET_MODEL           = $model
    ANTHROPIC_DEFAULT_HAIKU_MODEL            = $model  # background/small-model calls
    CLAUDE_CODE_SUBAGENT_MODEL               = $model
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
    CLAUDE_CODE_ATTRIBUTION_HEADER           = '0'     # keeps vLLM prefix caching effective
    CLAUDE_CODE_AUTO_MODE_SERVER             = '0'     # auto mode's server-side checks can't run on the lab server
    # the server's window (MAX_MODEL_LEN): else Claude Code reserves 32k output and never compacts
    CLAUDE_CODE_MAX_CONTEXT_TOKENS           = "$window"
    CLAUDE_CODE_AUTO_COMPACT_WINDOW          = "$window"
    CLAUDE_CODE_MAX_OUTPUT_TOKENS            = '16384'
}

# Claude Code's WebSearch runs on Anthropic's servers and only errors with the lab model: turn it off and
# use the lab-search MCP server on tassan (web_search, fetch) through the tunnel, when it answers.
# These options take several values, so they go after the user's arguments.
$extra = @('--disallowedTools', 'WebSearch')
$mcpCode = $null
try { Invoke-WebRequest -Method Post 'http://127.0.0.1:8002/mcp' -TimeoutSec 5 -UseBasicParsing | Out-Null; $mcpCode = 200 }
catch { if ($_.Exception.Response) { $mcpCode = [int]$_.Exception.Response.StatusCode } }
if ($mcpCode -eq 401) {   # up, and asking for the lab key
    $dir = Join-Path $HOME '.tassan'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $mcpFile = Join-Path $dir 'mcp.json'
    $json = @{ mcpServers = @{ 'lab-search' = @{ type = 'http'; url = 'http://127.0.0.1:8002/mcp'; headers = @{ Authorization = "Bearer $token" } } } } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($mcpFile, $json, (New-Object Text.UTF8Encoding $false))   # no BOM
    $extra += @('--mcp-config', $mcpFile)
} else {
    Write-Host 'Note: no web search this session (nothing answers on 127.0.0.1:8002: tunnel without it, or search off on tassan).' -ForegroundColor Yellow
}

$saved = @{}
foreach ($name in $vars.Keys) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $(if ($vars[$name]) { $vars[$name] } else { $null }), 'Process')
}

Write-Host "Claude Code -> tassan $Backend ($model) at $base" -ForegroundColor Cyan
try {
    # claude prints a benign stderr warning with a custom auth token; with 'Stop' it would be fatal.
    $ErrorActionPreference = 'Continue'
    & claude --model $model @ClaudeArgs @extra
}
finally {
    foreach ($name in $vars.Keys) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
    }
    Write-Host 'Environment restored: plain `claude` uses the normal Anthropic backend again.' -ForegroundColor Cyan
}
