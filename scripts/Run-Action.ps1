#Requires -Version 7.6
# The root composite action calls these stages around actions/cache. This script
# owns bootstrap/file/process wiring only; the Rust companion owns action behavior.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('prepare', 'install', 'invoke')][string] $Stage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Tools.psm1')
$manifest = Read-ActionManifest -Path (
    Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'release.json')

function Add-ActionOutput {
    param([string] $Name, [string] $Value)
    if ($Value.Contains("`n") -or $Value.Contains("`r")) {
        throw "Bootstrap output $Name must be a single line."
    }
    "$Name=$Value" | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8
}

if ($Stage -eq 'prepare') {
    $disableCache = $env:CBH_ACTION_DISABLE_CACHE
    if (![string]::IsNullOrEmpty($disableCache) -and $disableCache -cnotin @('true', 'false')) {
        throw 'CBH_ACTION_DISABLE_CACHE must be true, false or unset.'
    }
    $inputs = $env:CBH_INPUTS_JSON | ConvertFrom-Json -AsHashtable
    if ($inputs -isnot [System.Collections.IDictionary]) {
        throw 'CBH_INPUTS_JSON must be an object containing string inputs.'
    }
    foreach ($key in @($inputs.Keys)) {
        if ($inputs[$key] -isnot [string]) {
            throw "Action input $key must be a string."
        }
    }
    # Empty runtime values still carry names that Rust must validate before it
    # applies command-specific defaults. Only bootstrap-owned keys are removed.
    $method = if ($inputs.ContainsKey('install-method') -and $inputs['install-method'] -cne '') {
        $inputs['install-method']
    } else { 'binstall' }
    if ($method -cnotin @('binstall', 'install', 'path')) {
        throw "Unknown installation method: $method"
    }
    $sourcePath = if ($inputs.ContainsKey('source-path')) { $inputs['source-path'] } else { '' }
    if (($method -eq 'path' -and [string]::IsNullOrWhiteSpace($sourcePath)) -or
        ($method -ne 'path' -and $sourcePath)) {
        throw 'source-path is required for path installation and is not valid for other methods.'
    }
    $packages = @(Get-RequiredTool -Manifest $manifest -Command $inputs['command'])
    $workingDirectory = if ($inputs.ContainsKey('working-directory') -and $inputs['working-directory'] -cne '') {
        [IO.Path]::GetFullPath($inputs['working-directory'], $PWD.ProviderPath)
    } else { $PWD.ProviderPath }
    if (!(Test-Path -LiteralPath $workingDirectory -PathType Container)) {
        throw "Working directory does not exist: $workingDirectory"
    }
    $inputs['working-directory'] = $workingDirectory
    if ($sourcePath) {
        $sourcePath = [IO.Path]::GetFullPath($sourcePath, $PWD.ProviderPath)
    }
    $inputs.Remove('install-method')
    $inputs.Remove('source-path')
    if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        throw 'RUNNER_TEMP is required for isolated action installation and runtime files.'
    }
    $temp = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
    $checkouts = @($workingDirectory)
    if ($env:GITHUB_WORKSPACE) { $checkouts += $env:GITHUB_WORKSPACE }
    foreach ($checkout in $checkouts) {
        $directory = Get-Item -LiteralPath $temp
        $resolvedCheckout = Get-Item -LiteralPath $checkout
        if ($resolvedCheckout.LinkType) { $resolvedCheckout = $resolvedCheckout.ResolveLinkTarget($true) }
        while ($null -ne $directory) {
            if ($directory.LinkType) { $directory = $directory.ResolveLinkTarget($true) }
            # Conservatively reject case-only overlaps, without assuming the
            # filesystem's case sensitivity from its operating system.
            if ($directory.FullName -ieq $resolvedCheckout.FullName) {
                throw 'RUNNER_TEMP must be outside the caller and measured checkouts.'
            }
            $directory = $directory.Parent
        }
    }
    $runRoot = Join-Path $temp "cbh-action-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $runRoot | Out-Null
    $inputPath = Join-Path $runRoot 'inputs.json'
    $inputs | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $inputPath -Encoding utf8
    $versions = ($manifest.tools | Where-Object { $_.name -cin $packages } |
        Sort-Object name | ForEach-Object { "$($_.name)-$($_.version)" }) -join '_'
    # Real-method canaries need the current root action without either remote
    # cache reuse or an existing local root; see docs/implementation.md.
    $cacheEnabled = $method -ne 'path' -and $disableCache -cne 'true'
    # Bump this prefix when the installation/verification format changes.
    $cacheKey = "cbh-tools-v1-$($env:RUNNER_OS)-$($env:RUNNER_ARCH)-$versions"
    # actions/cache includes the requested paths in its cache version. A random
    # installation path would miss every restored cache despite a stable key.
    $root = if ($cacheEnabled) {
        Join-Path -Path $temp -ChildPath 'cbh-action-tools' -AdditionalChildPath $cacheKey
    } else { Join-Path $runRoot 'tools' }
    $statePath = Join-Path $runRoot 'state.json'
    @{
        method = $method
        sourcePath = $sourcePath
        root = $root
        packages = $packages
        inputPath = $inputPath
        tempDir = $runRoot
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding utf8
    Write-Information "Command $($inputs.command) requires $($packages -join ', '); method $method. Runtime files: $runRoot. Tool root: $root. Neither is inside $workingDirectory." -InformationAction Continue
    if ($disableCache -ceq 'true') {
        Write-Information 'CBH_ACTION_DISABLE_CACHE=true requests a fresh installation root with no tool-cache restore or save.' -InformationAction Continue
    }
    Add-ActionOutput 'state-path' $statePath
    Add-ActionOutput 'install-root' $root
    Add-ActionOutput 'cache-enabled' $cacheEnabled.ToString().ToLowerInvariant()
    Add-ActionOutput 'cache-key' $cacheKey
    return
}

$state = Get-Content -LiteralPath $env:CBH_STATE_PATH -Raw | ConvertFrom-Json -AsHashtable
if ($Stage -eq 'install') {
    $install = @{
        Manifest = $manifest
        Method = $state.method
        Root = $state.root
        Packages = [string[]] $state.packages
    }
    if ($state.method -eq 'path') { $install.SourcePath = $state.sourcePath }
    $state['executables'] = Install-ActionTools @install
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $env:CBH_STATE_PATH -Encoding utf8
    return
}

$companion = ($manifest.tools | Where-Object role -CEQ 'companion').name
$main = ($manifest.tools | Where-Object role -CEQ 'tool').name
$arguments = @('action', '--inputs-file', $state.inputPath,
    '--github-output', $env:GITHUB_OUTPUT, '--temp-dir', $state.tempDir)
if ($state.executables.ContainsKey($main)) {
    $arguments += @('--tool', $state.executables[$main])
}
Write-Information 'Invoking the pinned companion with the input file; it owns validation, execution and step outputs.' -InformationAction Continue
$PSNativeCommandUseErrorActionPreference = $false
$global:LASTEXITCODE = 0
& $state.executables[$companion] @arguments | Out-Host
if ($global:LASTEXITCODE -ne 0) {
    throw "The benchmark-history action failed with exit code $global:LASTEXITCODE."
}
