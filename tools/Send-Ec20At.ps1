<#
.SYNOPSIS
Sends one AT command to the EC20 and prints the reply.

.EXAMPLE
.\Send-Ec20At.ps1 AT
.\Send-Ec20At.ps1 'AT+QCFG="usbnet"'
.\Send-Ec20At.ps1 -Role Modem -TimeoutMs 30000 'AT+COPS=?'

.NOTES
Windows PowerShell 5.1 compatible. SPDX-License-Identifier: MIT
Exit code 0 when the final result code is OK, 1 otherwise.
Do not pass a SIM PIN here; use Enter-Ec20SimPin.ps1, which keeps it out of
the output and out of the command history.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Command,
    [ValidateSet('At', 'Modem', 'Nmea', 'Diag')][string]$Role = 'At',
    [int]$TimeoutMs = 5000
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Ec20.psm1') -Force
if ($Command -match '^AT\+CPIN\s*=') {
    throw 'Use Enter-Ec20SimPin.ps1 for the SIM PIN.'
}
$r = Invoke-Ec20At -Command $Command -Role $Role -TimeoutMs $TimeoutMs
if ($r.Ok) { exit 0 } else { exit 1 }
