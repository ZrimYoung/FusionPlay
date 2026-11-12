param([ValidateSet('Debug','Release')][string]$Configuration = 'Release', [switch]$SkipNative)
. (Join-Path $PSScriptRoot 'env.ps1')
Push-Location (Join-Path $RepositoryRoot 'windows')
try {
    if (-not $SkipNative) {
        $taskCargoArguments = @('build', '--locked', '--manifest-path', '../src/FusionPlay.Host/Cargo.toml', '--lib')
        if ($Configuration -eq 'Release') { $taskCargoArguments += '--release' }
        & cargo @taskCargoArguments
        if ($LASTEXITCODE -ne 0) { throw 'Rust build failed.' }
    }
    & (Join-Path $PSScriptRoot 'make-icon.ps1')
    $taskNativeProfile = if ($Configuration -eq 'Release') { 'release' } else { 'debug' }
    $script:NativeOutput = Join-Path $env:CARGO_TARGET_DIR $taskNativeProfile
    & dotnet build FusionPlay.Windows/FusionPlay.Windows.csproj -c $Configuration -p:Platform=x64 "-p:FusionPlayNativeDir=$NativeOutput" --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Windows app build failed.' }
} finally { Pop-Location }
