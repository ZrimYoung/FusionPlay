param([string]$ToolsRoot = $env:FUSIONPLAY_WINDOWS_TOOLS)
$ErrorActionPreference = 'Stop'
if (-not $ToolsRoot) { $ToolsRoot = Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))) '.tools/fusionplay-windows' }
$taskTools = [IO.Path]::GetFullPath($ToolsRoot)
New-Item -ItemType Directory -Path $taskTools -Force | Out-Null
$taskDotnet = Join-Path $taskTools 'dotnet/dotnet.exe'
if (-not (Test-Path -LiteralPath $taskDotnet)) {
    $taskMetadata = Invoke-RestMethod 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json'
    $taskSdk = $taskMetadata.releases | ForEach-Object { $_.sdks } | Where-Object { $_.version -eq '10.0.403' } | Select-Object -First 1
    if (-not $taskSdk) { throw 'The pinned .NET 10.0.403 SDK was not found in official release metadata.' }
    $taskArchive = $taskSdk.files | Where-Object { $_.rid -eq 'win-x64' -and $_.name -match '\.zip$' } | Select-Object -First 1
    $taskDownload = Join-Path $taskTools 'dotnet-sdk.zip'
    Invoke-WebRequest -Uri $taskArchive.url -OutFile $taskDownload
    if ((Get-FileHash -LiteralPath $taskDownload -Algorithm SHA512).Hash -ne $taskArchive.hash) { throw '.NET SDK checksum mismatch.' }
    Expand-Archive -LiteralPath $taskDownload -DestinationPath (Join-Path $taskTools 'dotnet') -Force
}
$env:CARGO_HOME = Join-Path $taskTools 'cargo'
$env:RUSTUP_HOME = Join-Path $taskTools 'rustup'
$taskRustup = Join-Path $env:CARGO_HOME 'bin/rustup.exe'
if (-not (Test-Path -LiteralPath $taskRustup)) {
    $taskInstaller = Join-Path $taskTools 'rustup-init.exe'
    Invoke-WebRequest 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' -OutFile $taskInstaller
    $env:RUSTUP_INIT_SKIP_PATH_CHECK = 'yes'
    & $taskInstaller -y --no-modify-path --profile minimal --default-host x86_64-pc-windows-msvc --default-toolchain stable
    if ($LASTEXITCODE -ne 0) { throw 'Rust installation failed.' }
}
& $taskRustup component add rustfmt clippy --toolchain stable-x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw 'Rust check tools installation failed.' }
Write-Output "Tools are ready in $taskTools. Visual Studio C++ Build Tools and a Windows SDK must also be installed."
