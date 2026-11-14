/*
 * ec20at: send AT commands to, and read NMEA from, a Quectel EC20/EC25
 * (USB 2C7C:0125) whose serial interfaces are bound to WinUSB by
 * inf/winusb/ec20-winusb.inf. No COM port is involved.
 *
 * Usage:
 *   ec20at [-p at|modem|nmea|diag] [-t MS] [--no-dtr] [-v] COMMAND
 *   ec20at [-p ROLE] [-t MS] -          read COMMAND from the first line of stdin
 *   ec20at -p nmea --listen SECONDS     print what the port sends, no command
 *   ec20at --list                       show which roles are present
 *
 * The command is sent with a trailing CR. Lines are printed as they arrive
 * until a final result code (OK, ERROR, +CME ERROR, +CMS ERROR, NO CARRIER,
 * BUSY, NO ANSWER, NO DIALTONE, CONNECT) or until the timeout. The echo of
 * the command itself is not printed, so a command read from stdin (a SIM
 * PIN, for example) does not appear in the output.
 *
 * Exit codes: 0 final result OK or CONNECT, 1 any other final result code,
 * 2 timeout without a final result code, 3 interface not found,
 * 4 usage error, 5 USB I/O error.
 *
 * SPDX-License-Identifier: MIT
 */

#define WIN32_LEAN_AND_MEAN
#define _CRT_SECURE_NO_WARNINGS
#include <windows.h>
#include <setupapi.h>
#include <winusb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Must match the DeviceInterfaceGUIDs in inf/winusb/ec20-winusb.inf. */
struct role {
    const char *name;
    int mi;
    GUID guid;
};

static const struct role roles[] = {
    { "diag",  0, { 0xB9951A67, 0x6973, 0x4FAF, { 0x8A, 0xF1, 0x63, 0x46, 0x2F, 0x73, 0x3E, 0xC3 } } },
    { "nmea",  1, { 0xAB461143, 0xC18E, 0x4250, { 0xA9, 0xE2, 0x9B, 0x2C, 0x99, 0x11, 0x0A, 0x39 } } },
    { "at",    2, { 0x9D19419D, 0x3DB7, 0x4E33, { 0xB1, 0x6C, 0xE4, 0xB3, 0x95, 0xAA, 0x31, 0xE0 } } },
    { "modem", 3, { 0x199F29DC, 0x376F, 0x490A, { 0xB4, 0x4D, 0x54, 0x7B, 0xB6, 0x2A, 0x69, 0x97 } } },
};

#define NROLES (sizeof(roles) / sizeof(roles[0]))

enum {
    EXIT_OK_RESULT = 0,
    EXIT_ERROR_RESULT = 1,
    EXIT_TIMEOUT = 2,
    EXIT_NOT_FOUND = 3,
    EXIT_USAGE = 4,
    EXIT_IO = 5,
};

static int verbose;

struct port {
    HANDLE file;
    WINUSB_INTERFACE_HANDLE usb;
    UCHAR ifnum;
    UCHAR pipe_in;
    UCHAR pipe_out;
    UCHAR pipe_int;
    UCHAR nep;
};

static const struct role *find_role(const char *name)
{
    size_t i;

    for (i = 0; i < NROLES; i++)
        if (_stricmp(roles[i].name, name) == 0)
            return &roles[i];
    return NULL;
}

/* Device path of the first present interface of this GUID, or NULL. */
static WCHAR *interface_path(const GUID *guid)
{
    HDEVINFO set;
    SP_DEVICE_INTERFACE_DATA ifd;
    PSP_DEVICE_INTERFACE_DETAIL_DATA_W detail = NULL;
    DWORD need = 0;
    WCHAR *path = NULL;

    set = SetupDiGetClassDevsW(guid, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE)
        return NULL;

    ifd.cbSize = sizeof(ifd);
    if (!SetupDiEnumDeviceInterfaces(set, NULL, guid, 0, &ifd))
        goto out;

    SetupDiGetDeviceInterfaceDetailW(set, &ifd, NULL, 0, &need, NULL);
    if (need == 0)
        goto out;
    detail = (PSP_DEVICE_INTERFACE_DETAIL_DATA_W)malloc(need);
    if (!detail)
        goto out;
    detail->cbSize = sizeof(*detail);
    if (!SetupDiGetDeviceInterfaceDetailW(set, &ifd, detail, need, NULL, NULL))
        goto out;
    path = _wcsdup(detail->DevicePath);
out:
    free(detail);
    SetupDiDestroyDeviceInfoList(set);
    return path;
}

