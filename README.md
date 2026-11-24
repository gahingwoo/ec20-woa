# ec20-woa

Driver packages and scripts for using a Quectel EC20 / EC25 LTE module
(USB `2C7C:0125`) under Windows 11 23H2 ARM64, without Quectel's Windows
driver. Written for the LCKFB TaishanPi 3M (Rockchip RK3576), where the
module sits on the board's USB bus, but nothing here is specific to that
board.

The repository contains no driver binary and nothing from Quectel. The two
INF files bind drivers that ship with Windows (`usbser.sys`, `winusb.sys`);
the mobile data path uses the inbox Mobile Broadband class driver.

## Status

First run on hardware, 2026-11-14, TaishanPi 3M, Windows 11 23H2 ARM64
(build 22631), module firmware EC20CEFILGR08A03M1G: with
`ec20-ports.inf` installed, `usbser.sys` started on all four interfaces
(MI_00 to MI_03, problem code 0) and they appeared as COM3 to COM6. The AT
port answered `AT` with `OK`, and `Get-Ec20Status.ps1` read the module's
identity, signal (`+CSQ: 22,99`) and serving cell. The module reported
`+CME ERROR: 10` to `AT+CPIN?` (no SIM seen) in that run, so nothing that
needs a SIM has been tried. One run, one board.

Everything not listed as measured in the table below is inferred from
Microsoft's documentation, the Linux kernel drivers for this module,
Quectel's Linux documentation and the module's behaviour under Linux on the
same board. Each section says which.

CI validates the INFs with `infverif`, builds catalogs with `inf2cat` for
the ARM64 Windows 10/11 versions up to 23H2, test-signs them, verifies the
signatures, builds `ec20at.exe` for ARM64, and checks that every script
parses in Windows PowerShell 5.1. That proves the package is well formed,
not that it works.

| Part | State |
|---|---|
| Device enumeration (below) | measured |
| `ec20-ports.inf` (usbser COM ports) | measured: four COM ports, AT answers (one run) |
| `ec20-winusb.inf` + `ec20at.exe` | builds, signs; untested |
| PowerShell scripts | `Install-Ec20Driver`, `Send-Ec20At`, `Get-Ec20Status` run on the board; the others untested |
| MBIM mobile data | `Set-Ec20UsbNet.ps1` checks each step; untested on Windows |
| GNSS, call audio | AT sequences measured under Linux on this module; untested on Windows |

## The device

Measured under Windows (2026-11-14): `USB\VID_2C7C&PID_0125&REV_0318`,
"EC20-CE-FILG", bound to the inbox composite driver (usbccgp), firmware
EC20CEFILGR08A03M1G (from the same module under Linux).

| Function | Class/Sub/Proto | Role | Windows before this package | This package |
|---|---|---|---|---|
| MI_00 | FF/FF/FF | DM (diagnostic, Qualcomm DIAG) | no driver | usbser or WinUSB |
| MI_01 | FF/00/00 | NMEA output of the GNSS receiver | no driver | usbser or WinUSB |
| MI_02 | FF/00/00 | AT commands | no driver | usbser or WinUSB |
| MI_03 | FF/00/00 | modem (AT commands, PPP) | no driver | usbser or WinUSB |
| MI_04 | FF/FF/FF | network, QMI/rmnet (factory default) | no driver | not bound |
| MI_05 | 01/00/00 | USB Audio (voice call PCM), enabled earlier | usbaudio, works | not touched |

