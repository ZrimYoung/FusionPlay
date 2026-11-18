param(
    [string]$ToolsRoot = $env:FUSIONPLAY_TOOLS_ROOT,
    [string]$AndroidSdk,
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [string]$ApplicationId = 'com.fusionplay.android',
    [string[]]$Abis = @('armeabi-v7a', 'arm64-v8a', 'x86_64')
)

$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repository = Split-Path -Parent $project
$android = Join-Path $project 'android'
$variant = $Configuration.ToLowerInvariant()
if ($ApplicationId -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') {
    throw 'ApplicationId must be a valid Android package name.'
}
if (-not $Abis.Count -or @($Abis | Where-Object { $_ -notin @('armeabi-v7a', 'arm64-v8a', 'x86_64') }).Count) {
    throw 'Choose armeabi-v7a, arm64-v8a or x86_64.'
}
if (-not $AndroidSdk) { $AndroidSdk = $env:ANDROID_HOME }
if (-not $AndroidSdk) { $AndroidSdk = $env:ANDROID_SDK_ROOT }
if (-not $AndroidSdk -and $ToolsRoot) { $AndroidSdk = Join-Path $ToolsRoot 'android-sdk' }
if (-not $AndroidSdk) { throw 'Set ANDROID_HOME or supply AndroidSdk.' }
$AndroidSdk = [IO.Path]::GetFullPath($AndroidSdk)
$ndk = Join-Path $AndroidSdk 'ndk/28.2.13676358'
if (-not (Test-Path -LiteralPath $ndk -PathType Container)) { throw "Android NDK 28.2.13676358 is missing: $ndk" }

$variables = @('ANDROID_HOME', 'ANDROID_SDK_ROOT', 'ANDROID_NDK_HOME', 'CARGO_HOME', 'RUSTUP_HOME', 'GRADLE_USER_HOME', 'CARGO_TARGET_DIR')
$previous = @{}
foreach ($name in $variables) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $env:ANDROID_HOME = $AndroidSdk
    $env:ANDROID_SDK_ROOT = $AndroidSdk
    $env:ANDROID_NDK_HOME = $ndk
    if ($ToolsRoot) {
        $tools = [IO.Path]::GetFullPath($ToolsRoot)
        if (-not $env:CARGO_HOME) { $env:CARGO_HOME = Join-Path $tools 'rust/cargo-home' }
        if (-not $env:RUSTUP_HOME) { $env:RUSTUP_HOME = Join-Path $tools 'rust/rustup-home' }
        if (-not $env:GRADLE_USER_HOME) { $env:GRADLE_USER_HOME = Join-Path $tools 'cache/gradle' }
        if (-not $env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR = Join-Path $tools 'cache/cargo-target/FusionPlay' }
    }
    if (-not $env:CARGO_HOME) { $env:CARGO_HOME = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cargo' }

    & (Join-Path $android 'gradlew.bat') -p $android ":app:assemble$Configuration" --no-daemon `
        "-PfusionPlayApplicationId=$ApplicationId" "-PfusionPlayAbis=$($Abis -join ',')"
    if ($LASTEXITCODE -ne 0) { throw "Android $Configuration build failed (exit $LASTEXITCODE)." }

    $apk = Join-Path $project "build/app/outputs/apk/$variant/app-$variant.apk"
    if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) { throw "APK missing: $apk" }
    $output = Join-Path $repository 'artifacts/android-native'
    New-Item -ItemType Directory -Force -Path $output | Out-Null
    $target = Join-Path $output "FusionPlay-$ApplicationId-$variant-$($Abis -join '_').apk"
    Copy-Item -LiteralPath $apk -Destination $target -Force
    Write-Output $target
} finally {
    foreach ($name in $variables) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
}
