<#
.SYNOPSIS
Unlocks a PIN-protected SIM with AT+CPIN.

.DESCRIPTION
Checks AT+CPIN? first and sends the PIN only when the SIM is waiting for its
PIN. Never sends anything when the SIM asks for its PUK. Shows the number of
attempts left (AT+QPINC) before sending. Makes exactly one attempt.

The PIN is a SecureString. Without -Pin the script prompts for it, so it is
not stored in the PowerShell history. It is replaced with **** in all
output, including the modem's echo of the command.

.EXAMPLE
.\Enter-Ec20SimPin.ps1
.\Enter-Ec20SimPin.ps1 -Pin (Read-Host -AsSecureString 'SIM PIN')

.NOTES
Windows PowerShell 5.1 compatible. SPDX-License-Identifier: MIT
In MBIM mode Windows also asks for the PIN (Settings > Network & internet >
Cellular). Unlocking it here first is fine; the SIM stays unlocked until the
module is reset or powered off.
#>
[CmdletBinding()]
param(
    [Security.SecureString]$Pin,
    [ValidateSet('At', 'Modem')][string]$Role = 'At'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Ec20.psm1') -Force

$s = Invoke-Ec20At -Command 'AT+CPIN?' -Role $Role
$state = ($s.Lines | Where-Object { $_ -like '+CPIN:*' } | Select-Object -First 1)
if (-not $state) { throw 'No +CPIN reply. Is a SIM inserted?' }
if ($state -match 'READY') { Write-Host 'The SIM is already unlocked.'; exit 0 }
if ($state -match 'PUK') { throw 'The SIM asks for its PUK. Not sending anything; unlock it in a phone.' }
if ($state -notmatch 'SIM PIN$') { throw ('Unexpected SIM state: ' + $state) }

$left = Invoke-Ec20At -Command 'AT+QPINC="SC"' -Role $Role
foreach ($l in $left.Lines) {
    if ($l -match '^\+QPINC:\s*"SC",\s*(\d+)') {
        if ([int]$Matches[1] -le 1) {
            throw ('Only ' + $Matches[1] + ' PIN attempt left. Not trying; enter it in a phone if you are sure of it.')
        }
    }
}

if (-not $Pin) { $Pin = Read-Host -AsSecureString 'SIM PIN' }
$plain = ConvertFrom-Ec20SecureString $Pin
try {
    if ($plain -notmatch '^[0-9]{4,8}$') { throw 'A SIM PIN is 4 to 8 digits.' }
    $r = Invoke-Ec20At -Command ('AT+CPIN="' + $plain + '"') -Role $Role -TimeoutMs 10000 -Secret @($plain)
} finally {
    $plain = $null
    [GC]::Collect()
}
if (-not $r.Ok) { throw 'The PIN was not accepted. Check the attempts left with Get-Ec20Status.ps1 before trying again.' }
Start-Sleep -Seconds 2
Invoke-Ec20At -Command 'AT+CPIN?' -Role $Role | Out-Null