static void port_close(struct port *p)
{
    if (p->usb)
        WinUsb_Free(p->usb);
    if (p->file && p->file != INVALID_HANDLE_VALUE)
        CloseHandle(p->file);
    memset(p, 0, sizeof(*p));
}

static int port_open(const struct role *r, struct port *p)
{
    WCHAR *path;
    USB_INTERFACE_DESCRIPTOR id;
    WINUSB_PIPE_INFORMATION pi;
    UCHAR i;

    memset(p, 0, sizeof(*p));
    path = interface_path(&r->guid);
    if (!path) {
        fprintf(stderr, "ec20at: no %s interface (MI_%02d) bound to WinUSB is present\n", r->name, r->mi);
        return EXIT_NOT_FOUND;
    }
    if (verbose)
        fprintf(stderr, "ec20at: %s: %ls\n", r->name, path);

    p->file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                          NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED, NULL);
    free(path);
    if (p->file == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "ec20at: CreateFile failed, error %lu (another program has the port open?)\n",
                GetLastError());
        p->file = NULL;
        return EXIT_IO;
    }
    if (!WinUsb_Initialize(p->file, &p->usb)) {
        fprintf(stderr, "ec20at: WinUsb_Initialize failed, error %lu\n", GetLastError());
        p->usb = NULL;
        port_close(p);
        return EXIT_IO;
    }
    if (!WinUsb_QueryInterfaceSettings(p->usb, 0, &id)) {
        fprintf(stderr, "ec20at: WinUsb_QueryInterfaceSettings failed, error %lu\n", GetLastError());
        port_close(p);
        return EXIT_IO;
    }
    p->ifnum = id.bInterfaceNumber;
    p->nep = id.bNumEndpoints;
    for (i = 0; i < id.bNumEndpoints; i++) {
        if (!WinUsb_QueryPipe(p->usb, 0, i, &pi))
            continue;
        if (pi.PipeType == UsbdPipeTypeBulk && USB_ENDPOINT_DIRECTION_IN(pi.PipeId) && !p->pipe_in)
            p->pipe_in = pi.PipeId;
        else if (pi.PipeType == UsbdPipeTypeBulk && USB_ENDPOINT_DIRECTION_OUT(pi.PipeId) && !p->pipe_out)
            p->pipe_out = pi.PipeId;
        else if (pi.PipeType == UsbdPipeTypeInterrupt && !p->pipe_int)
            p->pipe_int = pi.PipeId;
    }
    if (verbose)
        fprintf(stderr, "ec20at: interface %u, class %02X/%02X/%02X, %u endpoints, bulk in 0x%02X, bulk out 0x%02X, interrupt 0x%02X\n",
                p->ifnum, id.bInterfaceClass, id.bInterfaceSubClass, id.bInterfaceProtocol,
                p->nep, p->pipe_in, p->pipe_out, p->pipe_int);
    if (!p->pipe_in || !p->pipe_out) {
        fprintf(stderr, "ec20at: interface %u has no bulk IN/OUT pair\n", p->ifnum);
        port_close(p);
        return EXIT_IO;
    }
    {
        ULONG to = 2000;
        BOOL on = TRUE;

        WinUsb_SetPipePolicy(p->usb, p->pipe_out, PIPE_TRANSFER_TIMEOUT, sizeof(to), &to);
        /* A write that is a multiple of the packet size needs a ZLP. */
        WinUsb_SetPipePolicy(p->usb, p->pipe_out, SHORT_PACKET_TERMINATE, sizeof(on), &on);
    }
    return 0;
}

/*
 * CDC SET_CONTROL_LINE_STATE with DTR and RTS set, sent to the interface.
 * Linux sends the same request when it opens these ports (usb_wwan.c).
 */
