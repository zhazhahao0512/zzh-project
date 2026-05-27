[CmdletBinding()]
param(
    [int]$Port = 8792,
    [string]$HostName = "0.0.0.0"
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot

Set-Location $repoRoot
node web\server.js --port $Port --host $HostName
