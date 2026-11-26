# Ec20.psm1: shared helpers for the ec20-woa scripts.
# Windows PowerShell 5.1 compatible. SPDX-License-Identifier: MIT
#
# Talks to a Quectel EC20/EC25 (USB 2C7C:0125) through whichever driver the
# serial interfaces are bound to:
#   usbser (inf\usbser\ec20-ports.inf): a COM port, opened with
#           System.IO.Ports.SerialPort;
#   WinUSB (inf\winusb\ec20-winusb.inf): no COM port, ec20at.exe is used.

Set-StrictMode -Version 2

$Script:HwPrefix = 'USB\VID_2C7C&PID_0125&MI_'
# Used only when the interface classes cannot be read: the QMI/MBIM layout.
$Script:RoleMi = @{ Diag = 0; Nmea = 1; At = 2; Modem = 3 }

function Get-Ec20InterfaceClass {
    # "FF/00/00" from the interface's compatible IDs, or '' if unreadable.
    param([string]$InstanceId)
    try {
        $cids = (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName DEVPKEY_Device_CompatibleIds -ErrorAction Stop).Data
        foreach ($c in @($cids)) {
            if ($c -match '^USB\\Class_([0-9A-F]{2})&SubClass_([0-9A-F]{2})&Prot_([0-9A-F]{2})$') {
                return ($Matches[1] + '/' + $Matches[2] + '/' + $Matches[3]).ToUpperInvariant()
            }
        }
    } catch {}
    return ''
}

function Get-Ec20Interface {
    <#
    .SYNOPSIS
    Lists the functions (MI_xx) of the EC20 that Windows currently sees.
    .DESCRIPTION
    The interface numbers move with the USB network mode (AT+QCFG="usbnet"):
    the AT port is MI_02 in QMI and MBIM mode and MI_04 in RNDIS mode. So
    the roles come from the classes: the FF/00/00 interfaces in ascending
    order are NMEA, AT and modem in every mode, the first FF/FF/FF one is
    DM, and the rest is network (QMI FF/FF/FF, MBIM 02/0E, RNDIS E0,
    ECM 02/06) or audio (01). See README.md, "Interfaces per usbnet mode".
    #>
    [CmdletBinding()]
    param()
    $devs = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like ($Script:HwPrefix + '*') })
    $rows = @()
    foreach ($d in $devs) {
        $mi = -1
        if ($d.InstanceId -match '&MI_([0-9A-F]{2})') { $mi = [Convert]::ToInt32($Matches[1], 16) }
        $port = $null
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $d.InstanceId + '\Device Parameters'
        $pp = Get-ItemProperty -Path $key -Name PortName -ErrorAction SilentlyContinue
        if ($pp) { $port = $pp.PortName }
        $svc = $null
        if ($d.PSObject.Properties['Service']) { $svc = $d.Service }
        $rows += [pscustomobject]@{
            MI         = ('MI_{0:D2}' -f $mi)
            Class      = (Get-Ec20InterfaceClass $d.InstanceId)
            Role       = ''
            Status     = $d.Status
            Service    = $svc
            ComPort    = $port
            Name       = $d.FriendlyName
            InstanceId = $d.InstanceId
        }
    }
    $rows = @($rows | Sort-Object MI)
    if (@($rows | Where-Object { -not $_.Class }).Count) {
        foreach ($r in $rows) {
            $mi = [Convert]::ToInt32($r.MI.Substring(3), 10)
            foreach ($k in $Script:RoleMi.Keys) { if ($Script:RoleMi[$k] -eq $mi) { $r.Role = $k } }
            if ($mi -eq 4) { $r.Role = 'Network' }
            if ($mi -eq 5) { $r.Role = 'Audio' }
        }
        return $rows
    }
    $serial = @('Nmea', 'At', 'Modem'); $n = 0; $dm = $false
    foreach ($r in $rows) {
        switch -Regex ($r.Class) {
            '^FF/00/00$' { if ($n -lt 3) { $r.Role = $serial[$n] }; $n++ }
            '^FF/FF/FF$' { if (-not $dm) { $r.Role = 'Diag'; $dm = $true } else { $r.Role = 'Network' } }
            '^(02/0E|02/06|E0/|0A/)' { $r.Role = 'Network' }
            '^01/' { $r.Role = 'Audio' }
        }
    }
    return $rows
}