The roles come from the Linux kernel (`drivers/usb/serial/qcserial.c`,
`handle_quectel_ec20`: "0: DM/DIAG, 1: NMEA, 2: AT-capable modem port,
3: Modem interface, 4: NDIS") and Quectel's *LTE&5G Linux USB Driver User
Guide* V2.0, Table 2 (ttyUSB0 DM, ttyUSB1 NMEA, ttyUSB2 AT, ttyUSB3 PPP or
AT, interface 4 the network adapter). Linux matches this PID by interface
class: `option.c` binds the FF/00/00 interfaces and the FF/FF/FF ones that
have exactly two endpoints (`NUMEP2`, which selects DIAG), and `qmi_wwan.c`
binds the FF/FF/FF interface that is not DIAG (`QMI_MATCH_FF_FF_FF`, whose
comment says the DIAG function "has exactly 2 endpoints"). So MI_00 has two
bulk endpoints and no interrupt endpoint. The endpoint counts of MI_01 to
MI_03 were not measured; `ec20at.exe --list` prints them.

## Serial ports: what was chosen and why

Three ways to get the AT, NMEA, modem and diag interfaces working on ARM64
Windows without Quectel's driver were considered.

**(a) usbser.sys through an INF that names the hardware IDs.**
Microsoft documents usbser.sys for CDC ACM devices: it loads by itself on
`USB\Class_02&SubClass_02`, and for any other class "you might need to
load your own driver or write an INF file that references another in-box
driver" ([USB serial driver (Usbser.sys)][usbser]). The EC20 interfaces are
vendor class, so an INF is needed. The current page no longer shows an INF
example for Windows 10 and later. The inbox `usbser.inf` itself marks its
install sections for reuse "via Include/Needs" (`UsbSerial_Install.NT`,
`.NT.Hw`, `.NT.Services`), which is what `ec20-ports.inf` does. The older
documented route, `Include=mdmcpq.inf` with usbser as a lower filter, does
not apply: `mdmcpq.inf` is not on the target install.

For: Linux treats these interfaces as CDC ACM in all the ways an AT port
needs. `usb_wwan.c` sends CDC `SET_CONTROL_LINE_STATE` to the interface
on open and close, and `option.c` (`option_instat_callback`) parses CDC
`SERIAL_STATE` notifications from the interrupt endpoint. The EC25 entries
in `option.c` are not marked `NCTRL`, which is the flag for interfaces that
reject those requests. A COM port works with every terminal program.

Against: Microsoft does not document how usbser.sys behaves on a single
vendor-class interface that has no CDC functional descriptors and no
separate data interface. It may refuse to start (Code 10). It also sends
`SET_LINE_CODING` and `GET_LINE_CODING`, which Linux never sends to these
interfaces, so whether the module accepts them is unknown. MI_00 has no
interrupt endpoint at all. I found no first-hand report, positive or
negative, of usbser.sys on EC20/EC25 ports; the search turned up only
requests for ARM64 drivers on Quectel's forum.

**(b) WinUSB through an INF, plus a user-mode tool.**
`winusb.sys` starts on any interface with bulk endpoints, regardless of
class, and Microsoft documents exactly this INF pattern
([WinUSB (Winusb.sys) installation][winusb]). It always gets the
interfaces working, but no COM port appears, so only programs that use the
WinUSB API can talk to them. `tools\ec20at.exe` (C, built for ARM64 in CI,
static CRT) sends AT commands and reads NMEA over WinUSB, and sends the
same `SET_CONTROL_LINE_STATE` (DTR and RTS on) that Linux sends.

**(c) An open-source serial driver for Qualcomm-style ports.**
No maintained open-source KMDF/UMDF driver for Qualcomm/Quectel serial
ports that builds for ARM64 was found. Writing one (a UMDF2 virtual serial
port over WinUSB) is possible but is a project of its own; it is the right
next step only if (a) fails and a real COM port is needed for third-party
software.

**Quectel's own driver.** Quectel's public Windows packages (for example
*Quectel_Windows_USB_Driver(Q)_NDIS* V2.8, listed for EC21/EC25/EG25-G and
others) require a Quectel account; the download page states no
architecture. On Quectel's forum, staff wrote in 2019 that Quectel "has
not released a formal Windows driver version for the ARM / ARM64
architecture", and in 2024 that "By default there is no arm64 win10
driver", sending one user a build made "for another customer"; users
report that the public packages are x86 and x64 only. (Forum posts, not
documentation.) An x64 kernel driver cannot load on ARM64
Windows: emulation covers user-mode code only (Microsoft's Windows on Arm
documentation; not re-read for this README). Quectel binaries cannot be
redistributed here in any case. If you obtain an ARM64 package from Quectel,
remove this repository's packages first (`Install-Ec20Driver.ps1 -Variant
None`), since both match the same hardware IDs.

**Decision.** Ship both (a) and (b) as separate driver packages, with
scripts that work over either. Try (a) first, because a COM port is what
everything else expects; if any port shows Code 10 or will not open, switch
to (b), which is expected to work but gives no COM port. The scripts pick
whichever transport is installed. Only one of the two packages should be
installed at a time; `Install-Ec20Driver.ps1` enforces that.

## Install

From the CI artifact `ec20-woa-arm64` (Actions tab, latest green run on
`main`), unpacked on the board. Test signing must be on (`bcdedit /set
testsigning on`); the packages contain no driver binary, but the catalogs
are signed with a certificate made for that CI run, which the install
script adds to the machine's Root and TrustedPublisher stores.

In an elevated Windows PowerShell, in the unpacked `ec20-woa-arm64` folder:

```powershell
Get-ChildItem -Recurse | Unblock-File
Set-ExecutionPolicy -Scope Process Bypass
.\tools\Install-Ec20Driver.ps1 -Variant Usbser -ImportCertificate
```

Expected: Device Manager > Ports (COM & LPT) shows "EC20 AT command port
(usbser) (COMn)", the same for the NMEA, modem and DM diagnostic ports,
and the script's table shows a COM port for MI_00 to MI_03. MI_04 stays
without a driver. MI_05 is unchanged.

Before installing, it is worth checking that the ARM64 `usbser.inf` has the
sections `ec20-ports.inf` names (they were read from an x64 copy):

```powershell
Select-String -Path C:\Windows\INF\usbser.inf -Pattern '^\[UsbSerial_Install'
```

Three lines are expected: `[UsbSerial_Install.NT]`,
`[UsbSerial_Install.NT.Hw]` and `[UsbSerial_Install.NT.Services]`.

## Test

```powershell
.\tools\Send-Ec20At.ps1 AT              # expect "OK"
.\tools\Send-Ec20At.ps1 ATI             # Quectel, EC20F (or EC25), Revision: ...
.\tools\Get-Ec20Status.ps1              # bindings, SIM, registration, signal
.\tools\Enter-Ec20SimPin.ps1            # prompts for the PIN; never echoed or logged
```

`Enter-Ec20SimPin.ps1` checks `AT+CPIN?` first, refuses to do anything if
the SIM wants its PUK, refuses if only one PIN attempt is left
(`AT+QPINC="SC"`), and makes exactly one attempt. The PIN is a
`SecureString`, replaced with `****` in all output including the modem's
echo, and passed to `ec20at.exe` on stdin rather than on a command line.

Any terminal program also works on the COM port (115200 8N1; the baud rate
does not matter on USB). Send `AT` followed by Enter (CR).

### If a port shows Code 10 or will not open

| Symptom | Likely meaning | Next step |
|---|---|---|
| Code 10 on MI_01..MI_03 | usbser.sys refused a vendor-class interface | WinUSB package |
| Code 10 on MI_00 only | usbser.sys needs an interrupt endpoint, which DIAG lacks | ignore MI_00, or WinUSB package |
| Port present, `Send-Ec20At.ps1` says "Opening COMn failed" | usbser started but the module rejects a line-coding request | WinUSB package |
| Port opens, no reply, "(no final result code)" | the module ignores the port until DTR, or the port is not the AT port | try `-Role Modem`; then WinUSB package with `ec20at.exe -v` |
| Code 52 (signature) | certificate not imported, or test signing off | rerun with `-ImportCertificate`; `bcdedit /enum` |
| The ports have no driver after install | a newer package for the same IDs (Quectel's, or the other variant) is in the store | `pnputil /enum-drivers`, `Install-Ec20Driver.ps1 -Variant None`, reinstall |

The WinUSB package:

```powershell
.\tools\Install-Ec20Driver.ps1 -Variant WinUsb
.\tools\ec20at.exe --list               # each role, interface number, endpoints
.\tools\ec20at.exe -v AT                # expect "OK"
.\tools\Send-Ec20At.ps1 AT              # the scripts now use ec20at.exe
```

Device Manager then lists "EC20 AT command port (WinUSB)" and the others
under Universal Serial Bus devices, with no COM numbers.

`ec20at.exe` exit codes: 0 final result `OK`/`CONNECT`, 1 another final
result (`ERROR`, `+CME ERROR`, ...), 2 timeout, 3 interface not found,
4 usage, 5 USB I/O error. Only one program can open a WinUSB interface at a
time.

Remove everything: `.\tools\Install-Ec20Driver.ps1 -Variant None`.

## Mobile data: MBIM

In the factory mode (`AT+QCFG="usbnet",0`) the network function MI_04 is
QMI (FF/FF/FF). Windows has no inbox QMI driver, so MI_04 stays a device
with a yellow mark (code 28). No INF in this repository binds it, on
purpose: an INF for `USB\VID_2C7C&PID_0125&MI_04`, even a null one, would
also win over the inbox MBIM driver after a switch to MBIM, because the
hardware ID is the same in both modes and a hardware-ID match outranks the
class match the MBIM driver uses. The way to a working MI_04 is MBIM.

Quectel's Windows NDIS/QMI driver is not an option: Quectel staff wrote in
2024 that ARM64 Windows drivers are not released by default ("For special
customers, please create a ticket"), the downloads need a Quectel account,
and nothing in them may be redistributed here.

### What changes in MBIM mode

`AT+QCFG="usbnet",2` (then `AT+CFUN=1,1` or a power cycle) turns the
network function into CDC MBIM. Windows has an inbox driver for that, the
Mobile Broadband class driver (`wmbclass.sys`, `netwmbclass.inf`), which
binds by class, not by VID/PID.

| | QMI (0) | MBIM (2) | Source |
|---|---|---|---|
| USB ID | 2C7C:0125 | 2C7C:0125 (unchanged) | a published lsusb of an EG25-G in MBIM mode; Linux matches the serial ports by interface class only |
| MI_00..MI_03 (DM, NMEA, AT, modem) | FF class, COM ports | the same numbers and classes, so `ec20-ports.inf` keeps matching and the COM numbers stay | the same lsusb; Quectel's Linux guide (option.c skips every interface that is not class FF) |
| Network | MI_04 FF/FF/FF (QMI) | MI_04 02/0E/00 (MBIM control) + MI_05 0A/00/02 (MBIM data) | the same lsusb |
| USB Audio (UAC) | MI_05 | expected to move up to MI_06 and above, a new device that the inbox usbaudio driver installs by itself; not measured | inferred |

Not known until measured on this module: whether the firmware groups the
two MBIM interfaces with an Interface Association Descriptor. Windows'
composite driver (usbccgp) puts them together into one function only with an
IAD (or a Microsoft OS descriptor, which this module does not have). With an
IAD, Device Manager shows one "MI_04" function that wmbclass binds; without
one, MI_04 and MI_05 appear separately and the MBIM driver cannot start.
Qualcomm's MBIM gadget function, which this generation of Quectel firmware
is built on, does declare an IAD, so the first case is expected.
`Set-Ec20UsbNet.ps1` reports which one happened.

Also not known: whether firmware EC20CEFILGR08A03M1G accepts `usbnet,2`
at all (an EC25-AU needed a firmware update before it did). The script reads
the value back before and after the reset and stops if it did not stick.

### What MBIM does not change, and what it does

- AT, GNSS (NMEA) and voice calls stay on the serial ports; Windows' MBIM
  stack has no call control, so calls are made with AT commands as before
  ("Voice call audio" below), and their audio stays on UAC.
- Windows manages the modem through MBIM once wmbclass binds (WWAN AutoConfig,
  `WwanSvc`): it asks for the SIM PIN, turns the radio off in airplane mode,
  and **may write APNs into the module's profile table** (provisioned
  contexts persist across power cycles by specification). Linux on the same
  board can then see a different default APN.
- Data over Cellular may be metered by the SIM. Windows shows the connection
  as cellular and connects automatically unless that is turned off in
  Settings > Network & internet > Cellular.

### Switching (on Windows)

Check first that the inbox driver is present:

```powershell
Get-ChildItem C:\Windows\System32\DriverStore\FileRepository -Filter 'netwmbclass.inf_*' |
    ForEach-Object { Get-ChildItem $_.FullName -Filter wmbclass.sys }
Get-Service WwanSvc
```

Then, with the AT port's COM number (COM6 on the TaishanPi 3M test board):

```powershell
.\tools\Set-Ec20UsbNet.ps1 -Query -Port COM6     # usbnet 0 today, and the USB functions
.\tools\Set-Ec20UsbNet.ps1 -Mode MBIM -Port COM6 # asks, sets, reads back, resets, waits, reads back, checks
```

The same by hand, on any terminal at 115200 8N1 on the AT port:

```
AT+QCFG="usbnet"         -> +QCFG: "usbnet",0   OK
AT+QCFG="usbnet",2       -> OK
AT+QCFG="usbnet"         -> +QCFG: "usbnet",2   OK   (read back before the reset)
AT+CFUN=1,1              -> the module resets, the COM ports vanish for 20 to 40 s
AT+QCFG="usbnet"         -> +QCFG: "usbnet",2   OK   (after it is back)
```

Pass: the script ends with "MBIM is bound to wmbclass" and exit code 0;
Device Manager > Network adapters lists a mobile broadband adapter; Settings
> Network & internet shows **Cellular**; `netsh mbn show interfaces` lists one
interface. Exit code 4 with "two separate functions" means no IAD: switch
back.

Switching back to the factory mode:

```powershell
.\tools\Set-Ec20UsbNet.ps1 -Mode QMI -Port COM6
```

or by hand `AT+QCFG="usbnet",0`, read back, `AT+CFUN=1,1`.

### Effect on Linux on the same board

The mode lives in the module, so Linux sees MBIM too until it is switched
back. From the kernel tables: `qmi_wwan` no longer binds (there is no
FF/FF/FF network interface), `cdc_mbim` binds by class, and `option` still
creates ttyUSB0 to ttyUSB3 on interfaces 0 to 3. Udev rules keyed on
interface numbers 02 and 03 (the TaishanPi 3M voice service on ttyUSB3)
keep working, and the call-audio sequence (`AT+QPCMV=1,2` after
registration) is AT, unaffected by the mode.

ModemManager supports MBIM modems and its Quectel plugin handles MBIM.
In MBIM mode, MM's voice support comes from its generic AT implementation on
ttyUSB2 rather than from QMI's voice service, so GNOME Calls should still
place and receive calls, by a different path; this has not been tried on
this board. A ModemManager maintainer noted in 2020 that an EC25 in MBIM
mode does not support MM's initial EPS bearer settings, which matters for a
VoLTE-only SIM if the attach APN must be set from Linux. If anything on
Linux breaks, switch back from Linux: `AT+QCFG="usbnet",0` on ttyUSB2, read
it back, then `AT+CFUN=1,1`.

## GNSS

```powershell
.\tools\Start-Ec20Gnss.ps1                 # AT+QGPS=1, then 30 s of NMEA from MI_01
.\tools\Start-Ec20Gnss.ps1 -ListenSeconds 0 -Location   # AT+QGPSLOC=2
.\tools\Start-Ec20Gnss.ps1 -Stop           # AT+QGPSEND
```

NMEA appears on MI_01 (`AT+QGPSCFG="outport"` should read `"usbnmea"`).
A cold start needs an antenna with sky view and can take minutes. With the
usbser package, MI_01 is also an ordinary COM port that GNSS software can
open. Windows' own location service does not read NMEA from a COM port
without a GNSS driver; that is not provided here.

## Voice call audio

Calls are handled by the module; Windows only carries the audio, through the
USB Audio function MI_05, which already works as a speaker and microphone.
The module must be told to route call audio there with `AT+QPCMV=1,2`.

Measured on this module under Linux (2026-11-10): when the first
`AT+QPCMV=1,2` of a boot is sent before network registration, the module
answers `OK` and reads back `1,2`, but every call in that boot is silent,
and sending it again later in the same boot does not help. Sent after
registration plus about 20 seconds, calls had audio (8 of 8 calls over 3
boots). `Enable-Ec20CallAudio.ps1` therefore waits for `+CREG`/`+CEREG` to
report registered, waits 20 more seconds, then sends it, on the modem port
(MI_03) by default.

```powershell
.\tools\Enable-Ec20CallAudio.ps1
.\tools\Send-Ec20At.ps1 -Role Modem 'ATD<number>;'   # dial a voice call (note the ;)
.\tools\Send-Ec20At.ps1 -Role Modem 'AT+CLCC'        # list calls
.\tools\Send-Ec20At.ps1 -Role Modem 'ATA'            # answer
.\tools\Send-Ec20At.ps1 -Role Modem 'ATH'            # hang up
```

Then pick the EC20's speaker and microphone endpoints in Windows sound
settings, or play and record them in an audio program. A dialer is out of
scope. On the SIM used during the Linux tests (VoLTE only), Linux also
enabled IMS before QPCMV; if calls fail to connect on Windows, that is the
first difference to look at.

## Repository layout

```
inf/usbser/ec20-ports.inf     usbser.sys for MI_00..MI_03 (COM ports)
inf/winusb/ec20-winusb.inf    winusb.sys for MI_00..MI_03, one interface GUID per role
tools/ec20at/ec20at.c         AT and NMEA over WinUSB
tools/Ec20.psm1               shared helpers: find ports, send AT, redact secrets
tools/*.ps1                   install, status, PIN, usbnet mode, GNSS, call audio
.github/workflows/ci.yml      validation, catalogs, test signing, ARM64 build
INSTALL.txt                   short version of the above, shipped in the artifact
```

## Open questions

1. Does usbser.sys start on MI_01 to MI_03, and on MI_00 (no interrupt
   endpoint)? Does the module accept `SET_LINE_CODING`?
2. Does the AT port answer without DTR? (`ec20at.exe --no-dtr AT`)
3. After `usbnet,2`: whether this firmware accepts it, whether it declares
   an IAD for MBIM, where UAC moves, and whether Windows brings up the
   Cellular page.
4. Endpoint counts of MI_01 to MI_03 (`ec20at.exe --list`).

## Licence

MIT, see `LICENSE`. Nothing from Quectel is included: no binaries, no INF
text, no documentation text beyond short quotes cited above. "Quectel",
"EC20" and "EC25" name the hardware this is for; this project is not
affiliated with or endorsed by Quectel.

## Sources

- Microsoft, [USB serial driver (Usbser.sys)][usbser]
- Microsoft, [WinUSB (Winusb.sys) installation for developers][winusb]
- Linux kernel: `drivers/usb/serial/option.c`, `drivers/usb/serial/usb_wwan.c`,
  `drivers/usb/serial/qcserial.c`, `drivers/net/usb/qmi_wwan.c`
- Quectel, [LTE&5G Linux USB Driver User Guide V2.0][qlinux] (Tables 2 and 4, section 3.2.5)
- Quectel, [Windows USB Driver (Q) NDIS V2.8 download page][qndis]
- Quectel forum (not documentation): [EG25-G on Windows 10 ARM64][qf1],
  [EC200A & EC2x on Windows 11 ARM64][qf2], [Windows IoT Core driver for ARM and ARM64][qf3],
  [EM06-E on Windows 10 IoT ARM64][qf4]

[usbser]: https://learn.microsoft.com/windows-hardware/drivers/usbcon/usb-driver-installation-based-on-compatible-ids
[winusb]: https://learn.microsoft.com/windows-hardware/drivers/usbcon/winusb-installation
[qlinux]: https://sixfab.com/wp-content/uploads/2020/12/Quectel_LTE5G_Linux_USB_Driver_User_Guide_V2.0.pdf
[qndis]: https://www.quectel.com/download/quectel_windows_usb_driverq_ndis_v2-8_en/
[qf1]: https://forums.quectel.com/t/need-help-for-quectel-lte-eg25-g-usb-windows-10-arm64-device-driver-for-raspberry-pi-4b/27687
[qf2]: https://forums.quectel.com/t/need-help-for-quectel-ec200a-ec2x-series-usb-windows-11-arm64-device-driver-for-qualcomm-sc7180/30069
[qf3]: https://forums.quectel.com/t/windows-iot-core-driver-for-arm-and-arm64/2936
[qf4]: https://forums.quectel.com/t/looking-for-em06-e-usb-driver-for-windows-10-iot-arm64/33670