static void port_set_dtr(struct port *p, int on)
{
    WINUSB_SETUP_PACKET sp;
    ULONG done = 0;

    sp.RequestType = 0x21; /* host to device, class, interface */
    sp.Request = 0x22;     /* SET_CONTROL_LINE_STATE */
    sp.Value = on ? 0x0003 : 0x0000;
    sp.Index = p->ifnum;
    sp.Length = 0;
    if (!WinUsb_ControlTransfer(p->usb, sp, NULL, 0, &done, NULL))
        fprintf(stderr, "ec20at: SET_CONTROL_LINE_STATE failed, error %lu (continuing)\n", GetLastError());
    else if (verbose)
        fprintf(stderr, "ec20at: DTR/RTS %s\n", on ? "on" : "off");
}

/* One read with a timeout. Returns bytes read, 0 on timeout, -1 on error. */
static int port_read(struct port *p, char *buf, ULONG len, ULONG timeout_ms)
{
    ULONG got = 0;

    WinUsb_SetPipePolicy(p->usb, p->pipe_in, PIPE_TRANSFER_TIMEOUT, sizeof(timeout_ms), &timeout_ms);
    if (!WinUsb_ReadPipe(p->usb, p->pipe_in, (PUCHAR)buf, len, &got, NULL)) {
        DWORD e = GetLastError();

        if (e == ERROR_SEM_TIMEOUT)
            return 0;
        fprintf(stderr, "ec20at: read failed, error %lu\n", e);
        return -1;
    }
    return (int)got;
}

static int is_final(const char *line, int *ok)
{
    static const char *const good[] = { "OK", "CONNECT" };
    static const char *const bad[] = { "ERROR", "+CME ERROR", "+CMS ERROR", "NO CARRIER",
                                       "BUSY", "NO ANSWER", "NO DIALTONE" };
    size_t i;

    for (i = 0; i < sizeof(good) / sizeof(good[0]); i++)
        if (strncmp(line, good[i], strlen(good[i])) == 0 &&
            (line[strlen(good[i])] == '\0' || line[strlen(good[i])] == ' ')) {
            *ok = 1;
            return 1;
        }
    for (i = 0; i < sizeof(bad) / sizeof(bad[0]); i++)
        if (strncmp(line, bad[i], strlen(bad[i])) == 0) {
            *ok = 0;
            return 1;
        }
    return 0;
}

/* Discard whatever is already queued (late replies, unsolicited codes). */
static void port_drain(struct port *p)
{
    char buf[4096];
    int n, i;

    for (i = 0; i < 50; i++) {
        n = port_read(p, buf, sizeof(buf), 50);
        if (n <= 0)
            return;
        if (verbose)
            fprintf(stderr, "ec20at: discarded %d stale bytes\n", n);
    }
}

static int do_command(struct port *p, const char *cmd, ULONG timeout_ms)
{
    char out[1024];
    char line[4096];
    char buf[4096];
    size_t ll = 0;
    ULONG done = 0;
    ULONGLONG deadline;
    size_t cl = strlen(cmd);
    int n, i, ok = 0;

    if (cl + 2 > sizeof(out)) {
        fprintf(stderr, "ec20at: command too long\n");
        return EXIT_USAGE;
    }
    memcpy(out, cmd, cl);
    out[cl++] = '\r';

    port_drain(p);
    if (!WinUsb_WritePipe(p->usb, p->pipe_out, (PUCHAR)out, (ULONG)cl, &done, NULL) || done != cl) {
        fprintf(stderr, "ec20at: write failed, error %lu\n", GetLastError());
        SecureZeroMemory(out, sizeof(out));
        return EXIT_IO;
    }
    SecureZeroMemory(out, sizeof(out));

    deadline = GetTickCount64() + timeout_ms;
    while (GetTickCount64() < deadline) {
        n = port_read(p, buf, sizeof(buf), 200);
        if (n < 0)
            return EXIT_IO;
        for (i = 0; i < n; i++) {
            char c = buf[i];

            if (c == '\r' || c == '\n') {
                if (ll == 0)
                    continue;
                line[ll] = '\0';
                ll = 0;
                if (strcmp(line, cmd) == 0)
                    continue; /* the echo of the command */
                printf("%s\n", line);
                fflush(stdout);
                if (is_final(line, &ok)) {
                    SecureZeroMemory(line, sizeof(line));
                    return ok ? EXIT_OK_RESULT : EXIT_ERROR_RESULT;
                }
            } else if (ll < sizeof(line) - 1) {
                line[ll++] = c;
            }
        }
    }
    if (ll) {
        line[ll] = '\0';
        if (strcmp(line, cmd) != 0)
            printf("%s\n", line);
    }
    SecureZeroMemory(line, sizeof(line));
    fprintf(stderr, "ec20at: no final result code within %lu ms\n", timeout_ms);
    return EXIT_TIMEOUT;
}

