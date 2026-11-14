<#
.SYNOPSIS
Selects the EC20's USB network function (AT+QCFG="usbnet") and resets it.

.DESCRIPTION
  QMI   = 0  rmnet/QMI, the default. Linux qmi_wwan; no inbox Windows driver.
  ECM   = 1  CDC ECM. Linux cdc_ether. Whether Windows 11 23H2 has an inbox
             driver for CDC ECM was not checked; not used here.
  MBIM  = 2  CDC MBIM. Windows inbox Mobile Broadband (wmbclass), Linux cdc_mbim.
  RNDIS = 3  RNDIS. Windows has an inbox RNDIS driver, but it gives no
             Windows cellular UI; not recommended.
The setting is stored in the module and survives power cycles. The module
resets (AT+CFUN=1,1), drops off USB and comes back after about 20 to 30
seconds with a different set of interfaces.

.EXAMPLE
.\Set-Ec20UsbNet.ps1 -Mode MBIM
.\Set-Ec20UsbNet.ps1 -Mode QMI        # back to the factory default
.\Set-Ec20UsbNet.ps1 -Query

.NOTES
Windows PowerShell 5.1 compatible. SPDX-License-Identifier: MIT
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('QMI', 'ECM', 'MBIM', 'RNDIS')][string]$Mode,
    [switch]$Query,
    [switch]$NoReset
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Ec20.psm1') -Force
$codes = @{ QMI = 0; ECM = 1; MBIM = 2; RNDIS = 3 }

$cur = Invoke-Ec20At -Command 'AT+QCFG="usbnet"'
if ($Query -or -not $Mode) { exit 0 }
$want = $codes[$Mode]
$now = $null
foreach ($l in $cur.Lines) { if ($l -match '"usbnet",\s*(\d+)') { $now = [int]$Matches[1] } }
if ($now -eq $want) { Write-Host ('Already ' + $Mode + ' (' + $want + ').'); exit 0 }

if ($PSCmdlet.ShouldProcess('EC20', ('set usbnet to ' + $Mode + ' (' + $want + ') and reset the module'))) {
    $r = Invoke-Ec20At -Command ('AT+QCFG="usbnet",' + $want)
    if (-not $r.Ok) { throw 'The module rejected the usbnet setting.' }
    if ($NoReset) { Write-Host 'Set. It takes effect at the next module reset (AT+CFUN=1,1) or power cycle.'; exit 0 }
    # The module resets while answering, so a missing reply is expected.
    try { Invoke-Ec20At -Command 'AT+CFUN=1,1' -TimeoutMs 3000 | Out-Null } catch { }
    Write-Host 'The module is resetting. Wait about 30 seconds, then run Get-Ec20Status.ps1.'
}
