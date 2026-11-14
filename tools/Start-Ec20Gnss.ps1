<#
.SYNOPSIS
Turns the EC20's GNSS receiver on (AT+QGPS=1) and prints NMEA sentences.

.EXAMPLE
.\Start-Ec20Gnss.ps1                     # on, then 30 s of NMEA from MI_01
.\Start-Ec20Gnss.ps1 -ListenSeconds 0 -Location
.\Start-Ec20Gnss.ps1 -Stop               # AT+QGPSEND

.NOTES
Windows PowerShell 5.1 compatible. SPDX-License-Identifier: MIT
A cold start needs an antenna with sky view and can take minutes before
$GPGGA carries a position; until then the sentences have empty fields.
AT+QGPSLOC answers +CME ERROR: 516 while there is no fix.
#>
[CmdletBinding()]
param(
    [int]$ListenSeconds = 30,
    [switch]$Location,
    [switch]$Stop
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Ec20.psm1') -Force

if ($Stop) { Invoke-Ec20At -Command 'AT+QGPSEND' | Out-Null; exit 0 }

$s = Invoke-Ec20At -Command 'AT+QGPS?'
$on = $false
foreach ($l in $s.Lines) { if ($l -match '^\+QGPS:\s*1') { $on = $true } }
if (-not $on) {
    $r = Invoke-Ec20At -Command 'AT+QGPS=1'
    if (-not $r.Ok) { throw 'AT+QGPS=1 failed.' }
}
# Where NMEA goes: "usbnmea" is the MI_01 port.
Invoke-Ec20At -Command 'AT+QGPSCFG="outport"' | Out-Null
if ($Location) { Invoke-Ec20At -Command 'AT+QGPSLOC=2' | Out-Null }
if ($ListenSeconds -gt 0) {
    Write-Host ('NMEA from MI_01 for ' + $ListenSeconds + ' s:')
    Receive-Ec20Port -Role Nmea -Seconds $ListenSeconds
}
