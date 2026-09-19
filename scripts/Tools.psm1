#Requires -Version 7.6
# Shared by the root action and installation gates. PowerShell must bootstrap the
# Rust binaries before their runtime can execute; see docs/implementation.md.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Cargo and binstall record crates.io with this canonical identity, including
# installations that use the sparse registry transport.
$script:PublishedRegistry = 'registry+https://github.com/rust-lang/crates.io-index'

function Read-ActionManifest {
    <#.SYNOPSIS
    Reads and validates the action's release manifest.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string] $Path)

    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest.schema_version -ne 1 -or $manifest.version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Unsupported action release manifest: $Path"
    }
    if (@($manifest.tools).Count -eq 0 -or @($manifest.targets).Count -eq 0) {
        throw 'The release manifest must declare tools and supported targets.'
    }
    $names = @{}
    $binaries = @{}
    foreach ($tool in $manifest.tools) {
        if ($tool.name -cnotmatch '^[a-z0-9][a-z0-9_-]*$' -or
            $tool.binary -cnotmatch '^[a-z0-9][a-z0-9_-]*$' -or
            $tool.version -cnotmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$' -or
            $tool.role -cnotin @('tool', 'companion', 'fixture', 'scope')) {
            throw 'Each tool must have a package, binary, exact version and recognized role.'
        }
        if ($names.ContainsKey($tool.name) -or $binaries.ContainsKey($tool.binary)) {
            throw "Duplicate package or binary in release manifest: $($tool.name)"
        }
        $names[$tool.name] = $true
        $binaries[$tool.binary] = $true
    }
    foreach ($role in @('tool', 'companion')) {
        if (@($manifest.tools | Where-Object role -CEQ $role).Count -ne 1) {
            throw "The release manifest must declare exactly one $role."
        }
    }
    return $manifest
}

function Get-RequiredTool {
    <#.SYNOPSIS
    Returns consumer package names for one supported action command.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)][string] $Command
    )

    $usesMain = $Command -cin @('collect', 'backfill', 'analyze-history', 'analyze-pr')
    if (!$usesMain -and $Command -cne 'alert' -and
        $Command -cnotmatch '^publish-(comment|issue)-(findings|clean|preflight|no-data|failed)$') {
        throw "Unknown action command: $Command"
    }
    foreach ($tool in $Manifest.tools) {
        if ($tool.role -ceq 'companion' -or ($usesMain -and $tool.role -ceq 'tool')) {
            $tool.name
        }
    }
}

function Get-ManifestTool {
    param($Manifest, [string] $Package)
    $tools = @($Manifest.tools | Where-Object name -CEQ $Package)
    if ($tools.Count -ne 1) {
        throw "Package is not uniquely declared in release.json: $Package"
    }
    return $tools[0]
}

function Get-ActionToolPath {
    <#.SYNOPSIS
    Resolves a manifest package's executable under the explicit installation root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Package
    )

    $tool = Get-ManifestTool $Manifest $Package
    $binary = if ($IsWindows) { "$($tool.binary).exe" } else { $tool.binary }
    return [IO.Path]::GetFullPath(
        (Join-Path -Path $Root -ChildPath 'bin' -AdditionalChildPath $binary), $PWD.ProviderPath)
}

function Invoke-ToolProcess {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $CaptureOutput
    )
    # Explicit exit handling also applies when the caller enables this preference.
    $PSNativeCommandUseErrorActionPreference = $false
    $global:LASTEXITCODE = 0
    if ($CaptureOutput) {
        $output = & $FilePath @Arguments
    } else {
        & $FilePath @Arguments | Out-Host
    }
    if ($global:LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $global:LASTEXITCODE."
    }
    if ($CaptureOutput) {
        return ($output -join "`n").Trim()
    }
}

