<#
.SYNOPSIS
Routes voice-call audio to the EC20's USB Audio function (AT+QPCMV=1,2),
after the module has registered.

.DESCRIPTION
Measured on this module under Linux (EC20CEFILGR08A03M1G, 2026-11-10): when
AT+QPCMV=1,2 is the first QPCMV of a boot and is sent before network
registration, the module answers OK and reads back 1,2, but every call of
that boot is silent on USB audio, and sending it again later in the same
boot does not help. Sent after registration plus about 20 s, calls had
audio. So this script waits for +CREG/+CEREG to report registered, waits
-DelaySeconds more, and only then sends it.

If AT+QPCMV? already reads 1,2 when the script starts, it was set earlier in
this boot (perhaps too early); the script says so and does nothing unless
-Force is given. The cure for a too-early setting is a module reset.

The USB Audio function itself (MI_05) must already be enabled in the
module's USB configuration; on this board it is (Windows shows it).

.EXAMPLE
.\Enable-Ec20CallAudio.ps1
.\Enable-Ec20CallAudio.ps1 -Disable

.NOTES
Windows PowerShell 5.1 compatible. SPDX-License-Identifier: MIT
Calls themselves: ATD<number>; to dial, ATA to answer, ATH to hang up,
AT+CLCC to list calls. See README.md.
#>
[CmdletBinding()]
param(
    [ValidateSet('At', 'Modem')][string]$Role = 'Modem',
    [int]$WaitRegistrationSeconds = 180,
    [int]$DelaySeconds = 20,
    [switch]$Disable,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Ec20.psm1') -Force

if ($Disable) { Invoke-Ec20At -Command 'AT+QPCMV=0' -Role $Role | Out-Null; exit 0 }

$q = Invoke-Ec20At -Command 'AT+QPCMV?' -Role $Role
foreach ($l in $q.Lines) {
    if ($l -match '^\+QPCMV:\s*1\s*,\s*2' -and -not $Force) {
        Write-Host 'QPCMV is already 1,2 in this boot. If calls are silent, reset the module (AT+CFUN=1,1) and run this script again after it registers.'
        exit 0
    }
}

$deadline = (Get-Date).AddSeconds($WaitRegistrationSeconds)
while (-not (Get-Ec20Registration -Role $Role)) {
    if ((Get-Date) -gt $deadline) { throw ('Not registered after ' + $WaitRegistrationSeconds + ' s. Check Get-Ec20Status.ps1 (SIM PIN, antenna, signal).') }
    Write-Host 'Waiting for network registration...'
    Start-Sleep -Seconds 5
}
Write-Host ('Registered. Waiting ' + $DelaySeconds + ' s more before enabling call audio.')
Start-Sleep -Seconds $DelaySeconds
$r = Invoke-Ec20At -Command 'AT+QPCMV=1,2' -Role $Role
if (-not $r.Ok) { throw 'AT+QPCMV=1,2 failed.' }
Invoke-Ec20At -Command 'AT+QPCMV?' -Role $Role | Out-Null
