param([Parameter(Mandatory=$true)][string]$ProgramPath)
$ErrorActionPreference = 'Stop'
$taskProgram = [IO.Path]::GetFullPath($ProgramPath)
if (-not (Test-Path -LiteralPath $taskProgram -PathType Leaf) -or [IO.Path]::GetFileName($taskProgram) -ne 'FusionPlay.Windows.exe') {
    throw 'Select the FusionPlay.Windows.exe from the extracted app folder.'
}
foreach ($taskProtocol in @('TCP','UDP')) {
    $taskRuleName = "FusionPlay-Windows-$taskProtocol"
    $taskExisting = Get-NetFirewallRule -Name $taskRuleName -ErrorAction SilentlyContinue
    if ($taskExisting) {
        $taskExisting | Set-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -Profile Private -RemoteAddress LocalSubnet -Protocol $taskProtocol -Program $taskProgram | Out-Null
    } else {
        New-NetFirewallRule -Name $taskRuleName -DisplayName "FusionPlay Windows ($taskProtocol, local subnet)" -Enabled True -Direction Inbound -Action Allow -Profile Private -RemoteAddress LocalSubnet -Protocol $taskProtocol -Program $taskProgram | Out-Null
    }
}
