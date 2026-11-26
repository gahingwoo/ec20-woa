# ec20-woa

Driver packages and scripts for using a Quectel EC20 / EC25 LTE module
(USB `2C7C:0125`) under Windows 11 23H2 ARM64, without Quectel's Windows
driver. Written for the LCKFB TaishanPi 3M (Rockchip RK3576), where the
module sits on the board's USB bus, but nothing here is specific to that
board.

The repository contains no driver binary and nothing from Quectel. The two
INF files bind drivers that ship with Windows (`usbser.sys`, `winusb.sys`);
mobile data does not work yet (see "Mobile data").

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
| `ec20-ports.inf` 1.0 (usbser, MI_00..MI_03 by hardware ID) | measured in QMI mode: four COM ports, AT answers (one run); breaks RNDIS mode |
| `ec20-ports.inf` 2.0 (usbser, class FF/00/00 by compatible ID) | builds, signs; not yet on the board |
| `ec20-winusb.inf` + `ec20at.exe` | builds, signs; untested |
| PowerShell scripts | `Install-Ec20Driver`, `Send-Ec20At`, `Get-Ec20Status` run on the board; the others untested |
| MBIM mobile data (usbnet 2) | board-tested 2026-11-26: does not work, the module never answers MBIM OPEN |
| RNDIS mobile data (usbnet 3) | board-tested 2026-11-26: does not work, the adapter enumerates but forwards nothing |
| GNSS, call audio | AT sequences measured under Linux on this module; untested on Windows |

## The device

Measured under Windows (2026-11-14): `USB\VID_2C7C&PID_0125&REV_0318`,
"EC20-CE-FILG", bound to the inbox composite driver (usbccgp), firmware
EC20CEFILGR08A03M1G (from the same module under Linux).

| Function | Class/Sub/Proto | Role | Windows before this package | This package |
|---|---|---|---|---|
| MI_00 | FF/FF/FF | DM (diagnostic, Qualcomm DIAG) | no driver | WinUSB only (usbser 2.0 leaves DM unbound) |
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

## Interfaces per usbnet mode

The module renumbers its interfaces when its USB network mode
(`AT+QCFG="usbnet"`) changes. The serial ports keep their classes and their
order, not their numbers.

| MI | usbnet 0, QMI | usbnet 2, MBIM | usbnet 3, RNDIS |
|---|---|---|---|
| 00 | DM, FF/FF/FF | DM, FF/FF/FF | RNDIS control, E0/01/03 |
| 01 | NMEA, FF/00/00 | NMEA, FF/00/00 | RNDIS data, 0A/00/00 (same function as MI_00) |
| 02 | AT, FF/00/00 | AT, FF/00/00 | DM, FF/FF/FF |
| 03 | modem, FF/00/00 | modem, FF/00/00 | NMEA, FF/00/00 |
| 04 | QMI network, FF/FF/FF | MBIM control, 02/0E/00 | AT, FF/00/00 |
| 05 | audio, 01 | MBIM data, 0A (same function as MI_04) | modem, FF/00/00 |
| 06 | | audio, 01 | audio, 01 |

Measured (TaishanPi 3M, EC20CEFILGR08A03M1G): the QMI column
(2026-11-14); in MBIM mode MI_04 bound to `cxwmbclass` (2026-11-26); in
RNDIS mode the classes of MI_00 and MI_02..MI_06 (2026-11-26). Inferred:
MI_01 in RNDIS mode (no separate device appears, so Windows grouped it
with MI_00), the MBIM data interface and the audio position in MBIM mode,
and which of the RNDIS-mode FF/00/00 ports is AT: Quectel's Linux guide
puts the serial ports on interfaces 2 to 5 in ECM and RNDIS mode, in the
same order (DM, NMEA, AT, modem). ECM (usbnet 1) is expected to look like
the RNDIS column with a CDC ECM function (02/06) on MI_00; not measured,
and Windows 11 has no in-box CDC ECM driver.

