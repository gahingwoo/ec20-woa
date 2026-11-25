<#
.SYNOPSIS
Selects the EC20's USB network function (AT+QCFG="usbnet"), resets the
module and checks the result.

.DESCRIPTION
  QMI   = 0  rmnet/QMI, the factory default. Linux qmi_wwan; no inbox
             Windows driver (MI_04 shows a yellow mark).
  ECM   = 1  CDC ECM. Not used here.
  MBIM  = 2  CDC MBIM. Windows inbox Mobile Broadband class driver
             (wmbclass), Linux cdc_mbim; ModemManager supports both.
  RNDIS = 3  RNDIS. No Windows cellular UI; not recommended.

The setting is stored in the module and survives power cycles, so Linux on
the same board sees the same mode until it is switched back.

Steps, each of which stops the script if it fails:
  1. read the current mode (AT+QCFG="usbnet") and the firmware (AT+QGMR);
  2. ask for confirmation (-Confirm:$false skips it);
  3. AT+QCFG="usbnet",<n>, then read it back: it must say <n>;
  4. AT+CFUN=1,1 (the module resets and drops off USB; no reply expected);
  5. wait until the AT port answers again (-WaitSeconds, default 120);
  6. read AT+QCFG="usbnet" again after the reset: it must say <n>;
  7. list the module's USB functions and say whether the network function
     is the expected one (MBIM: a 02/0E interface bound to wmbclass).

Exit codes: 0 done and checked; 1 refused or cancelled; 2 the read-back
did not match; 3 the module did not come back in time; 4 the mode is set
but the expected network function is not there or has no driver.

.PARAMETER Port
The COM port of the AT interface, for example COM6. Without it the AT port
(MI_02) is looked up. The COM number stays the same across the reset,
because the serial interfaces keep their numbers in every usbnet mode.

.EXAMPLE
.\Set-Ec20UsbNet.ps1 -Query -Port COM6
.\Set-Ec20UsbNet.ps1 -Mode MBIM -Port COM6
.\Set-Ec20UsbNet.ps1 -Mode QMI -Port COM6       # back to the factory default

.NOTES
Windows PowerShell 5.1 compatible. SPDX-License-Identifier: MIT
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('QMI', 'ECM', 'MBIM', 'RNDIS')][string]$Mode,
    [switch]$Query,
    [string]$Port,
    [switch]$NoReset,
    [int]$WaitSeconds = 120
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Ec20.psm1') -Force
$codes = @{ QMI = 0; ECM = 1; MBIM = 2; RNDIS = 3 }
$names = @{ 0 = 'QMI'; 1 = 'ECM'; 2 = 'MBIM'; 3 = 'RNDIS' }

function Read-UsbNet {
    param([int]$TimeoutMs = 5000, [switch]$Quiet)
    $r = Invoke-Ec20At -Command 'AT+QCFG="usbnet"' -Port $Port -TimeoutMs $TimeoutMs -Quiet:$Quiet
    foreach ($l in $r.Lines) { if ($l -match '"usbnet",\s*(\d+)') { return [int]$Matches[1] } }
    return $null
}

function Show-Functions {
    $f = @(Get-Ec20Interface | Sort-Object MI)
    $f | Format-Table MI, Role, Status, Service, ComPort, Name -AutoSize | Out-Host
    return $f
}

# 1. Where the module is now.
Write-Host '--- before ---'
$now = Read-UsbNet
if ($null -eq $now) { Write-Host 'The module did not report a usbnet mode.'; exit 1 }
Write-Host ('usbnet is ' + $now + ' (' + $names[$now] + ')')
Invoke-Ec20At -Command 'AT+QGMR' -Port $Port | Out-Null
[void](Show-Functions)
if ($Query -or -not $Mode) { exit 0 }

$want = $codes[$Mode]
if ($now -eq $want) { Write-Host ('Already ' + $Mode + ' (' + $want + '). Nothing to do.'); exit 0 }

# 2. Confirmation.
$what = 'set usbnet from ' + $now + ' (' + $names[$now] + ') to ' + $want + ' (' + $Mode + ') and reset the module. ' +
        'The setting is stored in the module and Linux on this board will see it too.'
