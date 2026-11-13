param([string]$Version = '0.2.0-preview6', [switch]$SkipNative)
. (Join-Path $PSScriptRoot 'env.ps1')
if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$') { throw 'Invalid package version.' }
$taskArtifacts = Join-Path $RepositoryRoot 'artifacts'
$taskName = "FusionPlay-Windows-$Version-x64"
$taskPublish = Join-Path $taskArtifacts $taskName
if ((Test-Path -LiteralPath $taskPublish) -and (Get-ChildItem -LiteralPath $taskPublish -Force | Select-Object -First 1)) {
    throw 'Package output already exists. Use a new version or move the old folder before packaging; runtime data is never replaced.'
}
New-Item -ItemType Directory -Path $taskPublish -Force | Out-Null
Push-Location (Join-Path $RepositoryRoot 'windows')
try {
    if (-not $SkipNative) {
        & cargo build --locked --release --manifest-path ../src/FusionPlay.Host/Cargo.toml --lib
        if ($LASTEXITCODE -ne 0) { throw 'Rust build failed.' }
    }
    & (Join-Path $PSScriptRoot 'make-icon.ps1')
    $taskCompile = Join-Path $taskArtifacts ("windows-compile-" + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '/')
    & dotnet publish FusionPlay.Windows/FusionPlay.Windows.csproj -c Release -p:Platform=x64 "-p:Version=$Version" "-p:BaseOutputPath=$taskCompile" "-p:FusionPlayNativeDir=$env:CARGO_TARGET_DIR/release" --self-contained true -o $taskPublish --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Self-contained Windows publish failed.' }
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'windows/README.zh-CN.md') -Destination (Join-Path $taskPublish '使用说明.md') -Force
    $taskCommit = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
    [ordered]@{
        version=$Version; architecture='x64'; source_commit=$taskCommit
        source_url="https://github.com/ZrimYoung/FusionPlay/tree/$taskCommit"
        branch=(& git -C $RepositoryRoot branch --show-current).Trim()
        dirty=[bool](& git -C $RepositoryRoot status --porcelain)
        acoustic_sync='not_verified'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskPublish 'build-info.json') -Encoding utf8
    $taskArchive = Join-Path $taskArtifacts "$taskName.zip"
    Add-Type -AssemblyName System.IO.Compression
    $taskFile = [IO.File]::Open($taskArchive, [IO.FileMode]::Create)
    $taskZip = [IO.Compression.ZipArchive]::new($taskFile, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($taskFileEntry in Get-ChildItem -LiteralPath $taskPublish -Recurse -File) {
            $taskRelative = [IO.Path]::GetRelativePath($taskPublish, $taskFileEntry.FullName)
            if ($taskRelative -match '(^|[\\/])FusionPlayData([\\/]|$)' -or $taskRelative -match '^(bin|obj)[\\/]' -or $taskRelative -match '\.pdb$') { continue }
            $taskEntry = $taskZip.CreateEntry("$taskName/" + $taskRelative.Replace('\','/'), [IO.Compression.CompressionLevel]::Optimal)
            $taskSourceStream = [IO.File]::OpenRead($taskFileEntry.FullName)
            $taskTargetStream = $taskEntry.Open()
            try { $taskSourceStream.CopyTo($taskTargetStream) } finally { $taskSourceStream.Dispose(); $taskTargetStream.Dispose() }
        }
    } finally { $taskZip.Dispose(); $taskFile.Dispose() }
    $taskHash = Get-FileHash -LiteralPath $taskArchive -Algorithm SHA256
    "$($taskHash.Hash.ToLowerInvariant())  $taskName.zip" | Set-Content -LiteralPath "$taskArchive.sha256" -Encoding ascii
    Write-Output "App: $taskPublish"
    Write-Output "ZIP: $taskArchive"
    Write-Output "SHA256: $($taskHash.Hash)"
} finally { Pop-Location }