How `ec20-ports.inf` picks the ports. A hardware ID such as
`USB\VID_2C7C&PID_0125&MI_00` names a number, and the number means DM in
one mode and RNDIS in another. A hardware-ID match also outranks every
compatible-ID match, so version 1.0 took the RNDIS function away from the
in-box RNDIS driver (`wceisvista.inf` matches
`USB\Class_E0&SubClass_01&Prot_03`); on the board MI_00 then failed to
start. Version 2.0 matches one compatible ID that carries the class:
`USB\COMPAT_VID_2c7c&Class_ff&SubClass_00&Prot_00`, which Windows
generates for each FF/00/00 interface of a VID 2C7C device. In every
column above that is exactly NMEA, AT and modem. Not bound, on purpose:

- DM (FF/FF/FF). In QMI mode the QMI network function is FF/FF/FF as well,
  and only the interface number, which moves, tells the two apart. DM is
  left without a driver (Device Manager shows it with code 28); nothing
  here uses it.
- The network functions keep their in-box class drivers (MBIM
  `cxwmbclass`, RNDIS `wceisvista`) or stay without one (QMI).

Side effects: the three ports share one name, "Quectel EC2x serial port
(usbser)", and the scripts tell them apart by order (lowest FF/00/00
interface NMEA, then AT, then modem). The match names the vendor, not the
product, so FF/00/00 interfaces of other Quectel modules get usbser.sys
too. `ec20-winusb.inf` still matches by number and is only right in QMI
and MBIM mode; `Install-Ec20Driver.ps1 -Variant WinUsb` refuses otherwise.

## Serial ports: what was chosen and why

Three ways to get the AT, NMEA, modem and diag interfaces working on ARM64
Windows without Quectel's driver were considered.

**(a) usbser.sys through an INF (by hardware ID in 1.0, by class since 2.0).**
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

Expected: Device Manager > Ports (COM & LPT) shows three "Quectel EC2x
serial port (usbser) (COMn)", and the script's table shows a COM port for
the Nmea, At and Modem roles (MI_01..MI_03 in QMI and MBIM mode, MI_03..MI_05
in RNDIS mode). DM and, in QMI mode, MI_04 stay without a driver. Audio is
unchanged. Upgrading from 1.0 is the same command: it removes the old
package (and the devices installed from it) before adding the new one.

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

## Mobile data: not working, keep the module in QMI mode

Keep the module in QMI mode (`AT+QCFG="usbnet",0`, the factory default)
until Quectel has firmware that works. Board-tested on 2026-11-26 with
firmware EC20CEFILGR08A03M1G:

- MBIM (`usbnet` 2): the MBIM function binds the in-box `cxwmbclass`, but
  the module never answers MBIM OPEN. No Cellular page, no data.
- RNDIS (`usbnet` 3): the RNDIS adapter enumerates but forwards nothing;
  `AT+QNETDEVCTL` and `AT$QCRMCALL` return ERROR.
- QMI (`usbnet` 0): Windows has no in-box QMI driver. Never bind MI_04
  (the QMI function) to anything in this mode.

Check the mode, and go back to QMI:

```powershell
.\tools\Set-Ec20UsbNet.ps1 -Query        # expect +QCFG: "usbnet",0
.\tools\Set-Ec20UsbNet.ps1 -Mode QMI     # asks for confirmation, then resets the module
```

The module replies ERROR to a usbnet set that does apply, so trust the
read-back after the reset (about 30 s), not the reply. The setting is
stored in the module, so Linux on the same board sees the same mode; from
Linux, `AT+QCFG="usbnet",0` on ttyUSB2 and then `AT+CFUN=1,1`.

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
inf/usbser/ec20-ports.inf     usbser.sys for the FF/00/00 ports (NMEA, AT, modem), any usbnet mode
inf/winusb/ec20-winusb.inf    winusb.sys for MI_00..MI_03, one interface GUID per role (QMI/MBIM only)
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
3. Endpoint counts of MI_01 to MI_03 (`ec20at.exe --list`).

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