if (-not $PSCmdlet.ShouldProcess('EC20 on ' + $(if ($Port) { $Port } else { 'its AT port' }), $what)) { exit 1 }

# 3. Set and read back before the reset.
$r = Invoke-Ec20At -Command ('AT+QCFG="usbnet",' + $want) -Port $Port
if (-not $r.Ok) { Write-Host 'The module rejected the setting. Nothing was changed.'; exit 1 }
$rb = Read-UsbNet
if ($rb -ne $want) {
    Write-Host ('Read-back says ' + $rb + ', not ' + $want + '. Not resetting.')
    exit 2
}
Write-Host ('Read-back before the reset: ' + $rb + ' (' + $names[$rb] + ').')
if ($NoReset) { Write-Host 'Set. It takes effect at the next AT+CFUN=1,1 or power cycle.'; exit 0 }

# 4. Reset. The module resets while answering, so no reply is expected.
try { Invoke-Ec20At -Command 'AT+CFUN=1,1' -Port $Port -TimeoutMs 3000 | Out-Null } catch { }
Write-Host 'The module is resetting.'
Start-Sleep -Seconds 10

# 5. Wait for the AT port to answer again.
$deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
$after = $null
while ([DateTime]::UtcNow -lt $deadline) {
    try {
        $a = Invoke-Ec20At -Command 'AT' -Port $Port -TimeoutMs 2000 -Quiet
        if ($a.Ok) {
            # 6. Read back after the reset.
            Start-Sleep -Seconds 3
            $after = Read-UsbNet
            break
        }
    } catch { }
    Start-Sleep -Seconds 3
}
if ($null -eq $after) {
    Write-Host ('The AT port did not answer within ' + $WaitSeconds + ' s. Check Device Manager; a power cycle of the module also applies the setting.')
    exit 3
}
Write-Host '--- after ---'
Write-Host ('Read-back after the reset: ' + $after + ' (' + $names[$after] + ')')
if ($after -ne $want) { Write-Host 'The module came back in a different mode.'; exit 2 }

# 7. The USB functions as Windows sees them now. PnP may need a few seconds
#    to install the new network function.
Start-Sleep -Seconds 10
$f = Show-Functions
$ok = $true
switch ($Mode) {
    'MBIM' {
        $m = @($f | Where-Object { $_.Role -eq 'MBIM' })
        if (-not $m) {
            Write-Host 'No MBIM (02/0E) function is present. If MI_04 and MI_05 appear as two separate functions, the module has no IAD for MBIM and Windows cannot group them; switch back with -Mode QMI.'
            $ok = $false
        } elseif ($m[0].Status -ne 'OK' -or $m[0].Service -notmatch '^(cx)?wmbclass$') {
            # netwmbclass.inf names the service cxwmbclass on 22621 (23H2)
            # and wmbclass on older builds
            Write-Host ('The MBIM function is ' + $m[0].Status + ' with service ' + $m[0].Service + ', not OK on the in-box MBIM driver (cxwmbclass).')
            $ok = $false
        } else {
            Write-Host ('MBIM is bound to ' + $m[0].Service + '. Settings > Network & internet > Cellular should be there now.')
            Write-Host 'Check: netsh mbn show interfaces ; netsh mbn show readyinfo *'
        }
    }
    'QMI' {
        if (-not @($f | Where-Object { $_.Role -eq 'QMI' })) { Write-Host 'No QMI (FF/FF/FF) function at MI_04.'; $ok = $false }
    }
}
foreach ($r in 'Diag', 'Nmea', 'At', 'Modem') {
    $i = @($f | Where-Object { $_.Role -eq $r })
    if (-not $i -or $i[0].Status -ne 'OK') { Write-Host ('The ' + $r + ' port is missing or not OK.'); $ok = $false }
}
if (-not @($f | Where-Object { $_.Role -eq 'Audio' })) { Write-Host 'Note: no USB Audio function (UAC) is present.' }
if ($ok) { exit 0 } else { exit 4 }