function Get-Ec20Transport {
    <#
    .SYNOPSIS
    Decides how to reach one role: a COM port (usbser) or ec20at.exe (WinUSB).
    #>
    [CmdletBinding()]
    param([ValidateSet('At', 'Modem', 'Nmea', 'Diag')][string]$Role = 'At')
    $i = @(Get-Ec20Interface | Where-Object { $_.Role -eq $Role }) | Select-Object -First 1
    if (-not $i) {
        throw "The EC20 $Role interface is not present. Is the module powered and enumerated (Get-PnpDevice -InstanceId 'USB\VID_2C7C&PID_0125*')?"
    }
    $mi = $i.MI
    if ($i.ComPort) {
        return [pscustomobject]@{ Kind = 'Serial'; Port = $i.ComPort; Role = $Role; Interface = $i }
    }
    if ($i.Service -and $i.Service -ieq 'WinUSB') {
        # ec20-winusb.inf names roles by interface number (QMI/MBIM layout).
        if ($i.MI -ne ('MI_{0:D2}' -f $Script:RoleMi[$Role])) {
            throw "$mi is the $Role port in this usbnet mode, but ec20-winusb.inf and ec20at.exe know only the QMI/MBIM layout. Use the usbser package (tools\Install-Ec20Driver.ps1 -Variant Usbser)."
        }
        $exe = Find-Ec20AtExe
        if (-not $exe) { throw "$mi is bound to WinUSB but ec20at.exe was not found next to the scripts." }
        return [pscustomobject]@{ Kind = 'WinUsb'; Port = $exe; Role = $Role; Interface = $i }
    }
    throw ("$mi has no COM port and is not bound to WinUSB (status '" + $i.Status + "', service '" + $i.Service + "'). Install one of the ec20-woa driver packages (tools\Install-Ec20Driver.ps1).")
}