static int do_listen(struct port *p, unsigned seconds)
{
    char buf[4096];
    ULONGLONG deadline = GetTickCount64() + (ULONGLONG)seconds * 1000;
    int n;

    while (GetTickCount64() < deadline) {
        n = port_read(p, buf, sizeof(buf), 250);
        if (n < 0)
            return EXIT_IO;
        if (n > 0) {
            fwrite(buf, 1, (size_t)n, stdout);
            fflush(stdout);
        }
    }
    return 0;
}

static int do_list(void)
{
    size_t i;
    int found = 0;

    for (i = 0; i < NROLES; i++) {
        struct port p;
        WCHAR *path = interface_path(&roles[i].guid);

        if (!path) {
            printf("%-6s MI_%02d  not present\n", roles[i].name, roles[i].mi);
            continue;
        }
        free(path);
        found++;
        if (port_open(&roles[i], &p) == 0) {
            printf("%-6s MI_%02d  present, interface %u, %u endpoints, bulk in 0x%02X out 0x%02X, interrupt 0x%02X\n",
                   roles[i].name, roles[i].mi, p.ifnum, p.nep, p.pipe_in, p.pipe_out, p.pipe_int);
            port_close(&p);
        } else {
            printf("%-6s MI_%02d  present but could not be opened\n", roles[i].name, roles[i].mi);
        }
    }
    return found ? 0 : EXIT_NOT_FOUND;
}

static void usage(void)
{
    fprintf(stderr,
            "usage: ec20at [-p at|modem|nmea|diag] [-t MS] [--no-dtr] [-v] COMMAND\n"
            "       ec20at [-p ROLE] [-t MS] -            (command from stdin)\n"
            "       ec20at -p nmea --listen SECONDS\n"
            "       ec20at --list\n");
}

int main(int argc, char **argv)
{
    const struct role *r = find_role("at");
    const char *cmd = NULL;
    char stdin_cmd[1024];
    ULONG timeout_ms = 5000;
    unsigned listen = 0;
    int dtr = 1, list = 0, rc, i;
    struct port p;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-p") == 0 && i + 1 < argc) {
            r = find_role(argv[++i]);
            if (!r) {
                usage();
                return EXIT_USAGE;
            }
        } else if (strcmp(argv[i], "-t") == 0 && i + 1 < argc) {
            timeout_ms = strtoul(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--listen") == 0 && i + 1 < argc) {
            listen = (unsigned)strtoul(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--no-dtr") == 0) {
            dtr = 0;
        } else if (strcmp(argv[i], "--list") == 0) {
            list = 1;
        } else if (strcmp(argv[i], "-v") == 0) {
            verbose = 1;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage();
            return 0;
        } else if (!cmd) {
            cmd = argv[i];
        } else {
            usage();
            return EXIT_USAGE;
        }
    }

    if (list)
        return do_list();

    if (cmd && strcmp(cmd, "-") == 0) {
        size_t l;

        if (!fgets(stdin_cmd, sizeof(stdin_cmd), stdin)) {
            fprintf(stderr, "ec20at: no command on stdin\n");
            return EXIT_USAGE;
        }
        l = strlen(stdin_cmd);
        while (l && (stdin_cmd[l - 1] == '\n' || stdin_cmd[l - 1] == '\r'))
            stdin_cmd[--l] = '\0';
        cmd = stdin_cmd;
    }
    if (!cmd && !listen) {
        usage();
        return EXIT_USAGE;
    }

    rc = port_open(r, &p);
    if (rc)
        return rc;
    if (dtr)
        port_set_dtr(&p, 1);

    rc = 0;
    if (cmd && *cmd)
        rc = do_command(&p, cmd, timeout_ms);
    if (listen && (rc == 0 || !cmd))
        rc = do_listen(&p, listen);

    SecureZeroMemory(stdin_cmd, sizeof(stdin_cmd));
    port_close(&p);
    return rc;
}
