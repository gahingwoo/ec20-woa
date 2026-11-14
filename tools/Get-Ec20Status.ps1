<#
.SYNOPSIS
Shows the driver binding of each EC20 interface, then SIM, registration,
signal, operator and USB network mode.

.NOTES
Windows PowerShell 5.1 compatible. SPDX-License-Identifier: MIT
Only read-only (query) AT commands are sent. IMEI, IMSI and ICCID are not
queried, so the output can be pasted into a bug report.
#>
[CmdletBinding()]
param([ValidateSet('At', 'Modem')][string]$Role = 'At')
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Ec20.psm1') -Force

Write-Host 'EC20 interfaces as Windows sees them:'
Get-Ec20Interface | Sort-Object MI | Format-Table MI, Role, Status, Service, ComPort, Name -AutoSize | Out-Host

$queries = @(
    'ATI',                 # manufacturer, model, revision
    'AT+QGMR',             # full firmware version
    'AT+CPIN?',            # SIM state: READY, SIM PIN, SIM PUK
    'AT+QPINC="SC"',       # remaining PIN and PUK attempts
    'AT+CFUN?',            # 1 = full functionality
    'AT+CREG?',            # circuit-switched registration (1 home, 5 roaming)
    'AT+CEREG?',           # LTE registration
    'AT+CSQ',              # signal: rssi 0..31 (99 unknown), ber
    'AT+COPS?',            # current operator
    'AT+QNWINFO',          # access technology, operator, band, channel
    'AT+QCFG="usbnet"',    # 0 QMI, 1 ECM, 2 MBIM, 3 RNDIS
    'AT+QPCMV?',           # voice over USB audio
    'AT+QGPS?'             # GNSS on/off
)
foreach ($q in $queries) {
    try { Invoke-Ec20At -Command $q -Role $Role | Out-Null }
    catch { Write-Host ('> ' + $q + '  failed: ' + $_.Exception.Message) }
}