function Get-ToolReceipt {
    param([string] $Root, $Tool)

    $path = Join-Path $Root '.crates.toml'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    # Both Cargo and binstall write this v1 table. Binstall does not write
    # .crates2.json, so requiring that file would reject valid prebuilt installs.
    # Read only Cargo's generated string-key/string-array format, not human output.
    $text = Get-Content -LiteralPath $path -Raw
    $table = [regex]::Match($text, '(?ms)^\[v1\]\s*(?<entries>.*?)(?=^\[|\z)')
    if (!$table.Success) {
        throw "Missing Cargo v1 installation table: $path"
    }
    $entryPattern = '(?m)^"(?<id>[^"\r\n]+)"\s*=\s*(?<bins>\[[^\]]*\])\s*$'
    $entries = [regex]::Matches($table.Groups['entries'].Value, $entryPattern)
    if ([regex]::Replace($table.Groups['entries'].Value, $entryPattern, '').Trim()) {
        throw "Unsupported or corrupt Cargo installation receipt: $path"
    }
    $selected = @($entries | Where-Object {
        $_.Groups['id'].Value.StartsWith("$($Tool.name) ", [StringComparison]::Ordinal)
    })
    if ($selected.Count -eq 0) {
        return $null
    }
    if ($selected.Count -ne 1) {
        throw "Ambiguous Cargo installation receipts for $($Tool.name) in $Root."
    }
    $entry = $selected[0]
    $identity = [regex]::Match($entry.Groups['id'].Value, '^\S+ (?<version>\S+) \((?<source>.+)\)$')
    if (!$identity.Success) {
        throw "Malformed Cargo installation identity for $($Tool.name)."
    }
    $bins = @($entry.Groups['bins'].Value | ConvertFrom-Json)
    $expectedBinary = [IO.Path]::GetFileName((Get-ActionToolPath -Manifest @{
        tools = @($Tool)
    } -Root $Root -Package $Tool.name))
    # Binstall records unsuffixed binary names on some Windows versions.
    if ($bins -cnotcontains $expectedBinary -and $bins -cnotcontains $Tool.binary) {
        return $null
    }
    $jsonPath = Join-Path $Root '.crates2.json'
    if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
        $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -AsHashtable
        $jsonEntries = @($json.installs.Keys | Where-Object {
            $_.StartsWith("$($Tool.name) ", [StringComparison]::Ordinal)
        })
        # Binstall can coexist with Cargo records for other packages. If Cargo
        # recorded this package as well, both receipts must agree.
        if ($jsonEntries.Count -gt 0 -and
            ($jsonEntries.Count -ne 1 -or $jsonEntries[0] -cne $entry.Groups['id'].Value -or
                (($json.installs[$jsonEntries[0]].bins -cnotcontains $expectedBinary) -and
                 ($json.installs[$jsonEntries[0]].bins -cnotcontains $Tool.binary)))) {
            throw "Conflicting Cargo installation receipts for $($Tool.name) in $Root."
        }
    }
    return @{
        version = $identity.Groups['version'].Value
        source = $identity.Groups['source'].Value
    }
}

function Test-ActionToolInstallation {
    <#.SYNOPSIS
    Checks exact crates.io Cargo installation receipts and executable presence.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Package
    )

    $tool = Get-ManifestTool $Manifest $Package
    $exe = Get-ActionToolPath -Manifest $Manifest -Root $Root -Package $Package
    if (!(Test-Path -LiteralPath $exe -PathType Leaf)) {
        Write-Information "Cannot reuse $Package`: executable is absent at $exe." -InformationAction Continue
        return $false
    }
    $receipt = Get-ToolReceipt -Root $Root -Tool $tool
    if (!$receipt) {
        Write-Information "Cannot reuse $Package`: Cargo has no matching package/binary receipt." -InformationAction Continue
        return $false
    }
    if ($receipt.version -cne $tool.version -or $receipt.source -cne $script:PublishedRegistry) {
        Write-Information "Cannot reuse $Package`: expected crates.io version $($tool.version), found $($receipt.version) from $($receipt.source)." -InformationAction Continue
        return $false
    }
    return $true
}

function Confirm-ToolRuntime {
    param($Tool, [string] $Executable, [string] $Version)

    if ($Tool.role -ceq 'companion') {
        $actual = Invoke-ToolProcess -FilePath $Executable -Arguments @('--version') -CaptureOutput
        if ($actual -cne "$($Tool.binary) $Version") {
            throw "Executable version mismatch: expected $($Tool.binary) $Version; got '$actual'."
        }
        Write-Information "Verified executable version: $actual. Checking the action command contract." -InformationAction Continue
        Invoke-ToolProcess -FilePath $Executable -Arguments @('action', '--help')
    } elseif ($Tool.role -ceq 'tool') {
        Write-Information "$($Tool.name) has no --version; Cargo records version $Version. Checking runtime commands, not claiming executable-reported identity." -InformationAction Continue
        foreach ($command in @('collect', 'backfill', 'analyze', 'machine-key')) {
            Invoke-ToolProcess -FilePath $Executable -Arguments @($command, '--help')
        }
    } else {
        Write-Information "$($Tool.name) identity comes from Cargo installation records; its behavioral canary is owned by CI." -InformationAction Continue
    }
}

