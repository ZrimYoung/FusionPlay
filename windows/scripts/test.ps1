param([switch]$Network, [switch]$SkipRust)
. (Join-Path $PSScriptRoot 'env.ps1')
Push-Location (Join-Path $RepositoryRoot 'windows')
try {
    if (-not $SkipRust) {
        & cargo test --locked --manifest-path ../src/FusionPlay.Host/Cargo.toml --lib
        if ($LASTEXITCODE -ne 0) { throw 'Host tests failed.' }
        & cargo test --locked --manifest-path ../src/FusionPlay.MiPlaySdk/Cargo.toml --lib
        if ($LASTEXITCODE -ne 0) { throw 'SDK tests failed.' }
    }
    $taskTestArgs = @('--native')
    if ($Network) { $taskTestArgs += '--network' }
    & dotnet run --project FusionPlay.Tests/FusionPlay.Tests.csproj -c Release "-p:FusionPlayNativeDir=$env:CARGO_TARGET_DIR/release" -- @taskTestArgs
    if ($LASTEXITCODE -ne 0) { throw 'Windows integration tests failed.' }
} finally { Pop-Location }
