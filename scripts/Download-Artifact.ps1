#Requires -Version 7.6
# This stable entry point lets the private action use the selected release's
# exact module implementation instead of resolving scripts from a caller checkout.
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ApiUrl,
    [Parameter(Mandatory)] [string] $Repository,
    [Parameter(Mandatory)] [long] $RunId,
    [Parameter(Mandatory)] [string] $Path,
    [string] $ArtifactIds,
    [string] $Name,
    [string] $Pattern,
    [switch] $MergeMultiple,
    [string] $GitHubToken = $env:GH_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Import-Module (Join-Path $PSScriptRoot 'ArtifactDownload.psm1') -Force

$parameters = @{
    ApiUrl = $ApiUrl
    Repository = $Repository
    RunId = $RunId
    Path = $Path
    GitHubToken = $GitHubToken
    ArtifactIds = $ArtifactIds
    Name = $Name
    Pattern = $Pattern
}
if ($MergeMultiple) { $parameters.MergeMultiple = $true }
Invoke-ArtifactDownload @parameters