function Install-ActionTools {
    <#.SYNOPSIS
    Installs selected packages and returns a package-name-to-executable map.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Install-ActionTools is the shared action/CI API for a set of packages.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)][ValidateSet('binstall', 'install', 'path')][string] $Method,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]] $Packages,
        [string] $SourcePath,
        [switch] $RequirePrebuilt
    )

    if ($RequirePrebuilt -and $Method -ne 'binstall') {
        throw 'RequirePrebuilt requires the binstall installation method.'
    }
    if ($Method -eq 'path' -and [string]::IsNullOrWhiteSpace($SourcePath)) {
        throw 'Path installation requires source-path pointing to the Folo source checkout.'
    }
    if ($Method -ne 'path' -and ![string]::IsNullOrEmpty($SourcePath)) {
        throw 'source-path applies only to install-method: path.'
    }
    $Root = [IO.Path]::GetFullPath($Root, $PWD.ProviderPath)
    $tools = @($Packages | Select-Object -Unique | ForEach-Object {
        Get-ManifestTool $Manifest $_
    })
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $result = @{}
    foreach ($tool in $tools) {
        $exe = Get-ActionToolPath -Manifest $Manifest -Root $Root -Package $tool.name
        # Gates and path builds never establish availability from a cached binary.
        $cached = !$RequirePrebuilt -and $Method -ne 'path' -and
            (Test-ActionToolInstallation -Manifest $Manifest -Root $Root -Package $tool.name)
        if ($cached) {
            Write-Information "Reusing $($tool.name) $($tool.version): the crates.io Cargo receipt matches and its executable is present." -InformationAction Continue
            Confirm-ToolRuntime -Tool $tool -Executable $exe -Version $tool.version
            $result[$tool.name] = $exe
            continue
        }
        Write-Information "Installing $($tool.name) using $Method into $Root because a verified reusable installation is absent or bypassed." -InformationAction Continue
        $cargo = (Get-Command cargo -CommandType Application -ErrorAction Stop).Source
        $expectedVersion = $tool.version
        if ($Method -eq 'path') {
            $packagePath = [IO.Path]::GetFullPath(
                (Join-Path -Path $SourcePath -ChildPath 'packages' -AdditionalChildPath $tool.name),
                $PWD.ProviderPath)
            $packageManifest = Join-Path $packagePath 'Cargo.toml'
            if (!(Test-Path -LiteralPath $packageManifest -PathType Leaf)) {
                throw "Missing source package manifest: $packagePath"
            }
            # Cargo resolves workspace-inherited versions and binary targets.
            # Source mode deliberately uses that checkout's identity, not release pins.
            $metadataArguments = @('metadata', '--manifest-path', $packageManifest,
                '--no-deps', '--format-version', '1', '--locked')
            $metadata = Invoke-ToolProcess -FilePath $cargo -Arguments $metadataArguments -CaptureOutput |
                ConvertFrom-Json -AsHashtable
            $sourcePackages = @($metadata.packages | Where-Object name -CEQ $tool.name)
            if ($sourcePackages.Count -ne 1) {
                throw "Source metadata must declare exactly one package named $($tool.name)."
            }
            $sourcePackage = $sourcePackages[0]
            $binaries = @($sourcePackage.targets | Where-Object {
                $_.name -ceq $tool.binary -and $_.kind -ccontains 'bin'
            })
            if ($binaries.Count -ne 1) {
                throw "Source package $($tool.name) does not provide the required binary $($tool.binary)."
            }
            $expectedVersion = $sourcePackage.version
            $arguments = @('install', '--path', $packagePath, '--locked', '--force', '--root', $Root)
            Write-Information "Building $($tool.name) $expectedVersion from $packagePath as resolved by Cargo metadata; release pins do not select its source version." -InformationAction Continue
        } elseif ($Method -eq 'install') {
            $arguments = @('install', $tool.name, '--version', "=$($tool.version)",
                '--locked', '--force', '--root', $Root)
            Write-Information "Building exact published version $($tool.version) with its locked dependencies." -InformationAction Continue
        } else {
            if (!(Get-Command cargo-binstall -CommandType Application -ErrorAction SilentlyContinue)) {
                throw 'cargo-binstall is required. Run the pinned cargo-bins/cargo-binstall bootstrap action before this installer.'
            }
            # Verified against cargo-binstall v1.23.0 args.rs. Restricting strategies
            # excludes both third-party quick-install archives and source fallback.
            $strategies = if ($RequirePrebuilt) { 'crate-meta-data' } else {
                'crate-meta-data,quick-install,compile'
            }
            $arguments = @('binstall', $tool.name, '--version', "=$($tool.version)",
                '--locked', '--no-confirm', '--force', '--root', $Root, '--strategies', $strategies)
            Write-Information "Resolving exact published version $($tool.version) using strategies: $strategies." -InformationAction Continue
        }
        Invoke-ToolProcess -FilePath $cargo -Arguments $arguments
        $receipt = Get-ToolReceipt -Root $Root -Tool $tool
        if (!$receipt -or !(Test-Path -LiteralPath $exe -PathType Leaf)) {
            throw "Installation did not produce the Cargo receipt and executable for $($tool.name)."
        }
        if ($receipt.version -cne $expectedVersion) {
            throw "Installation receipt for $($tool.name) records $($receipt.version), expected $expectedVersion for $Method."
        }
        if ($Method -eq 'path') {
            if ($receipt.source -cnotmatch '^path\+') {
                throw "Expected a fresh path installation receipt for $($tool.name)."
            }
        } elseif ($receipt.source -cne $script:PublishedRegistry) {
            throw "Expected a crates.io installation receipt for $($tool.name)."
        }
        Confirm-ToolRuntime -Tool $tool -Executable $exe -Version $receipt.version
        $result[$tool.name] = $exe
    }
    return $result
}

Export-ModuleMember -Function Read-ActionManifest, Get-RequiredTool, Install-ActionTools,
    Get-ActionToolPath, Test-ActionToolInstallation
