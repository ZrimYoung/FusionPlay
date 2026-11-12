param([string]$ToolsRoot = $env:FUSIONPLAY_WINDOWS_TOOLS)
$ErrorActionPreference = 'Stop'
$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $ToolsRoot) { $ToolsRoot = Join-Path (Split-Path $RepositoryRoot -Parent) '.tools/fusionplay-windows' }
$script:WindowsToolsRoot = [IO.Path]::GetFullPath($ToolsRoot)
$env:DOTNET_ROOT = Join-Path $WindowsToolsRoot 'dotnet'
$env:DOTNET_CLI_HOME = Join-Path $WindowsToolsRoot 'cache/dotnet-home'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$env:NUGET_PACKAGES = Join-Path $WindowsToolsRoot 'cache/nuget'
$env:CARGO_HOME = Join-Path $WindowsToolsRoot 'cargo'
$env:RUSTUP_HOME = Join-Path $WindowsToolsRoot 'rustup'
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
$env:CARGO_TARGET_DIR = Join-Path $WindowsToolsRoot 'cache/cargo-target'
$env:TEMP = Join-Path $WindowsToolsRoot 'cache/tmp'
$env:TMP = $env:TEMP
$env:PATH = "$env:DOTNET_ROOT;$env:CARGO_HOME\bin;$env:PATH"
foreach ($directory in @($env:DOTNET_CLI_HOME, $env:NUGET_PACKAGES, $env:CARGO_TARGET_DIR, $env:TEMP)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$taskVswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (Test-Path -LiteralPath $taskVswhere) {
    $taskVs = & $taskVswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($taskVs) {
        & (Join-Path $taskVs 'Common7/Tools/Launch-VsDevShell.ps1') -Arch amd64 -HostArch amd64 -SkipAutomaticLocation | Out-Null
    }
}
