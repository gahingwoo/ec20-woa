<#
.SYNOPSIS
Installs one of the two ec20-woa driver packages, removing the other first.

.DESCRIPTION
  -Variant Usbser   driver\usbser\ec20-ports.inf  (COM ports, usbser.sys)
  -Variant WinUsb   driver\winusb\ec20-winusb.inf (no COM ports, ec20at.exe)
  -Variant None     removes both
Both packages match the same hardware IDs, so only one may be in the driver
store at a time; otherwise Windows picks between them by date and version.

-ImportCertificate adds the package's test certificate (ec20-woa-test.cer)
to the machine's Root and TrustedPublisher stores. Needed once per CI build,
because each CI run signs with a new certificate.

Run from an elevated Windows PowerShell.

.EXAMPLE
.\Install-Ec20Driver.ps1 -Variant Usbser -ImportCertificate
.\Install-Ec20Driver.ps1 -Variant WinUsb
.\Install-Ec20Driver.ps1 -Variant None

.NOTES
Windows PowerShell 5.1 compatible. SPDX-License-Identifier: MIT
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Usbser', 'WinUsb', 'None')][string]$Variant,
    [string]$PackageRoot = '',
    [switch]$ImportCertificate
)
$ErrorActionPreference = 'Stop'
# Not as the parameter's default: under powershell.exe -File on Windows
# PowerShell 5.1 $PSScriptRoot is still empty while defaults are bound.
if (-not $PackageRoot) { $PackageRoot = Join-Path $PSScriptRoot '..' }
Import-Module (Join-Path $PSScriptRoot 'Ec20.psm1') -Force

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Run this from an elevated (Administrator) Windows PowerShell.' }

$root = (Resolve-Path -LiteralPath $PackageRoot).Path
if ($ImportCertificate) {
    $cer = Join-Path $root 'ec20-woa-test.cer'
    if (-not (Test-Path -LiteralPath $cer)) { throw ('Not found: ' + $cer) }
    & certutil.exe -f -addstore Root $cer | Out-Null
    if ($LASTEXITCODE) { throw 'certutil -addstore Root failed.' }
    & certutil.exe -f -addstore TrustedPublisher $cer | Out-Null
    if ($LASTEXITCODE) { throw 'certutil -addstore TrustedPublisher failed.' }
    Write-Host 'Test certificate added to Root and TrustedPublisher.'
}

# Remove every ec20-woa package already in the driver store.
$old = @(Get-WindowsDriver -Online | Where-Object {
        $_.OriginalFileName -like '*\ec20-ports.inf' -or $_.OriginalFileName -like '*\ec20-winusb.inf' })
foreach ($d in $old) {
    Write-Host ('Removing ' + $d.Driver + ' (' + (Split-Path $d.OriginalFileName -Leaf) + ')')
    & pnputil.exe /delete-driver $d.Driver /uninstall /force
    if ($LASTEXITCODE) { Write-Warning ('pnputil /delete-driver ' + $d.Driver + ' exited ' + $LASTEXITCODE) }
}

if ($Variant -ne 'None') {
    $inf = if ($Variant -eq 'Usbser') { Join-Path $root 'driver\usbser\ec20-ports.inf' } else { Join-Path $root 'driver\winusb\ec20-winusb.inf' }
    if (-not (Test-Path -LiteralPath $inf)) { throw ('Not found: ' + $inf) }
    & pnputil.exe /add-driver $inf /install
    # 259 = ERROR_NO_MORE_ITEMS: added, but no device needed updating.
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 259 -and $LASTEXITCODE -ne 3010) { throw ('pnputil /add-driver exited ' + $LASTEXITCODE) }
}
& pnputil.exe /scan-devices | Out-Null
Start-Sleep -Seconds 3
Get-Ec20Interface | Sort-Object MI | Format-Table MI, Role, Status, Service, ComPort, Name -AutoSize