function Find-Ec20AtExe {
    foreach ($p in @((Join-Path $PSScriptRoot 'ec20at.exe'), (Join-Path $PSScriptRoot 'bin\ec20at.exe'))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Protect-Ec20Text {
    param([string]$Text, [string[]]$Secret)
    if ($null -eq $Text) { return $Text }
    foreach ($s in $Secret) { if ($s) { $Text = $Text.Replace($s, '****') } }
    return $Text
}

function Test-Ec20Final {
    param([string]$Line)
    if ($Line -match '^(OK|CONNECT)( |$)') { return 'Ok' }
    if ($Line -match '^(ERROR|\+CME ERROR|\+CMS ERROR|NO CARRIER|BUSY|NO ANSWER|NO DIALTONE)') { return 'Error' }
    return $null
}

function Invoke-Ec20At {
    <#
    .SYNOPSIS
    Sends one AT command and returns the reply lines.
    .PARAMETER Secret
    Strings to replace with **** in everything printed or returned (a PIN).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [ValidateSet('At', 'Modem', 'Nmea', 'Diag')][string]$Role = 'At',
        [int]$TimeoutMs = 5000,
        [string[]]$Secret = @(),
        [switch]$Quiet
    )
    $t = Get-Ec20Transport -Role $Role
    $lines = New-Object System.Collections.Generic.List[string]
    $final = $null
    if ($t.Kind -eq 'Serial') {
        $sp = New-Object System.IO.Ports.SerialPort $t.Port, 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
        $sp.DtrEnable = $true
        $sp.RtsEnable = $true
        $sp.ReadTimeout = 200
        $sp.WriteTimeout = 2000
        try {
            $sp.Open()
        } catch {
            throw ("Opening " + $t.Port + " failed: " + $_.Exception.Message + " If usbser rejects the line-coding requests of this port, use the WinUSB package instead (README.md, 'If a port shows Code 10 or will not open').")
        }
        try {
            Start-Sleep -Milliseconds 100
            $sp.DiscardInBuffer()
            $sp.Write($Command + "`r")
            $buf = ''
            $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
            while (-not $final -and [DateTime]::UtcNow -lt $deadline) {
                $chunk = $sp.ReadExisting()
                if (-not $chunk) { Start-Sleep -Milliseconds 50; continue }
                $buf += $chunk
                while ($true) {
                    $m = [regex]::Match($buf, "\r\n|\n|\r")
                    if (-not $m.Success) { break }
                    $line = $buf.Substring(0, $m.Index).Trim()
                    $buf = $buf.Substring($m.Index + $m.Length)
                    if (-not $line -or $line -eq $Command) { continue }
                    $lines.Add($line)
                    $f = Test-Ec20Final $line
                    if ($f) { $final = $f; break }
                }
            }
        } finally {
            $sp.Close()
        }
    } else {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $t.Port
        # The command goes through stdin so that it never appears on a
        # command line (other processes can read command lines).
        $psi.Arguments = '-p ' + $Role.ToLowerInvariant() + ' -t ' + $TimeoutMs + ' -'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $errTask = $p.StandardError.ReadToEndAsync()
        $p.StandardInput.WriteLine($Command)
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        $err = $errTask.Result
        foreach ($l in ($out -split "`r?`n")) { if ($l.Trim()) { $lines.Add($l.Trim()) } }
        switch ($p.ExitCode) {
            0 { $final = 'Ok' }
            1 { $final = 'Error' }
            2 { $final = $null }
            default { throw ("ec20at.exe failed (exit " + $p.ExitCode + "): " + (Protect-Ec20Text $err.Trim() $Secret)) }
        }
    }
    $shown = Protect-Ec20Text $Command $Secret
    $safe = @($lines | ForEach-Object { Protect-Ec20Text $_ $Secret })
    if (-not $Quiet) {
        Write-Host ('> ' + $shown + '   [' + $t.Role + ' via ' + $t.Kind + ' ' + $(if ($t.Kind -eq 'Serial') { $t.Port } else { 'ec20at.exe' }) + ']')
        foreach ($l in $safe) { Write-Host ('  ' + $l) }
        if (-not $final) { Write-Host ('  (no final result code within ' + $TimeoutMs + ' ms)') }
    }
    [pscustomobject]@{
        Command = $shown
        Lines   = $safe
        Final   = $final
        Ok      = ($final -eq 'Ok')
    }
}

function Receive-Ec20Port {
    <#
    .SYNOPSIS
    Prints what a port sends for some seconds (for the NMEA port).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('At', 'Modem', 'Nmea', 'Diag')][string]$Role = 'Nmea',
        [int]$Seconds = 10
    )
    $t = Get-Ec20Transport -Role $Role
    if ($t.Kind -eq 'Serial') {
        $sp = New-Object System.IO.Ports.SerialPort $t.Port, 115200
        $sp.DtrEnable = $true
        $sp.RtsEnable = $true
        $sp.Open()
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
            while ([DateTime]::UtcNow -lt $deadline) {
                $chunk = $sp.ReadExisting()
                if ($chunk) { [Console]::Out.Write($chunk) } else { Start-Sleep -Milliseconds 100 }
            }
        } finally {
            $sp.Close()
        }
    } else {
        & $t.Port -p $Role.ToLowerInvariant() --listen $Seconds
    }
}

function Get-Ec20Registration {
    <#
    .SYNOPSIS
    Returns $true when +CREG or +CEREG reports registered (home 1, roaming 5).
    #>
    [CmdletBinding()]
    param([ValidateSet('At', 'Modem')][string]$Role = 'At')
    foreach ($c in 'AT+CEREG?', 'AT+CREG?') {
        $r = Invoke-Ec20At -Command $c -Role $Role -Quiet
        foreach ($l in $r.Lines) {
            if ($l -match '^\+C(E)?REG:\s*\d+\s*,\s*(\d+)') {
                if ($Matches[2] -eq '1' -or $Matches[2] -eq '5') { return $true }
            }
        }
    }
    return $false
}

function ConvertFrom-Ec20SecureString {
    param([Security.SecureString]$Value)
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

Export-ModuleMember -Function Get-Ec20Interface, Get-Ec20Transport, Invoke-Ec20At, Receive-Ec20Port, Get-Ec20Registration, ConvertFrom-Ec20SecureString, Protect-Ec20Text
