// PaneLink for Windows — agent (control server) + viewer (fullscreen low-latency decoder).
//
//   panelink.exe            -> agent: listens on TCP 49500 (control) + UDP 49500 (discovery), spawns one viewer per streamed monitor
//   panelink.exe view <device> <port> <codec> [vsync]
//
// Viewer pipeline (zero CPU copies): UDP -> FEC reassembly -> D3D11VA decode on the GPU that
// owns the target monitor -> GPU copy -> NV12->RGB shader -> flip-model swapchain, Present(0,
// ALLOW_TEARING) so frames hit the screen immediately (independent flip, no DWM composition).

#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#define INITGUID
#define _CRT_RAND_S
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <windows.h>
#include <mmsystem.h>
#include <d3d11.h>
#include <dxgi1_6.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <wchar.h>
#include <ctype.h>
#include <tlhelp32.h>
#include <sddl.h>
#include <wtsapi32.h>
#include <winhttp.h>
#include <wincodec.h>

#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_d3d11va.h>

#define CONTROL_PORT 49500
#define PAYLOAD 1400
#define MAX_PKTS 8192
#define SLOTS 8
#define MAX_MON 16

// ---------------------------------------------------------------------------------------------
// logging

static FILE *g_log;
static char g_role[32] = "agent";

static void log_open(const char *role) {
    snprintf(g_role, sizeof g_role, "%s", role);
    char dir[MAX_PATH], path[MAX_PATH];
    DWORD n = GetEnvironmentVariableA("ProgramData", dir, sizeof dir);
    if (!n) strcpy(dir, "C:\\ProgramData");
    strcat(dir, "\\PaneLink");
    CreateDirectoryA(dir, NULL);
    snprintf(path, sizeof path, "%s\\%s.log", dir, role);
    char old[MAX_PATH]; snprintf(old, sizeof old, "%s\\%s.old.log", dir, role);
    MoveFileExA(path, old, MOVEFILE_REPLACE_EXISTING);   // keep the previous run for diagnosis
    g_log = fopen(path, "w");
}

static void plog(const char *fmt, ...) {
    if (!g_log) return;
    SYSTEMTIME t; GetLocalTime(&t);
    fprintf(g_log, "%02d:%02d:%02d.%03d ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    va_list ap; va_start(ap, fmt); vfprintf(g_log, fmt, ap); va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
}

static double g_qpf;
static double now_us(void) {
    LARGE_INTEGER c; QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1e6 / g_qpf;
}

// ---------------------------------------------------------------------------------------------
// monitor enumeration

typedef struct {
    wchar_t device[32];    // \\.\DISPLAY1
    wchar_t friendly[64];
    int x, y, w, h, hz, primary;
} Monitor;

static Monitor g_mons[MAX_MON];
static int g_nmons;

static void friendly_name(const wchar_t *gdi, wchar_t *out, int outlen) {
    wcsncpy(out, gdi, outlen);
    UINT32 np = 0, nm = 0;
    if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &np, &nm) != ERROR_SUCCESS) return;
    DISPLAYCONFIG_PATH_INFO *paths = calloc(np, sizeof *paths);
    DISPLAYCONFIG_MODE_INFO *modes = calloc(nm, sizeof *modes);
    if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &np, paths, &nm, modes, NULL) == ERROR_SUCCESS) {
        for (UINT32 i = 0; i < np; i++) {
            DISPLAYCONFIG_SOURCE_DEVICE_NAME src = {0};
            src.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
            src.header.size = sizeof src;
            src.header.adapterId = paths[i].sourceInfo.adapterId;
            src.header.id = paths[i].sourceInfo.id;
            if (DisplayConfigGetDeviceInfo(&src.header) != ERROR_SUCCESS) continue;
            if (wcscmp(src.viewGdiDeviceName, gdi) != 0) continue;
            DISPLAYCONFIG_TARGET_DEVICE_NAME tgt = {0};
            tgt.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
            tgt.header.size = sizeof tgt;
            tgt.header.adapterId = paths[i].targetInfo.adapterId;
            tgt.header.id = paths[i].targetInfo.id;
            if (DisplayConfigGetDeviceInfo(&tgt.header) == ERROR_SUCCESS && tgt.monitorFriendlyDeviceName[0])
                wcsncpy(out, tgt.monitorFriendlyDeviceName, outlen);
            break;
        }
    }
    free(paths); free(modes);
}

static BOOL CALLBACK mon_cb(HMONITOR hm, HDC dc, LPRECT r, LPARAM lp) {
    (void)dc; (void)r; (void)lp;
    if (g_nmons >= MAX_MON) return FALSE;
    MONITORINFOEXW mi = {0}; mi.cbSize = sizeof mi;
    GetMonitorInfoW(hm, (MONITORINFO *)&mi);
    DEVMODEW dm = {0}; dm.dmSize = sizeof dm;
    EnumDisplaySettingsW(mi.szDevice, ENUM_CURRENT_SETTINGS, &dm);
    Monitor *m = &g_mons[g_nmons++];
    wcsncpy(m->device, mi.szDevice, 32);
    m->x = mi.rcMonitor.left; m->y = mi.rcMonitor.top;
    m->w = mi.rcMonitor.right - mi.rcMonitor.left; m->h = mi.rcMonitor.bottom - mi.rcMonitor.top;
    m->hz = (int)dm.dmDisplayFrequency;
    m->primary = (mi.dwFlags & MONITORINFOF_PRIMARY) != 0;
    friendly_name(mi.szDevice, m->friendly, 64);
    return TRUE;
}

static void enum_monitors(void) {
    g_nmons = 0;
    EnumDisplayMonitors(NULL, NULL, mon_cb, 0);
}

// ---------------------------------------------------------------------------------------------
// agent (Windows service, LocalSystem)
//
// Runs in session 0 from boot, so it works whether the user is logged in, unlocked or locked.
// Everything that touches the screen runs as SYSTEM inside the active console session: monitor
// enumeration ("list" helper) and the viewers, which follow the input desktop (Default <-> Winlogon).

typedef struct { HANDLE proc, stopEvent; int active; int port, hz, vsync, autostop, power, mousePx, graceMs, gpuMHz, ins[4]; char codec[16]; } Viewer;
static Viewer g_viewers[MAX_MON];
static CRITICAL_SECTION g_vlock;
static volatile SOCKET g_client = INVALID_SOCKET;
// Seamless reconnects: when the controller drops, viewers keep showing the (still flowing) UDP video
// for a grace period; a reconnect that re-sends the same START is a no-op.
#define ORPHAN_GRACE_MS 15000
static volatile ULONGLONG g_orphanSince;
static HANDLE g_hotkeyEvent;      // set by a viewer when Ctrl+Alt+Shift+F12 is pressed
static HANDLE g_activityEvent;    // set by a viewer when someone starts using this PC
static HANDLE g_serviceStop;
static SERVICE_STATUS_HANDLE g_svc;

// Starts `cmd` as SYSTEM in the active console session (works on the lock screen and with nobody
// logged in). Optional stdout pipe for the "list" helper.
static int spawn_console(wchar_t *cmd, PROCESS_INFORMATION *pi, HANDLE *stdoutRead) {
    HANDLE tok = NULL, dup = NULL;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ALL_ACCESS, &tok)) return 0;
    BOOL ok = DuplicateTokenEx(tok, MAXIMUM_ALLOWED, NULL, SecurityIdentification, TokenPrimary, &dup);
    CloseHandle(tok);
    if (!ok) return 0;
    DWORD session = WTSGetActiveConsoleSessionId();
    SetTokenInformation(dup, TokenSessionId, &session, sizeof session);  // no-op when not a service
    STARTUPINFOW si = {0}; si.cb = sizeof si;
    si.lpDesktop = L"winsta0\\default";
    HANDLE wr = NULL;
    if (stdoutRead) {
        SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
        CreatePipe(stdoutRead, &wr, &sa, 0);
        SetHandleInformation(*stdoutRead, HANDLE_FLAG_INHERIT, 0);
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdOutput = wr; si.hStdError = wr; si.hStdInput = NULL;
    }
    wchar_t exe[MAX_PATH]; GetModuleFileNameW(NULL, exe, MAX_PATH);
    ok = CreateProcessAsUserW(dup, exe, cmd, NULL, NULL, stdoutRead != NULL, HIGH_PRIORITY_CLASS | CREATE_NO_WINDOW,
                              NULL, NULL, &si, pi);
    if (!ok) plog("CreateProcessAsUser failed %lu (session %lu)", GetLastError(), session);
    if (wr) CloseHandle(wr);
    CloseHandle(dup);
    return ok;
}

// Monitor list as seen from the console session ("MON ..." protocol lines from the helper).
static void enum_monitors_console(void) {
    wchar_t exe[MAX_PATH], cmd[MAX_PATH + 16];
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    swprintf(cmd, MAX_PATH + 16, L"\"%ls\" list", exe);
    PROCESS_INFORMATION pi; HANDLE rd;
    if (!spawn_console(cmd, &pi, &rd)) return;
    char buf[8192]; DWORD total = 0, n;
    while (total < sizeof buf - 1 && ReadFile(rd, buf + total, sizeof buf - 1 - total, &n, NULL) && n) total += n;
    buf[total] = 0;
    WaitForSingleObject(pi.hProcess, 3000);
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread); CloseHandle(rd);
    g_nmons = 0;
    for (char *line = strtok(buf, "\n"); line && g_nmons < MAX_MON; line = strtok(NULL, "\n")) {
        Monitor *m = &g_mons[g_nmons];
        int idx, consumed = 0; char dev[64];
        if (sscanf(line, "MON %d %d %d %d %d %d %d %63s %n", &idx, &m->x, &m->y, &m->w, &m->h, &m->hz, &m->primary, dev, &consumed) < 8) continue;
        MultiByteToWideChar(CP_UTF8, 0, dev, -1, m->device, 32);
        char *fr = line + consumed; fr[strcspn(fr, "\r")] = 0;
        MultiByteToWideChar(CP_UTF8, 0, fr, -1, m->friendly, 64);
        g_nmons++;
    }
    plog("console session has %d monitors", g_nmons);
}

// Power while extending: the PC only decodes video then. Bit 1 = quiet fans (FanControl, via the
// hook scripts fans-quiet.cmd / fans-normal.cmd next to the logs, so the fan software can change
// without a rebuild; its quiet profile still ramps on temperature). Bit 2 = cap the GPU core clock
// (nvidia-smi -lgc; decode + one shader pass needs a fraction of it). Everything is undone when the
// last viewer goes, and at agent start/stop, so a crash can't leave the PC throttled.
static HANDLE g_dashProc;               // Morning dashboard helper (see dash_start)
static int g_dashPower;
static ULONGLONG g_dashShutdownAt;
#define DASH_GPU_MHZ 900
static int dash_live(void);
static int g_powerMode = -1;            // what we last asked for: -1 unknown (forces a reset at startup)
static volatile LONG g_powerWant = -1;  // handed to the worker, which runs the tools off the command path
static HANDLE g_powerEvent;
#define NVSMI L"C:\\Windows\\System32\\nvidia-smi.exe"

static int run_wait(wchar_t *cmd, DWORD ms) {
    STARTUPINFOW si = {sizeof si}; PROCESS_INFORMATION pi;
    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) return -1;
    DWORD w = WaitForSingleObject(pi.hProcess, ms), code = 1;
    if (w != WAIT_OBJECT_0) TerminateProcess(pi.hProcess, 1);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
    return w == WAIT_OBJECT_0 ? (int)code : -1;
}

static int fans_configured(void) {
    return GetFileAttributesW(L"C:\\ProgramData\\PaneLink\\fans-quiet.cmd") != INVALID_FILE_ATTRIBUTES &&
           GetFileAttributesW(L"C:\\ProgramData\\PaneLink\\fans-normal.cmd") != INVALID_FILE_ATTRIBUTES;
}
static int gpu_tool(void) { return GetFileAttributesW(NVSMI) != INVALID_FILE_ATTRIBUTES; }

static void power_apply_now(int mode, int prev) {
    wchar_t cmd[MAX_PATH + 64];
    if ((prev < 0 || ((mode ^ prev) & 1)) && fans_configured()) {
        swprintf(cmd, MAX_PATH + 64, L"cmd.exe /c \"C:\\ProgramData\\PaneLink\\fans-%ls.cmd\"", (mode & 1) ? L"quiet" : L"normal");
        int r = run_wait(cmd, 20000);
        plog("power: fans %s (%s)", (mode & 1) ? "quiet" : "normal", r == 0 ? "ok" : "hook failed");
    }
    if ((prev < 0 || ((mode ^ prev) & ~1)) && gpu_tool()) {   // GPU bit or its clock limit changed
        int mhz = mode >> 4;
        if (mode & 2) swprintf(cmd, MAX_PATH + 64, L"\"%ls\" -lgc 210,%d", NVSMI, mhz);
        else swprintf(cmd, MAX_PATH + 64, L"\"%ls\" -rgc", NVSMI);
        int r = run_wait(cmd, 10000);
        if (mode & 2) plog("power: gpu capped 210-%d MHz (%s)", mhz, r == 0 ? "ok" : "nvidia-smi failed");
        else plog("power: gpu clocks reset (%s)", r == 0 ? "ok" : "nvidia-smi failed");
    }
}

// Applies only the newest request, so quick on/off/on never leaves the PC in a stale mode.
static DWORD WINAPI power_worker(void *arg) {
    (void)arg;
    int applied = -1;
    for (;;) {
        WaitForSingleObject(g_powerEvent, INFINITE);
        int want;
        while ((want = (int)g_powerWant) != applied) { power_apply_now(want, applied); applied = want; }
    }
    return 0;
}

static void power_apply(int mode) {
    g_powerMode = mode;
    if (!g_powerEvent) { g_powerEvent = CreateEventW(NULL, FALSE, FALSE, NULL); CreateThread(NULL, 0, power_worker, NULL, 0, NULL); }
    InterlockedExchange(&g_powerWant, mode);
    SetEvent(g_powerEvent);
}

// Called after every start/stop and once a second: the union of what the live viewers asked for.
static void power_update(void) {
    int want = 0;
    EnterCriticalSection(&g_vlock);
    for (int i = 0; i < MAX_MON; i++)
        if (g_viewers[i].active && WaitForSingleObject(g_viewers[i].proc, 0) == WAIT_TIMEOUT) {
            want |= g_viewers[i].power;
            if ((g_viewers[i].power & 2) && (g_viewers[i].gpuMHz << 4) > (want & ~15)) want = (want & 15) | (g_viewers[i].gpuMHz << 4);
        }
    LeaveCriticalSection(&g_vlock);
    if (dash_live() && (g_dashPower & 3)) {
        want |= g_dashPower & 3;
        if ((g_dashPower & 2) && (DASH_GPU_MHZ << 4) > (want & ~15)) want = (want & 15) | (DASH_GPU_MHZ << 4);
    }
    if (!(want & 2)) want &= 15;
    if (want != g_powerMode) power_apply(want);
}

// Rest: while extending, the PC is only a display. "Rest" pauses (NtSuspendProcess) every app of the
// signed-in user, so browsers, launchers and games stop burning CPU/GPU, and resumes them exactly as
// they were when rest ends. Only the user's own processes are touched: anything running as SYSTEM,
// a service account, DWM or the font driver host is never paused, nor are the shell pieces the
// desktop needs, fan/RGB/driver helpers, and whatever the Mac (or rest-keep.txt) says to keep.
// Ends on REST 0, when extending stops (including someone touching the PC), and at agent start/stop;
// the paused list is also on disk so a crashed agent can't leave apps frozen.
typedef LONG (NTAPI *NtProcFn)(HANDLE);
static NtProcFn pNtSuspendProcess, pNtResumeProcess;
typedef struct { DWORD pid; FILETIME created; } Rested;
#define MAX_RESTED 1024
static Rested g_rested[MAX_RESTED];
static int g_nrested, g_restOn, g_restSkipped;
static char g_restKeep[2048];              // comma-separated extra names from the Mac
static ULONGLONG g_restSwept;
#define REST_FILE L"C:\\ProgramData\\PaneLink\\rested.txt"

static const char *REST_KEEP_EXACT[] = {
    "explorer.exe", "sihost.exe", "ctfmon.exe", "taskhostw.exe", "svchost.exe", "conhost.exe", "dllhost.exe",
    "runtimebroker.exe", "textinputhost.exe", "startmenuexperiencehost.exe", "shellexperiencehost.exe",
    "searchapp.exe", "searchui.exe", "lockapp.exe", "applicationframehost.exe", "smartscreen.exe",
    "securityhealthsystray.exe", "userinit.exe", "panelink.exe", "fancontrol.exe", "cmd.exe", "powershell.exe",
    "schtasks.exe", "nvidia-smi.exe", "audiodg.exe", "backgroundtaskhost.exe", "comppkgsrv.exe", "systemsettings.exe",
    "useroobebroker.exe", NULL };
static const char *REST_KEEP_PART[] = { "asus", "armoury", "aura", "nvidia", "nvcontainer", "nvdisplay", "realtek", "rtk",
    "vgtray", "vanguard", "logi", "razer", "corsair", "steelseries", "icue", "ngenuity", "easyswitch",
    "mbhal", "tailscale", "warp", "cloudflare", "remoteserver", "defender", NULL };   // VPN/remote access, peripherals, RGB

static int rest_keep(const char *name) {
    char n[MAX_PATH]; int i;
    for (i = 0; name[i] && i < MAX_PATH - 1; i++) n[i] = (char)tolower((unsigned char)name[i]);
    n[i] = 0;
    for (const char **k = REST_KEEP_EXACT; *k; k++) if (!strcmp(n, *k)) return 1;
    for (const char **k = REST_KEEP_PART; *k; k++) if (strstr(n, *k)) return 1;
    // extras: from the Mac, then C:\ProgramData\PaneLink\rest-keep.txt (one name per line); match without ".exe" too
    char extra[4096]; snprintf(extra, sizeof extra, "%s,", g_restKeep);
    FILE *f = _wfopen(L"C:\\ProgramData\\PaneLink\\rest-keep.txt", L"r");
    if (f) { size_t l = strlen(extra); fread(extra + l, 1, sizeof extra - 1 - l, f); extra[sizeof extra - 1] = 0; fclose(f); }
    for (char *t = strtok(extra, ",\r\n"); t; t = strtok(NULL, ",\r\n")) {
        while (*t == ' ') t++;
        char k[MAX_PATH]; int j;
        for (j = 0; t[j] && j < MAX_PATH - 1; j++) k[j] = (char)tolower((unsigned char)t[j]);
        while (j && k[j - 1] == ' ') j--;
        k[j] = 0;
        if (!j) continue;
        size_t ln = strlen(n);
        if (!strcmp(n, k) || (ln > 4 && !strncmp(n, k, ln - 4) && strlen(k) == ln - 4 && !strcmp(n + ln - 4, ".exe"))) return 1;
    }
    return 0;
}

// The signed-in user's own processes only: not SYSTEM / LOCAL SERVICE / NETWORK SERVICE (S-1-5-18..20),
// DWM (S-1-5-90-*) or the font driver host (S-1-5-96-*).
static int rest_user_process(HANDLE p) {
    HANDLE tok; int user = 0;
    if (!OpenProcessToken(p, TOKEN_QUERY, &tok)) return 0;
    char buf[256]; DWORD len;
    if (GetTokenInformation(tok, TokenUser, buf, sizeof buf, &len)) {
        char *sid = NULL;
        if (ConvertSidToStringSidA(((TOKEN_USER *)buf)->User.Sid, &sid)) {
            user = strncmp(sid, "S-1-5-18", 9) && strncmp(sid, "S-1-5-19", 9) && strncmp(sid, "S-1-5-20", 9) &&
                   strncmp(sid, "S-1-5-90-", 9) && strncmp(sid, "S-1-5-96-", 9) && !strncmp(sid, "S-1-5-21-", 9);
            LocalFree(sid);
        }
    }
    CloseHandle(tok);
    return user;
}

static void rest_save(void) {
    FILE *f = _wfopen(REST_FILE, L"w");
    if (!f) return;
    for (int i = 0; i < g_nrested; i++)
        fprintf(f, "%lu %lu %lu\n", g_rested[i].pid, g_rested[i].created.dwHighDateTime, g_rested[i].created.dwLowDateTime);
    fclose(f);
}

static int rest_ntapi(void) {
    if (!pNtSuspendProcess) {
        HMODULE nt = GetModuleHandleW(L"ntdll.dll");
        pNtSuspendProcess = (NtProcFn)GetProcAddress(nt, "NtSuspendProcess");
        pNtResumeProcess = (NtProcFn)GetProcAddress(nt, "NtResumeProcess");
    }
    return pNtSuspendProcess && pNtResumeProcess;
}

// Pauses everything eligible that isn't paused yet (also catches apps started during rest).
// dry: only lists what it would pause (REST ? diagnostics), into dry/dryLen.
static void rest_sweep_ex(char *dry, int dryLen);
static void rest_sweep(void) { rest_sweep_ex(NULL, 0); }
static void rest_sweep_ex(char *dry, int dryLen) {
    if (!rest_ntapi()) return;
    DWORD session = WTSGetActiveConsoleSessionId(), self = GetCurrentProcessId();
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return;
    PROCESSENTRY32W pe = {sizeof pe};
    int added = 0, skipped = 0;
    for (BOOL ok = Process32FirstW(snap, &pe); ok; ok = Process32NextW(snap, &pe)) {
        DWORD s;
        if (pe.th32ProcessID <= 4 || pe.th32ProcessID == self || !ProcessIdToSessionId(pe.th32ProcessID, &s) || s != session) continue;
        int already = 0;
        for (int i = 0; i < g_nrested && !already; i++) already = g_rested[i].pid == pe.th32ProcessID;
        if (already || g_nrested >= MAX_RESTED) continue;
        char name[MAX_PATH]; WideCharToMultiByte(CP_UTF8, 0, pe.szExeFile, -1, name, sizeof name, NULL, NULL);
        if (rest_keep(name)) continue;
        HANDLE p = OpenProcess(PROCESS_SUSPEND_RESUME | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
        if (!p) { skipped++; continue; }    // protected (anti-cheat, PPL): stays running
        FILETIME c, e, k, u; BOOL crit = FALSE;
        if (!rest_user_process(p) || (IsProcessCritical(p, &crit) && crit) || !GetProcessTimes(p, &c, &e, &k, &u)) { CloseHandle(p); continue; }
        if (dry) { size_t l = strlen(dry); snprintf(dry + l, dryLen - l, "%s ", name); CloseHandle(p); continue; }
        if (pNtSuspendProcess(p) >= 0) {
            g_rested[g_nrested].pid = pe.th32ProcessID; g_rested[g_nrested].created = c; g_nrested++; added++;
            plog("rest: paused %s (%lu)", name, pe.th32ProcessID);
        } else skipped++;
        CloseHandle(p);
    }
    CloseHandle(snap);
    if (dry) return;
    g_restSkipped += skipped;
    if (added) rest_save();
    g_restSwept = GetTickCount64();
}

static void rest_resume_one(DWORD pid, FILETIME created) {
    HANDLE p = OpenProcess(PROCESS_SUSPEND_RESUME | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!p) return;
    FILETIME c, e, k, u;   // pid reuse: only resume the very process we paused
    if (GetProcessTimes(p, &c, &e, &k, &u) && !CompareFileTime(&c, &created)) pNtResumeProcess(p);
    CloseHandle(p);
}

static void rest_off(const char *why) {
    if (!rest_ntapi()) return;
    int n = g_nrested;
    for (int i = 0; i < g_nrested; i++) rest_resume_one(g_rested[i].pid, g_rested[i].created);
    g_nrested = 0;
    // leftovers from a previous agent that died while resting
    FILE *f = _wfopen(REST_FILE, L"r");
    if (f) {
        unsigned long pid, hi, lo;
        while (fscanf(f, "%lu %lu %lu", &pid, &hi, &lo) == 3) { FILETIME c = {lo, hi}; rest_resume_one(pid, c); n++; }
        fclose(f);
        DeleteFileW(REST_FILE);
    }
    if (g_restOn || n) plog("rest: off (%s), resumed %d app(s)", why, n);
    int was = g_restOn;
    g_restOn = 0; g_restSkipped = 0;
    SOCKET c = g_client;
    if (was && c != INVALID_SOCKET) send(c, "REST 0 0 0\n", 11, 0);
}

static void rest_on(const char *keep) {
    snprintf(g_restKeep, sizeof g_restKeep, "%.2000s", keep ? keep : "");
    g_restOn = 1;
    rest_sweep();
    plog("rest: on, %d app(s) paused, %d left running (protected)", g_nrested, g_restSkipped);
}

// Morning dashboard (klipper's wake-up screen): a "dash" helper shows the PNGs klipper renders,
// full screen on the lock screen, until someone touches the PC or logs in. DASH power bits:
// 1 = quiet fans, 2 = GPU clock cap, 4 = rest (pause the signed-in user's apps).
// If nobody logs in within the given minutes, the PC shuts itself down again.
static int dash_live(void) { return g_dashProc && WaitForSingleObject(g_dashProc, 0) == WAIT_TIMEOUT; }

static int console_user_signed_in(void) {
    wchar_t *name = NULL; DWORD len = 0; int yes = 0;
    if (WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, WTSGetActiveConsoleSessionId(), WTSUserName, &name, &len)) {
        yes = name && name[0];
        WTSFreeMemory(name);
    }
    return yes;
}

static void dash_stop(const char *why) {
    if (g_dashProc) {
        HANDLE ev = OpenEventW(EVENT_MODIFY_STATE, FALSE, L"Global\\MorningDashStop");
        if (ev) { SetEvent(ev); CloseHandle(ev); }
        if (WaitForSingleObject(g_dashProc, 3000) != WAIT_OBJECT_0) TerminateProcess(g_dashProc, 0);
        CloseHandle(g_dashProc); g_dashProc = NULL;
        plog("dash: stopped (%s)", why);
    }
    g_dashPower = 0;
}

static int dash_start(const char *base, int shutdownMin, int power, char *err, int errlen) {
    // base must be a plain http://host:port (it goes on a command line)
    if (strncmp(base, "http://", 7) || strlen(base) > 100) { snprintf(err, errlen, "bad url"); return 0; }
    for (const char *c = base + 7; *c; c++)
        if (!isalnum((unsigned char)*c) && !strchr(".:-", *c)) { snprintf(err, errlen, "bad url"); return 0; }
    if (console_user_signed_in() && !g_restOn) {
        // someone is signed in: only show if the PC is locked (the input desktop is Winlogon)
        HDESK d = OpenInputDesktop(0, FALSE, GENERIC_READ); wchar_t name[64] = L"";
        if (d) { GetUserObjectInformationW(d, UOI_NAME, name, sizeof name, NULL); CloseDesktop(d); }
        if (_wcsicmp(name, L"Winlogon")) { snprintf(err, errlen, "someone is using the PC"); return 0; }
    }
    dash_stop("restart");
    HANDLE ev = CreateEventW(NULL, TRUE, FALSE, L"Global\\MorningDashStop");
    ResetEvent(ev);
    wchar_t exe[MAX_PATH], cmd[512];
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    swprintf(cmd, 512, L"\"%ls\" dash %hs", exe, base);
    PROCESS_INFORMATION pi;
    if (!spawn_console(cmd, &pi, NULL)) { CloseHandle(ev); snprintf(err, errlen, "spawn failed %lu", GetLastError()); return 0; }
    CloseHandle(pi.hThread);
    g_dashProc = pi.hProcess;
    g_dashPower = power & 7;
    g_dashShutdownAt = (shutdownMin > 0 && !console_user_signed_in()) ? GetTickCount64() + (ULONGLONG)shutdownMin * 60000 : 0;
    if ((power & 4) && !g_restOn && console_user_signed_in()) rest_on("");
    plog("dash: started (%hs, shutdown in %d min, power %d)", base, g_dashShutdownAt ? shutdownMin : 0, power);
    return 1;
}

// Once a second from the agent loop: tidy up after the helper exits, and the no-login shutdown.
static void dash_tick(void) {
    if (g_dashProc && !dash_live()) {
        DWORD code = 0; GetExitCodeProcess(g_dashProc, &code);
        CloseHandle(g_dashProc); g_dashProc = NULL; g_dashPower = 0;
        plog("dash: helper ended (code %lu)", code);
    }
    if (g_dashShutdownAt) {
        if (console_user_signed_in()) { plog("dash: someone signed in, no auto shutdown"); g_dashShutdownAt = 0; }
        else if (GetTickCount64() > g_dashShutdownAt) {
            g_dashShutdownAt = 0;
            dash_stop("auto shutdown");
            HANDLE tok; TOKEN_PRIVILEGES tp = {1};
            if (OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &tok)) {
                LookupPrivilegeValueW(NULL, L"SeShutdownPrivilege", &tp.Privileges[0].Luid);
                tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
                AdjustTokenPrivileges(tok, FALSE, &tp, 0, NULL, NULL);
                CloseHandle(tok);
            }
            DWORD r = InitiateShutdownW(NULL, L"Morning dashboard: nobody signed in", 0, SHUTDOWN_POWEROFF | SHUTDOWN_FORCE_OTHERS,
                                        SHTDN_REASON_MAJOR_OTHER | SHTDN_REASON_FLAG_PLANNED);
            plog("dash: nobody signed in -> shutting down (%lu)", r);
        }
    }
}

static int any_viewer(void) {
    int live = 0;
    EnterCriticalSection(&g_vlock);
    for (int i = 0; i < MAX_MON; i++) live |= g_viewers[i].active && WaitForSingleObject(g_viewers[i].proc, 0) == WAIT_TIMEOUT;
    LeaveCriticalSection(&g_vlock);
    return live;
}

static void stop_viewer(int i) {
    EnterCriticalSection(&g_vlock);
    Viewer *v = &g_viewers[i];
    if (v->active) {
        // ask nicely first so the viewer restores the monitor's refresh rate itself
        SetEvent(v->stopEvent);
        if (WaitForSingleObject(v->proc, 3000) != WAIT_OBJECT_0) TerminateProcess(v->proc, 0);
        CloseHandle(v->proc); CloseHandle(v->stopEvent);
        v->active = 0;
        plog("viewer %d stopped", i);
    }
    LeaveCriticalSection(&g_vlock);
}

static void stop_all(void) { for (int i = 0; i < MAX_MON; i++) stop_viewer(i); }

// ins: left/top/right/bottom pixels of the panel the picture stays out of (covered by the laptop)
static int start_viewer(int idx, const char *codec, int port, int hz, int vsync, int autostop, int power, int mousePx, int graceMs, int gpuMHz,
                        const int *ins, char *err, int errlen) {
    if (idx < 0 || idx >= g_nmons) { snprintf(err, errlen, "no such monitor"); return 0; }
    if (strcmp(codec, "hevc") && strcmp(codec, "h264")) { snprintf(err, errlen, "bad codec"); return 0; }
    if (port < 1024 || port > 65535 || hz < 0 || hz > 500) { snprintf(err, errlen, "bad parameters"); return 0; }
    vsync = vsync ? 1 : 0; autostop = autostop ? 1 : 0;
    if (mousePx < 0 || mousePx > 2000) mousePx = 40;
    if (graceMs < 0 || graceMs > 60000) graceMs = 2000;
    if (gpuMHz < 300 || gpuMHz > 3000) gpuMHz = 1100;
    EnterCriticalSection(&g_vlock);
    Viewer *v = &g_viewers[idx];
    v->power = power & 3; v->gpuMHz = gpuMHz;   // power preferences alone don't need a viewer restart
    int same = v->active && WaitForSingleObject(v->proc, 0) == WAIT_TIMEOUT && v->port == port && v->hz == hz &&
               v->vsync == vsync && v->autostop == autostop && v->mousePx == mousePx && v->graceMs == graceMs &&
               !memcmp(v->ins, ins, sizeof v->ins) && !strcmp(v->codec, codec);
    LeaveCriticalSection(&g_vlock);
    if (same) { plog("viewer %d already running with same settings: keeping it", idx); return 1; }
    stop_viewer(idx);

    wchar_t evName[64]; swprintf(evName, 64, L"Global\\PaneLinkStop-%d", port);
    HANDLE ev = CreateEventW(NULL, TRUE, FALSE, evName);
    ResetEvent(ev);
    wchar_t exe[MAX_PATH], cmd[1024], wcodec[16];
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    MultiByteToWideChar(CP_UTF8, 0, codec, -1, wcodec, 16);
    swprintf(cmd, 1024, L"\"%ls\" view %ls %d %ls %d %d %d %d %d %d %d %d %d", exe, g_mons[idx].device, port, wcodec, vsync, hz, autostop, mousePx, graceMs,
             ins[0], ins[1], ins[2], ins[3]);
    PROCESS_INFORMATION pi;
    if (!spawn_console(cmd, &pi, NULL)) { CloseHandle(ev); snprintf(err, errlen, "spawn failed %lu", GetLastError()); return 0; }
    CloseHandle(pi.hThread);
    EnterCriticalSection(&g_vlock);
    v->proc = pi.hProcess; v->stopEvent = ev; v->active = 1;
    v->port = port; v->hz = hz; v->vsync = vsync; v->autostop = autostop; v->power = power & 3; v->mousePx = mousePx; v->graceMs = graceMs; v->gpuMHz = gpuMHz;
    memcpy(v->ins, ins, sizeof v->ins);
    snprintf(v->codec, sizeof v->codec, "%s", codec);
    LeaveCriticalSection(&g_vlock);
    plog("viewer %d started: %ls", idx, cmd);
    return 1;
}

static void send_str(SOCKET s, const char *str) { send(s, str, (int)strlen(str), 0); }

// ---------------------------------------------------------------------------------------------
// pairing: a Mac has to pair once before it can control this PC. PAIR shows a 6-digit code on
// every monitor (lock screen included); the Mac sends it back with PAIRCODE and gets a token it
// presents with AUTH from then on. Tokens live in private\paired.txt ("<token> <name>" per Mac;
// delete the file to forget every Mac). trusted.txt lists addresses allowed without pairing
// (e.g. a home server that only sends DASH), one per line.

#define PRIVATE_DIR   L"C:\\ProgramData\\PaneLink\\private"
#define PAIRED_FILE   PRIVATE_DIR L"\\paired.txt"
#define PAIRCODE_FILE PRIVATE_DIR L"\\pair-code.txt"   // the current code, for headless setups (admins only)
#define TRUSTED_FILE  L"C:\\ProgramData\\PaneLink\\trusted.txt"
#define PAIR_MS 300000

static char g_pairCode[8], g_pairName[64];
static ULONGLONG g_pairUntil, g_pairLast;
static int g_pairTries;
static HANDLE g_pinProc, g_pinStop;

static int token_ok(const char *tok) {
    if (strlen(tok) != 32) return 0;
    FILE *f = _wfopen(PAIRED_FILE, L"r");
    if (!f) return 0;
    char line[256]; int ok = 0;
    while (!ok && fgets(line, sizeof line, f)) ok = !strncmp(line, tok, 32) && (line[32] == ' ' || line[32] == '\r' || line[32] == '\n' || !line[32]);
    fclose(f);
    return ok;
}

static int addr_trusted(const char *ip) {
    FILE *f = _wfopen(TRUSTED_FILE, L"r");
    if (!f) return 0;
    char line[128]; int ok = 0;
    while (!ok && fgets(line, sizeof line, f)) { line[strcspn(line, " \t\r\n#")] = 0; ok = line[0] && !strcmp(line, ip); }
    fclose(f);
    return ok;
}

static void pin_hide(void) {
    if (g_pinProc) {
        SetEvent(g_pinStop);
        if (WaitForSingleObject(g_pinProc, 2000) != WAIT_OBJECT_0) TerminateProcess(g_pinProc, 0);
        CloseHandle(g_pinProc); g_pinProc = NULL;
    }
    ResetEvent(g_pinStop);
    DeleteFileW(PAIRCODE_FILE);
}

static void pair_begin(SOCKET s, const char *name) {
    if (g_pairLast && GetTickCount64() - g_pairLast < 3000) { send_str(s, "PAIRFAIL wait\n"); return; }   // no code-guessing loops
    g_pairLast = GetTickCount64();
    pin_hide();
    int n = 0;   // ASCII only: the name goes through a command line
    for (const char *p = name; *p && n < (int)sizeof g_pairName - 1; p++) if (*p >= ' ' && *p < 127 && *p != '"' && *p != '\\') g_pairName[n++] = *p;
    g_pairName[n] = 0;
    if (!n) strcpy(g_pairName, "Mac");
    unsigned v; rand_s(&v);
    snprintf(g_pairCode, sizeof g_pairCode, "%06u", v % 1000000);
    g_pairUntil = GetTickCount64() + PAIR_MS; g_pairTries = 0;
    CreateDirectoryW(PRIVATE_DIR, NULL);
    FILE *f = _wfopen(PAIRCODE_FILE, L"w");
    if (f) { fprintf(f, "%s\n", g_pairCode); fclose(f); }
    wchar_t exe[MAX_PATH], cmd[MAX_PATH + 128];
    GetModuleFileNameW(NULL, exe, MAX_PATH);
    swprintf(cmd, MAX_PATH + 128, L"\"%ls\" pincode %hs \"%hs\"", exe, g_pairCode, g_pairName);
    PROCESS_INFORMATION pi;
    if (spawn_console(cmd, &pi, NULL)) { CloseHandle(pi.hThread); g_pinProc = pi.hProcess; }
    plog("pairing: code shown for \"%s\"", g_pairName);
    send_str(s, "PAIRING\n");
}

static void pair_finish(SOCKET s, const char *code) {
    char out[64];
    if (!g_pairCode[0] || GetTickCount64() > g_pairUntil) { send_str(s, "PAIRFAIL expired\n"); return; }
    if (strcmp(code, g_pairCode)) {
        if (++g_pairTries >= 5) { g_pairCode[0] = 0; pin_hide(); send_str(s, "PAIRFAIL expired\n"); }
        else send_str(s, "PAIRFAIL wrong\n");
        plog("pairing: wrong code (%d)", g_pairTries);
        return;
    }
    char tok[33];
    for (int i = 0; i < 16; i++) { unsigned v; rand_s(&v); snprintf(tok + 2 * i, 3, "%02x", v & 255); }
    CreateDirectoryW(PRIVATE_DIR, NULL);
    FILE *f = _wfopen(PAIRED_FILE, L"a");
    if (!f) { send_str(s, "PAIRFAIL storage\n"); return; }
    fprintf(f, "%s %s\n", tok, g_pairName); fclose(f);
    g_pairCode[0] = 0;
    pin_hide();
    plog("pairing: paired \"%s\"", g_pairName);
    snprintf(out, sizeof out, "PAIRED %s\n", tok); send_str(s, out);
}

// Discovery: a Mac broadcasts "PANELINK?" to UDP 49500; we answer with what it needs to pair and
// to wake us later: "PANELINK 1 <port> <wired MAC address> <computer name>".
static void wake_mac(char *out, int len) {
    snprintf(out, len, "-");
    ULONG sz = 32768; IP_ADAPTER_ADDRESSES *aa = malloc(sz);
    if (GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_GATEWAYS | GAA_FLAG_SKIP_DNS_SERVER, NULL, aa, &sz) == NO_ERROR) {
        int best = -1;
        for (IP_ADAPTER_ADDRESSES *a = aa; a; a = a->Next) {
            if (a->OperStatus != IfOperStatusUp || a->PhysicalAddressLength != 6) continue;
            int score = (a->IfType == IF_TYPE_ETHERNET_CSMACD ? 2 : 0) + (a->FirstGatewayAddress ? 1 : 0);   // wired + routed = the LAN NIC
            if (score <= best) continue;
            best = score;
            BYTE *m = a->PhysicalAddress;
            snprintf(out, len, "%02X:%02X:%02X:%02X:%02X:%02X", m[0], m[1], m[2], m[3], m[4], m[5]);
        }
    }
    free(aa);
}

static DWORD WINAPI discovery_server(void *arg) {
    (void)arg;
    SOCKET u = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_port = htons(CONTROL_PORT); a.sin_addr.s_addr = INADDR_ANY;
    while (bind(u, (struct sockaddr *)&a, sizeof a)) { plog("discovery bind failed %d, retrying", WSAGetLastError()); Sleep(5000); }
    for (;;) {
        char buf[64]; struct sockaddr_in from; int fl = sizeof from;
        int n = recvfrom(u, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &fl);
        if (n < 9 || strncmp(buf, "PANELINK?", 9)) continue;
        char name[MAX_COMPUTERNAME_LENGTH + 1] = "PC", mac[24], out[128];
        DWORD nl = sizeof name; GetComputerNameA(name, &nl);
        wake_mac(mac, sizeof mac);
        snprintf(out, sizeof out, "PANELINK 1 %d %s %s\n", CONTROL_PORT, mac, name);
        sendto(u, out, (int)strlen(out), 0, (struct sockaddr *)&from, fl);
    }
    return 0;
}

static CRITICAL_SECTION g_cmdlock;
static void handle_line_locked(SOCKET s, char *line);

static void handle_line(SOCKET s, char *line) {
    EnterCriticalSection(&g_cmdlock);
    handle_line_locked(s, line);
    LeaveCriticalSection(&g_cmdlock);
}

static void handle_line_locked(SOCKET s, char *line) {
    char out[1024];
    if (strncmp(line, "PING", 4) && strncmp(line, "PAIRCODE", 8)) plog("< %.200s", line);
    if (!strncmp(line, "HELLO", 5)) {
        // While streaming, keep the monitor list stable (refresh rates are switched by the viewers).
        int streaming = 0;
        for (int i = 0; i < MAX_MON; i++) streaming |= g_viewers[i].active;
        if (!streaming || g_nmons == 0) enum_monitors_console();
        snprintf(out, sizeof out, "MONITORS %d\n", g_nmons); send_str(s, out);
        for (int i = 0; i < g_nmons; i++) {
            char dev[64], fr[128];
            WideCharToMultiByte(CP_UTF8, 0, g_mons[i].device, -1, dev, sizeof dev, NULL, NULL);
            WideCharToMultiByte(CP_UTF8, 0, g_mons[i].friendly, -1, fr, sizeof fr, NULL, NULL);
            Monitor *m = &g_mons[i];
            snprintf(out, sizeof out, "MON %d %d %d %d %d %d %d %s %s\n", i, m->x, m->y, m->w, m->h, m->hz, m->primary, dev, fr);
            send_str(s, out);
        }
        // lets the Mac remind the user until quiet fans are actually set up
        snprintf(out, sizeof out, "FANS %d %d\n", fans_configured(), gpu_tool()); send_str(s, out);
    } else if (!strncmp(line, "START", 5)) {
        int idx, w, h, hz, port, vsync = 0, autostop = 0, power = 0, mousePx = 40, graceMs = 2000, gpuMHz = 1100, ins[4] = {0}; char codec[16];
        if (sscanf(line, "START %d %d %d %d %15s %d %d %d %d %d %d %d %d %d %d %d", &idx, &w, &h, &hz, codec, &port, &vsync, &autostop, &power,
                   &mousePx, &graceMs, &gpuMHz, &ins[0], &ins[1], &ins[2], &ins[3]) >= 6) {
            for (int i = 0; i < 4; i++) if (ins[i] < 0 || ins[i] > 4000) ins[i] = 0;
            char err[128];
            if (start_viewer(idx, codec, port, hz, vsync, autostop, power, mousePx, graceMs, gpuMHz, ins, err, sizeof err)) snprintf(out, sizeof out, "OK %d\n", idx);
            else snprintf(out, sizeof out, "ERR %d %s\n", idx, err);
            power_update();
        } else snprintf(out, sizeof out, "ERR -1 bad START\n");
        send_str(s, out);
    } else if (!strncmp(line, "STOPALL", 7)) {
        stop_all(); power_update(); send_str(s, "OK -1\n");
    } else if (!strncmp(line, "STOP", 4)) {
        int idx; if (sscanf(line, "STOP %d", &idx) == 1 && idx >= 0 && idx < MAX_MON) stop_viewer(idx);
        power_update();
        send_str(s, "OK -1\n");
    } else if (!strncmp(line, "REST", 4)) {   // REST 1 [keep,names] / REST 0
        if (line[4] == ' ' && line[5] == '?') {
            char dry[8192] = ""; rest_sweep_ex(dry, sizeof dry);
            send_str(s, "REST? "); send_str(s, dry); send_str(s, "\n");
        } else if (line[4] == ' ' && line[5] == '1') {
            if (!any_viewer()) send_str(s, "ERR -1 rest only works while extending\n");
            else { rest_on(line[6] == ' ' ? line + 7 : ""); snprintf(out, sizeof out, "REST 1 %d %d\n", g_nrested, g_restSkipped); send_str(s, out); }
        } else { rest_off("asked"); send_str(s, "REST 0 0 0\n"); }
    } else if (!strncmp(line, "DASH", 4)) {   // DASH 1 <http://host:port> <shutdownMin> <power> / DASH 0 / DASH ?
        char base[128]; int mins = 0, power = 0, err2 = 0; char err[96] = "";
        if (line[4] == ' ' && line[5] == '1' && sscanf(line, "DASH 1 %127s %d %d", base, &mins, &power) >= 1) {
            if (mins < 0 || mins > 600) mins = 0;
            err2 = !dash_start(base, mins, power, err, sizeof err);
            if (err2) snprintf(out, sizeof out, "ERR dash %s\n", err); else snprintf(out, sizeof out, "DASH 1\n");
        } else if (line[4] == ' ' && line[5] == '?') {
            snprintf(out, sizeof out, "DASH %d signed-in %d shutdown-in %llu\n", dash_live(), console_user_signed_in(),
                     g_dashShutdownAt ? (g_dashShutdownAt - GetTickCount64()) / 1000 : 0ULL);
        } else { dash_stop("asked"); g_dashShutdownAt = 0; snprintf(out, sizeof out, "DASH 0\n"); }
        power_update();
        send_str(s, out);
    } else if (!strncmp(line, "PAIRCODE ", 9)) {
        pair_finish(s, line + 9);
    } else if (!strncmp(line, "PAIR", 4)) {   // PAIR <name of the Mac>
        pair_begin(s, line[4] == ' ' ? line + 5 : "");
    } else if (!strncmp(line, "PING", 4)) {
        send_str(s, "PONG\n");
    } else if (!strncmp(line, "POKE", 4)) {   // diagnostics: simulate someone touching the PC (one Shift tap)
        wchar_t exe[MAX_PATH], cmd[MAX_PATH + 16];
        GetModuleFileNameW(NULL, exe, MAX_PATH);
        swprintf(cmd, MAX_PATH + 16, L"\"%ls\" poke", exe);
        PROCESS_INFORMATION pi;
        if (spawn_console(cmd, &pi, NULL)) { WaitForSingleObject(pi.hProcess, 3000); CloseHandle(pi.hProcess); CloseHandle(pi.hThread); }
        send_str(s, "POKED\n");
    } else if (!strncmp(line, "SHOT", 4)) {   // diagnostics: screenshot of whatever is on the console now
        wchar_t exe[MAX_PATH], cmd[MAX_PATH + 64];
        GetModuleFileNameW(NULL, exe, MAX_PATH);
        swprintf(cmd, MAX_PATH + 64, L"\"%ls\" shot C:\\ProgramData\\PaneLink\\shot.bmp", exe);
        PROCESS_INFORMATION pi; HANDLE rd;
        if (spawn_console(cmd, &pi, &rd)) {
            char b[128] = {0}; DWORD n = 0; ReadFile(rd, b, sizeof b - 1, &n, NULL);
            WaitForSingleObject(pi.hProcess, 5000);
            CloseHandle(pi.hProcess); CloseHandle(pi.hThread); CloseHandle(rd);
            snprintf(out, sizeof out, "SHOT %s", n ? b : "failed\n"); send_str(s, out);
        }
    }
}

// One thread per connection. The Mac's connection is the "controller"; a newer controller connection
// replaces a stale one (e.g. a half-dead socket after a Wi-Fi change). Diagnostic one-shot commands
// (SHOT) can be sent on a side connection without disturbing it.
static DWORD WINAPI conn_thread(void *arg) {
    SOCKET s = (SOCKET)(uintptr_t)arg;
    BOOL yes = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (char *)&yes, sizeof yes);
    DWORD tmo = 10000; setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (char *)&tmo, sizeof tmo);  // Mac pings every 2s
    char buf[4096]; int len = 0, isController = 0;
    struct sockaddr_in pa; int pl = sizeof pa; char ip[32] = "";
    if (!getpeername(s, (struct sockaddr *)&pa, &pl)) snprintf(ip, sizeof ip, "%s", inet_ntoa(pa.sin_addr));
    int authed = addr_trusted(ip);
    for (;;) {
        int n = recv(s, buf + len, sizeof buf - 1 - len, 0);
        if (n <= 0) break;
        len += n; buf[len] = 0;
        char *nl;
        while ((nl = strchr(buf, '\n'))) {
            *nl = 0;
            if (nl > buf && nl[-1] == '\r') nl[-1] = 0;
            int skip = 0;
            if (!strncmp(buf, "AUTH ", 5)) {
                if (!authed) authed = token_ok(buf + 5);
                if (!authed) plog("auth: unknown token from %s", ip);
                send_str(s, authed ? "AUTH 1\n" : "AUTH 0\n");
                skip = 1;
            } else if (!authed && strncmp(buf, "PAIR", 4) && strncmp(buf, "PING", 4)) {
                send_str(s, "NEEDPAIR\n");   // not paired: only PAIR/PAIRCODE/PING until AUTH succeeds
                skip = 1;
            }
            if (skip) {}
            else if (!isController && authed && strncmp(buf, "PAIR", 4) && strncmp(buf, "SHOT", 4) && strncmp(buf, "POKE", 4) && strncmp(buf, "REST ?", 6) && strncmp(buf, "DASH", 4)) {
                isController = 1;
                SOCKET old = g_client;
                g_client = s;
                g_orphanSince = 0;
                if (old != INVALID_SOCKET && old != s) shutdown(old, SD_BOTH);   // its thread exits and closes it
            }
            if (!skip) handle_line(s, buf);
            len -= (int)(nl + 1 - buf);
            memmove(buf, nl + 1, len + 1);
        }
        if (len >= (int)sizeof buf - 1) len = 0;
    }
    if (isController && g_client == s) {
        plog("controller disconnected; keeping viewers for %d s", ORPHAN_GRACE_MS / 1000);
        g_client = INVALID_SOCKET;
        g_orphanSince = GetTickCount64();
    }
    closesocket(s);
    return 0;
}

static DWORD WINAPI agent_server(void *arg) {
    (void)arg;
    SOCKET ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    BOOL yes = 1; setsockopt(ls, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (char *)&yes, sizeof yes);
    struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_port = htons(CONTROL_PORT); a.sin_addr.s_addr = INADDR_ANY;
    while (bind(ls, (struct sockaddr *)&a, sizeof a) || listen(ls, 8)) { plog("bind/listen failed %d, retrying", WSAGetLastError()); Sleep(2000); }
    plog("agent listening on %d", CONTROL_PORT);
    for (;;) {
        struct sockaddr_in ca; int cl = sizeof ca;
        SOCKET s = accept(ls, (struct sockaddr *)&ca, &cl);
        if (s == INVALID_SOCKET) continue;
        plog("connection from %s", inet_ntoa(ca.sin_addr));
        HANDLE t = CreateThread(NULL, 0, conn_thread, (void *)(uintptr_t)s, 0, NULL);
        if (t) CloseHandle(t); else closesocket(s);
    }
    return 0;
}

static void agent_loop(void) {
    InitializeCriticalSection(&g_vlock);
    InitializeCriticalSection(&g_cmdlock);
    // viewers (SYSTEM, console session) signal this; DACL-less named objects are fine between SYSTEM processes
    g_hotkeyEvent = CreateEventW(NULL, FALSE, FALSE, L"Global\\PaneLinkHotkey");
    g_activityEvent = CreateEventW(NULL, FALSE, FALSE, L"Global\\PaneLinkActivity");
    rest_off("agent start");   // a previous agent may have died while resting
    power_update();   // g_powerMode starts unknown: resets fans + GPU after a crash/reboot
    g_pinStop = CreateEventW(NULL, TRUE, FALSE, L"Global\\PaneLinkPinStop");
    CreateDirectoryW(PRIVATE_DIR, NULL);
    CreateThread(NULL, 0, agent_server, NULL, 0, NULL);
    CreateThread(NULL, 0, discovery_server, NULL, 0, NULL);
    HANDLE waits[3] = {g_hotkeyEvent, g_activityEvent, g_serviceStop};
    for (;;) {
        DWORD r = WaitForMultipleObjects(g_serviceStop ? 3 : 2, waits, FALSE, 1000);
        if (r == WAIT_OBJECT_0 + 2) { stop_all(); dash_stop("service stop"); rest_off("service stop"); if (g_powerMode != 0) power_apply_now(0, g_powerMode); return; }
        if (r == WAIT_OBJECT_0 || r == WAIT_OBJECT_0 + 1) {
            const char *why = r == WAIT_OBJECT_0 ? "hotkey" : "activity";
            plog("%s: stopping everything", why);
            stop_all();
            ResetEvent(g_activityEvent);   // every viewer saw the same input: one stop is enough
            ResetEvent(g_hotkeyEvent);
            SOCKET c = g_client;
            char msg[64]; snprintf(msg, sizeof msg, "STOPPED %s\n", why);
            if (c != INVALID_SOCKET) send_str(c, msg);   // keep the connection: the Mac just turns extending off
        }
        ULONGLONG o = g_orphanSince;
        if (o && GetTickCount64() - o > ORPHAN_GRACE_MS) {
            plog("controller gone for %d s: stopping viewers", ORPHAN_GRACE_MS / 1000);
            g_orphanSince = 0;
            stop_all();
        }
        EnterCriticalSection(&g_cmdlock);   // also catches viewers that exited on their own
        power_update();
        dash_tick();
        if (g_pairCode[0] && GetTickCount64() > g_pairUntil) { g_pairCode[0] = 0; pin_hide(); plog("pairing: code expired"); }
        if (g_pinProc && WaitForSingleObject(g_pinProc, 0) == WAIT_OBJECT_0) { CloseHandle(g_pinProc); g_pinProc = NULL; }
        if (g_restOn) {
            if (!any_viewer() && !dash_live()) rest_off("extending stopped");
            else if (GetTickCount64() - g_restSwept > 5000) rest_sweep();
        }
        LeaveCriticalSection(&g_cmdlock);
    }
}

static void svc_status(DWORD state) {
    SERVICE_STATUS st = {0};
    st.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    st.dwCurrentState = state;
    st.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN : 0;
    SetServiceStatus(g_svc, &st);
}

static DWORD WINAPI svc_ctrl(DWORD ctrl, DWORD type, LPVOID data, LPVOID ctx) {
    (void)type; (void)data; (void)ctx;
    if (ctrl == SERVICE_CONTROL_STOP || ctrl == SERVICE_CONTROL_SHUTDOWN) { svc_status(SERVICE_STOP_PENDING); SetEvent(g_serviceStop); }
    return NO_ERROR;
}

static void WINAPI svc_main(DWORD argc, LPWSTR *argv) {
    (void)argc; (void)argv;
    g_svc = RegisterServiceCtrlHandlerExW(L"PaneLink", svc_ctrl, NULL);
    g_serviceStop = CreateEventW(NULL, TRUE, FALSE, NULL);
    svc_status(SERVICE_RUNNING);
    agent_loop();
    svc_status(SERVICE_STOPPED);
}

static int run_service(void) {
    log_open("agent");
    plog("service starting");
    SERVICE_TABLE_ENTRYW table[] = {{L"PaneLink", svc_main}, {NULL, NULL}};
    if (!StartServiceCtrlDispatcherW(table)) {   // started by hand (not by the SCM): run in the foreground
        plog("not under SCM (%lu), running in foreground", GetLastError());
        agent_loop();
    }
    return 0;
}

// "list" helper (runs in the console session): prints the monitor list in protocol format
static int run_list(void) {
    enum_monitors();
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    for (int i = 0; i < g_nmons; i++) {
        char dev[64], fr[128], line[300]; DWORD w;
        WideCharToMultiByte(CP_UTF8, 0, g_mons[i].device, -1, dev, sizeof dev, NULL, NULL);
        WideCharToMultiByte(CP_UTF8, 0, g_mons[i].friendly, -1, fr, sizeof fr, NULL, NULL);
        Monitor *m = &g_mons[i];
        int n = snprintf(line, sizeof line, "MON %d %d %d %d %d %d %d %s %s\n", i, m->x, m->y, m->w, m->h, m->hz, m->primary, dev, fr);
        WriteFile(out, line, n, &w, NULL);
    }
    return 0;
}

// ---------------------------------------------------------------------------------------------
// viewer: reassembly + FEC

#pragma pack(push, 1)
typedef struct {
    uint8_t type, flags;
    uint16_t index;
    uint32_t frame;
    uint16_t count, group;
    uint32_t frameBytes;
    uint32_t tsUs;
} PktHdr;
typedef struct { uint8_t type, pad[3]; uint32_t lastGood; } IdrReq;
// ageUs: how long ago the echoed frame was presented (so the Mac doesn't count screen idle time as network delay)
typedef struct { uint8_t type, pad[3]; uint32_t echoTs, holdUs, ok, lost, decodeUs, presentUs, ageUs; } Stats;
// viewer -> Mac after every loss has been recovered: what the broken frame looked like on arrival and
// how recovery went, so the Mac can name a cause (see LossLog.swift)
typedef struct {
    uint8_t type, trigger, pad[2];       // 0x13; trigger: 1 newer frame came first, 2 gap at completion, 3 decoder stall, 4 renderer queue full
    uint32_t startFrame, frames;         // first frame lost, frames skipped until the keyframe showed
    uint16_t pkts, got, parity, broken;  // broken frame: data packets expected / received, parity received, FEC groups beyond repair
    uint32_t gapUs, recoverUs;           // silence before the trigger packet; trigger -> keyframe complete
    uint16_t idrReqs, keysSeen;          // keyframe requests sent, keyframes that started arriving (more than 1 = keyframe lost too)
    uint32_t frameBytes, keyBytes;       // broken frame size; recovering keyframe size
} LossPkt;
// Mac -> viewer, resent every second and on every change: live picture adjustments
typedef struct { uint8_t type, fullRange, pad[2]; float brightness, contrast, saturation, gamma, r, g, b; } ColorPkt;
#pragma pack(pop)

typedef struct {
    int used;
    uint32_t frame, frameBytes, ts;
    int count, group, ngroups, flags, recvd, done;
    uint8_t *data;             // count * PAYLOAD
    uint8_t *parity;           // ngroups * PAYLOAD
    uint8_t *have;             // count
    uint8_t *haveParity;       // ngroups
    uint16_t *groupRecvd;      // ngroups
    double firstUs;
} Slot;

typedef struct { uint8_t *buf; int len; int key; uint32_t ts; double arrivedUs; } QFrame;

static Slot g_slots[SLOTS];
static QFrame g_queue[32];
static int g_qhead, g_qtail;
static CRITICAL_SECTION g_qlock;
static HANDLE g_qevent;

static SOCKET g_udp;
static struct sockaddr_in g_peer;
static volatile int g_havePeer;
static volatile LONG g_needKey = 1;
static uint32_t g_nextFrame;
static volatile LONG g_lost, g_ok;
// per-second diagnostics
static volatile LONG d_pkts, d_recovered, d_lossEvents, d_idrSent, d_keys;
// current loss being tracked (recv thread only)
static struct { int active, trigger; uint32_t startFrame; uint16_t pkts, got, parity, broken; uint32_t frameBytes;
                double t0, gap; int idr, keys; } g_loss;
static double g_lastPktUs, g_prevPktUs;
static volatile LONG g_decStall;   // main thread -> recv thread: the decoder lost its reference chain
static double d_waitKeySince, d_waitKeyUs, d_maxAssembleUs, d_lastPresent, d_maxPresentGap, d_maxDecode, d_maxArrivalGap, d_lastArrival;

static void send_idr(void);
static int group_size(const Slot *s, int g);

// Snapshot of the frame we were waiting for when it was given up on.
static void loss_begin(int trigger) {
    if (g_loss.active) return;   // still recovering from the previous one: same event
    Slot *ps = &g_slots[g_nextFrame % SLOTS];
    memset(&g_loss, 0, sizeof g_loss);
    g_loss.active = 1; g_loss.trigger = trigger; g_loss.startFrame = g_nextFrame; g_loss.t0 = now_us();
    g_loss.gap = g_prevPktUs > 0 ? g_lastPktUs - g_prevPktUs : 0;
    if (ps->used && ps->frame == g_nextFrame) {
        int dataGot = 0, parGot = 0, broken = 0;
        for (int i = 0; i < ps->count; i++) dataGot += ps->have[i];
        for (int g = 0; g < ps->ngroups; g++) {
            parGot += ps->haveParity[g];
            int missing = group_size(ps, g) - ps->groupRecvd[g];
            broken += missing > 1 || (missing == 1 && !ps->haveParity[g]);
        }
        g_loss.pkts = (uint16_t)ps->count; g_loss.got = (uint16_t)dataGot; g_loss.parity = (uint16_t)parGot;
        g_loss.broken = (uint16_t)broken; g_loss.frameBytes = ps->frameBytes;
    }
}

static void loss_end(uint32_t keyFrame, uint32_t keyBytes) {
    if (!g_loss.active) return;
    g_loss.active = 0;
    LossPkt r = {0x13, (uint8_t)g_loss.trigger, {0}, g_loss.startFrame, keyFrame - g_loss.startFrame,
                 g_loss.pkts, g_loss.got, g_loss.parity, g_loss.broken, (uint32_t)g_loss.gap, (uint32_t)(now_us() - g_loss.t0),
                 (uint16_t)g_loss.idr, (uint16_t)g_loss.keys, g_loss.frameBytes, keyBytes};
    if (g_havePeer) sendto(g_udp, (char *)&r, sizeof r, 0, (struct sockaddr *)&g_peer, sizeof g_peer);
    plog("loss: trigger=%d frames=%u (from %u) broken frame %u/%u pkts parity %u groups-broken %u size %u B; gap before %.1f ms; "
         "recovered in %.1f ms (%d idr, %d keyframes seen, key %u B)",
         r.trigger, r.frames, r.startFrame, r.got, r.pkts, r.parity, r.broken, r.frameBytes, r.gapUs / 1000.0,
         r.recoverUs / 1000.0, r.idrReqs, r.keysSeen, keyBytes);
}

static void slot_reset(Slot *s, const PktHdr *h) {
    int ng = (h->count + h->group - 1) / h->group;
    s->used = 1; s->frame = h->frame; s->frameBytes = h->frameBytes; s->ts = h->tsUs;
    s->count = h->count; s->group = h->group; s->ngroups = ng; s->flags = h->flags; s->recvd = 0; s->done = 0; s->firstUs = now_us();
    s->data = realloc(s->data, (size_t)h->count * PAYLOAD);
    s->parity = realloc(s->parity, (size_t)ng * PAYLOAD);
    s->have = realloc(s->have, h->count); memset(s->have, 0, h->count);
    s->haveParity = realloc(s->haveParity, ng); memset(s->haveParity, 0, ng);
    s->groupRecvd = realloc(s->groupRecvd, ng * 2); memset(s->groupRecvd, 0, ng * 2);
}

// Groups are interleaved: packet i belongs to group i % ngroups, so a burst of consecutive
// losses lands in different groups. Returns 1 if every group is complete (recovering one
// missing packet per group from its parity).
static int group_size(const Slot *s, int g) { return (s->count - g + s->ngroups - 1) / s->ngroups; }

static int slot_try_complete(Slot *s) {
    if (s->recvd < s->count - s->ngroups) return 0;
    for (int g = 0; g < s->ngroups; g++) {
        int missing = group_size(s, g) - s->groupRecvd[g];
        if (missing == 0) continue;
        if (missing > 1 || !s->haveParity[g]) return 0;
    }
    for (int g = 0; g < s->ngroups; g++) {
        if (s->groupRecvd[g] == group_size(s, g)) continue;
        int lostIdx = -1;
        for (int i = g; i < s->count; i += s->ngroups) if (!s->have[i]) { lostIdx = i; break; }
        uint64_t *d = (uint64_t *)(s->data + (size_t)lostIdx * PAYLOAD);
        memcpy(d, s->parity + (size_t)g * PAYLOAD, PAYLOAD);
        for (int i = g; i < s->count; i += s->ngroups) {
            if (i == lostIdx) continue;
            const uint64_t *src = (const uint64_t *)(s->data + (size_t)i * PAYLOAD);
            for (int k = 0; k < PAYLOAD / 8; k++) d[k] ^= src[k];
        }
        s->have[lostIdx] = 1;
        InterlockedIncrement(&d_recovered);
        s->recvd++;
    }
    return 1;
}

// MMCSS "Games" task: the scheduler favours these threads over normal ones (a game in the background,
// browser, etc.), which keeps receive/present latency flat under load. Same as Sunshine/Moonlight.
static void mmcss_join(void) {
    typedef HANDLE(WINAPI * AvSet)(LPCWSTR, LPDWORD);
    HMODULE m = LoadLibraryW(L"avrt.dll");
    AvSet fn = m ? (AvSet)(void *)GetProcAddress(m, "AvSetMmThreadCharacteristicsW") : NULL;
    DWORD idx = 0;
    if (!fn || !fn(L"Games", &idx)) plog("mmcss: not available (%lu)", GetLastError());
}

static void send_idr(void) {
    if (!g_havePeer) return;
    IdrReq r = {0x10, {0}, g_nextFrame - 1};
    sendto(g_udp, (char *)&r, sizeof r, 0, (struct sockaddr *)&g_peer, sizeof g_peer);
}

static void deliver(Slot *s) {
    QFrame f;
    f.len = (int)s->frameBytes;
    f.buf = malloc(f.len + AV_INPUT_BUFFER_PADDING_SIZE);
    memcpy(f.buf, s->data, f.len);
    memset(f.buf + f.len, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    f.key = s->flags & 1; f.ts = s->ts; f.arrivedUs = now_us();
    EnterCriticalSection(&g_qlock);
    int next = (g_qtail + 1) % 32;
    if (next == g_qhead) {  // renderer stalled: flush and resync on a keyframe
        loss_begin(4);
        while (g_qhead != g_qtail) { free(g_queue[g_qhead].buf); g_qhead = (g_qhead + 1) % 32; }
        InterlockedExchange(&g_needKey, 1);
        free(f.buf);
    } else {
        g_queue[g_qtail] = f; g_qtail = next;
    }
    LeaveCriticalSection(&g_qlock);
    SetEvent(g_qevent);
}

// picture adjustments (shader constant buffer layout, 16-byte aligned)
typedef struct { float brightness, contrast, saturation, gamma; float r, g, b, fullRange; } ColorParams;
static ColorParams g_color = {0, 1, 1, 1, 1, 1, 1, 0};
static CRITICAL_SECTION g_colorLock;
static volatile LONG g_colorDirty;

static void on_packet(const uint8_t *pkt, int len) {
    if (len >= (int)sizeof(ColorPkt) && pkt[0] == 3) {
        const ColorPkt *c = (const ColorPkt *)pkt;
        ColorParams p = {c->brightness, c->contrast, c->saturation, c->gamma > 0.05f ? c->gamma : 1, c->r, c->g, c->b, (float)c->fullRange};
        EnterCriticalSection(&g_colorLock);
        if (memcmp(&p, &g_color, sizeof p)) { g_color = p; InterlockedExchange(&g_colorDirty, 1); }
        LeaveCriticalSection(&g_colorLock);
        return;
    }
    if (len < (int)sizeof(PktHdr)) return;
    const PktHdr *h = (const PktHdr *)pkt;
    const uint8_t *payload = pkt + sizeof(PktHdr);
    int plen = len - (int)sizeof(PktHdr);
    if (h->count == 0 || h->count > MAX_PKTS || h->group == 0 || plen > PAYLOAD) return;
    if (!g_needKey && (int32_t)(h->frame - g_nextFrame) < 0) return;  // already delivered / skipped
    // Packets of a newer frame while the expected one is still incomplete: the Mac sends frames (and
    // their parity) strictly in order, so the expected frame can no longer complete. Ask for the
    // keyframe now instead of after this whole frame has arrived (saves up to a frame interval).
    if (!g_needKey && (int32_t)(h->frame - g_nextFrame) > 0 && !(h->flags & 1)) {
        Slot *ps = &g_slots[g_nextFrame % SLOTS];
        if (!(ps->used && ps->frame == g_nextFrame && ps->done)) {
            loss_begin(1);
            InterlockedAdd(&g_lost, (LONG)(h->frame - g_nextFrame));
            InterlockedExchange(&g_needKey, 1);
            InterlockedIncrement(&d_lossEvents);
            d_waitKeySince = now_us();
            g_nextFrame = h->frame;
            send_idr();
            return;
        }
    }

    Slot *s = &g_slots[h->frame % SLOTS];
    if (!s->used || s->frame != h->frame) { slot_reset(s, h); if (g_loss.active && (h->flags & 1)) g_loss.keys++; }
    if (s->done) return;

    if (h->type == 1) {
        if (h->index >= s->count || s->have[h->index]) return;
        uint8_t *dst = s->data + (size_t)h->index * PAYLOAD;
        memcpy(dst, payload, plen);
        if (plen < PAYLOAD) memset(dst + plen, 0, PAYLOAD - plen);
        s->have[h->index] = 1; s->recvd++; s->groupRecvd[h->index % s->ngroups]++;
    } else if (h->type == 2) {
        if (h->index >= s->ngroups || s->haveParity[h->index]) return;
        memcpy(s->parity + (size_t)h->index * PAYLOAD, payload, PAYLOAD);
        s->haveParity[h->index] = 1;
    } else return;

    if (!slot_try_complete(s)) return;
    s->done = 1;

    if (g_needKey) {
        if (!(s->flags & 1)) return;
        InterlockedExchange(&g_needKey, 0);
        loss_end(s->frame, s->frameBytes);
        if (d_waitKeySince > 0) { d_waitKeyUs += now_us() - d_waitKeySince; d_waitKeySince = 0; }
    } else if (s->frame != g_nextFrame) {
        if (!(s->flags & 1)) {
            // a frame in between never completed: the reference chain is broken
            loss_begin(2);
            InterlockedAdd(&g_lost, (LONG)(s->frame - g_nextFrame));
            InterlockedExchange(&g_needKey, 1);
            InterlockedIncrement(&d_lossEvents);
            d_waitKeySince = now_us();
            g_nextFrame = s->frame + 1;
            send_idr();
            return;
        }
    }
    g_nextFrame = s->frame + 1;
    InterlockedIncrement(&g_ok);
    if (s->flags & 1) InterlockedIncrement(&d_keys);
    { double t = now_us(), a = t - s->firstUs; if (a > d_maxAssembleUs) d_maxAssembleUs = a;
      if (d_lastArrival > 0 && t - d_lastArrival > d_maxArrivalGap) d_maxArrivalGap = t - d_lastArrival;
      d_lastArrival = t; }
    deliver(s);
}

static DWORD WINAPI recv_thread(void *arg) {
    (void)arg;
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
    mmcss_join();
    static uint8_t buf[2048];
    double lastIdr = 0, lastBeat = 0;
    for (;;) {
        struct sockaddr_in from; int fl = sizeof from;
        int n = recvfrom(g_udp, (char *)buf, sizeof buf, 0, (struct sockaddr *)&from, &fl);
        if (n > 0) {
            if (!g_havePeer || from.sin_addr.s_addr != g_peer.sin_addr.s_addr || from.sin_port != g_peer.sin_port) {
                g_peer = from; g_havePeer = 1;
                plog("video from %s:%d", inet_ntoa(from.sin_addr), ntohs(from.sin_port));
            }
            InterlockedIncrement(&d_pkts);
            g_prevPktUs = g_lastPktUs; g_lastPktUs = now_us();
            if (InterlockedExchange(&g_decStall, 0)) loss_begin(3);
            on_packet(buf, n);
        }
        double t = now_us();
        if (g_needKey && g_havePeer && t - lastIdr > 50000) { send_idr(); lastIdr = t; InterlockedIncrement(&d_idrSent); g_loss.idr++; }
        // heartbeat: lets the Mac notice a dead link within ~120 ms and pause instead of queueing stale video
        if (g_havePeer && t - lastBeat > 20000) {
            IdrReq hb = {0x12, {0}, g_nextFrame - 1};
            sendto(g_udp, (char *)&hb, sizeof hb, 0, (struct sockaddr *)&g_peer, sizeof g_peer);
            lastBeat = t;
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------------------------
// viewer: D3D11 presentation

static const char *g_hlsl =
    "Texture2D<float> ty : register(t0);\n"
    "Texture2D<float2> tc : register(t1);\n"
    "SamplerState sm : register(s0);\n"
    "cbuffer P : register(b0) { float bright, contrast, sat, gam; float3 tint; float full; };\n"
    "struct V { float4 p : SV_Position; float2 uv : TEXCOORD0; };\n"
    "V vs(uint id : SV_VertexID) { V o; float2 uv = float2((id << 1) & 2, id & 2); o.uv = uv;\n"
    "  o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); return o; }\n"
    "float4 ps(V i) : SV_Target {\n"
    "  float y = ty.Sample(sm, i.uv); float2 c = tc.Sample(sm, i.uv) - 0.5019608;\n"
    "  if (full < 0.5) { y = (y - 0.0627451) * 1.1643836; c *= 1.1383929; }\n"
    "  float3 rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);\n"
    "  rgb = (rgb - 0.5) * contrast + 0.5 + bright;\n"
    "  float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));\n"
    "  rgb = lerp(float3(l, l, l), rgb, sat);\n"
    "  rgb = pow(saturate(rgb), 1.0 / gam) * tint;\n"
    "  return float4(saturate(rgb), 1); }\n";

static ID3D11Device *g_dev;
static ID3D11DeviceContext *g_ctx;
static IDXGISwapChain1 *g_swap;
static ID3D11RenderTargetView *g_rtv;
static ID3D11Texture2D *g_nv12;
static ID3D11ShaderResourceView *g_srvY, *g_srvC;
static int g_texW, g_texH, g_winW, g_winH, g_tearing, g_vsync, g_changedHz, g_autoStop, g_autoStopPx = 40, g_autoStopGraceMs = 2000;
static DWORD g_startTick;
static int g_ins[4];                  // left/top/right/bottom: panel area kept black (covered by the laptop)
static HANDLE g_waitable;             // v-sync: signalled when the swap chain can take a frame without queueing

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_SETCURSOR: SetCursor(NULL); return TRUE;
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_CLOSE: DestroyWindow(h); return 0;
    case WM_DESTROY: PostQuitMessage(0); return 0;   // ends this window's thread
    case WM_TIMER: {
        // Emergency stop that works on any desktop (incl. the lock screen): Ctrl+Alt+Shift+F12
        static int was;
        int down = (GetAsyncKeyState(VK_CONTROL) & 0x8000) && (GetAsyncKeyState(VK_MENU) & 0x8000) &&
                   (GetAsyncKeyState(VK_SHIFT) & 0x8000) && (GetAsyncKeyState(VK_F12) & 0x8000);
        if (down && !was) {
            HANDLE ev = OpenEventW(EVENT_MODIFY_STATE, FALSE, L"Global\\PaneLinkHotkey");
            if (ev) { SetEvent(ev); CloseHandle(ev); }
        }
        was = down;
        // A fullscreen game (Valorant etc.) brought to the front can cover us: stay on top.
        static int tick;
        if (++tick % 5 == 0 && GetForegroundWindow() != h) {
            HWND above = GetWindow(h, GW_HWNDPREV);
            for (; above; above = GetWindow(above, GW_HWNDPREV)) {
                RECT r, mine, x; GetWindowRect(above, &r); GetWindowRect(h, &mine);
                if (IsWindowVisible(above) && IntersectRect(&x, &r, &mine)) {
                    SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                    break;
                }
            }
        }
        // Auto-off: someone is using this PC (key, click, scroll, or a real mouse move; desk bumps ignored)
        if (g_autoStop) {
            static DWORD lastInput; static POINT base, prev; static int armed;
            LASTINPUTINFO li = {sizeof li}; POINT p;
            GetLastInputInfo(&li); GetCursorPos(&p);
            if (!armed) { lastInput = li.dwTime; base = prev = p; armed = GetTickCount() - g_startTick > (DWORD)g_autoStopGraceMs; }
            else if (li.dwTime != lastInput) {
                lastInput = li.dwTime;
                int dx = p.x - base.x, dy = p.y - base.y;
                // input with the cursor not moving since the last check = key/click/scroll; small nudges
                // (desk bumps) only count once they add up to the configured distance
                int moved = g_autoStopPx > 0 && dx * dx + dy * dy > g_autoStopPx * g_autoStopPx, still = p.x == prev.x && p.y == prev.y;
                if (moved || still) {
                    plog("local input on Windows (%s): asking to stop", moved ? "mouse" : "keyboard/click");
                    HANDLE ev = OpenEventW(EVENT_MODIFY_STATE, FALSE, L"Global\\PaneLinkActivity");
                    if (ev) { SetEvent(ev); CloseHandle(ev); }
                    armed = 0; g_startTick = GetTickCount();   // don't spam while we're being stopped
                }
            }
            prev = p;
        }
        return 0;
    }
    }
    return DefWindowProcW(h, m, w, l);
}

static IDXGIAdapter1 *adapter_for(const wchar_t *device, IDXGIFactory2 **outFactory) {
    IDXGIFactory2 *f = NULL;
    CreateDXGIFactory1(&IID_IDXGIFactory2, (void **)&f);
    *outFactory = f;
    IDXGIAdapter1 *a;
    for (UINT i = 0; IDXGIFactory2_EnumAdapters1(f, i, &a) == S_OK; i++) {
        IDXGIOutput *o;
        for (UINT j = 0; IDXGIAdapter1_EnumOutputs(a, j, &o) == S_OK; j++) {
            DXGI_OUTPUT_DESC d; IDXGIOutput_GetDesc(o, &d); IDXGIOutput_Release(o);
            if (!wcscmp(d.DeviceName, device)) {
                DXGI_ADAPTER_DESC1 ad; IDXGIAdapter1_GetDesc1(a, &ad);
                plog("monitor %ls is on adapter %ls", device, ad.Description);
                return a;
            }
        }
        IDXGIAdapter1_Release(a);
    }
    plog("no adapter owns %ls, using default", device);
    IDXGIFactory2_EnumAdapters1(f, 0, &a);
    return a;
}

static IDXGIFactory2 *g_fac;
static ID3D11Buffer *g_cbuf;

// Same trick as Sunshine: as SYSTEM we may put this process in the GPU scheduler's realtime class,
// so the decode/present work preempts a game's rendering instead of queueing behind it.
static void gpu_realtime(void) {
    typedef LONG(WINAPI * SetPrio)(HANDLE, int);
    SetPrio fn = (SetPrio)(void *)GetProcAddress(GetModuleHandleW(L"gdi32.dll"), "D3DKMTSetProcessSchedulingPriorityClass");
    LONG r = fn ? fn(GetCurrentProcess(), 5 /* D3DKMT_SCHEDULINGPRIORITYCLASS_REALTIME */) : -1;
    if (r) r = fn ? fn(GetCurrentProcess(), 4 /* HIGH */) : -1;
    plog("gpu scheduling priority: %s", r ? "default" : "raised");
}

static int d3d_init(const wchar_t *device) {
    IDXGIFactory2 *fac;
    IDXGIAdapter1 *ad = adapter_for(device, &fac);
    g_fac = fac;
    D3D_FEATURE_LEVEL fl[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
    HRESULT hr = D3D11CreateDevice((IDXGIAdapter *)ad, D3D_DRIVER_TYPE_UNKNOWN, NULL,
                                   D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                   fl, 2, D3D11_SDK_VERSION, &g_dev, NULL, &g_ctx);
    if (FAILED(hr)) { plog("D3D11CreateDevice failed %lx", hr); return 0; }

    // decoder and renderer share the immediate context from different call sites: make it safe
    ID3D10Multithread *mt;
    if (SUCCEEDED(ID3D11Device_QueryInterface(g_dev, &IID_ID3D10Multithread, (void **)&mt))) {
        ID3D10Multithread_SetMultithreadProtected(mt, TRUE); ID3D10Multithread_Release(mt);
    }

    IDXGIFactory5 *f5;
    if (SUCCEEDED(IDXGIFactory2_QueryInterface(fac, &IID_IDXGIFactory5, (void **)&f5))) {
        BOOL allow = FALSE;
        IDXGIFactory5_CheckFeatureSupport(f5, DXGI_FEATURE_PRESENT_ALLOW_TEARING, &allow, sizeof allow);
        g_tearing = allow; IDXGIFactory5_Release(f5);
    }
    ID3DBlob *vsb, *psb, *err = NULL;
    if (FAILED(D3DCompile(g_hlsl, strlen(g_hlsl), NULL, NULL, NULL, "vs", "vs_4_0", 0, 0, &vsb, &err)) ||
        FAILED(D3DCompile(g_hlsl, strlen(g_hlsl), NULL, NULL, NULL, "ps", "ps_4_0", 0, 0, &psb, &err))) {
        plog("shader compile failed: %s", err ? (char *)ID3D10Blob_GetBufferPointer(err) : "?");
        return 0;
    }
    ID3D11VertexShader *vs; ID3D11PixelShader *ps;
    ID3D11Device_CreateVertexShader(g_dev, ID3D10Blob_GetBufferPointer(vsb), ID3D10Blob_GetBufferSize(vsb), NULL, &vs);
    ID3D11Device_CreatePixelShader(g_dev, ID3D10Blob_GetBufferPointer(psb), ID3D10Blob_GetBufferSize(psb), NULL, &ps);
    D3D11_SAMPLER_DESC smd = {0};
    smd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    smd.AddressU = smd.AddressV = smd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    smd.MaxLOD = D3D11_FLOAT32_MAX;
    ID3D11SamplerState *smp; ID3D11Device_CreateSamplerState(g_dev, &smd, &smp);
    ID3D11DeviceContext_IASetPrimitiveTopology(g_ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(g_ctx, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(g_ctx, ps, NULL, 0);
    ID3D11DeviceContext_PSSetSamplers(g_ctx, 0, 1, &smp);
    D3D11_BUFFER_DESC bd = {0};
    bd.ByteWidth = sizeof(ColorParams); bd.Usage = D3D11_USAGE_DEFAULT; bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    D3D11_SUBRESOURCE_DATA init = {&g_color, 0, 0};
    ID3D11Device_CreateBuffer(g_dev, &bd, &init, &g_cbuf);
    ID3D11DeviceContext_PSSetConstantBuffers(g_ctx, 0, 1, &g_cbuf);
    // the picture goes into the uncovered part of the panel; the rest is cleared black every frame
    float vw = (float)(g_winW - g_ins[0] - g_ins[2]), vh = (float)(g_winH - g_ins[1] - g_ins[3]);
    if (vw < 64 || vh < 64) { memset(g_ins, 0, sizeof g_ins); vw = (float)g_winW; vh = (float)g_winH; }
    D3D11_VIEWPORT vp = {(float)g_ins[0], (float)g_ins[1], vw, vh, 0, 1};
    ID3D11DeviceContext_RSSetViewports(g_ctx, 1, &vp);
    IDXGIDevice1 *dd;
    if (SUCCEEDED(ID3D11Device_QueryInterface(g_dev, &IID_IDXGIDevice1, (void **)&dd))) {
        IDXGIDevice1_SetMaximumFrameLatency(dd, 1);
        // a game running in the background (Valorant uncapped in its menu) must not starve us
        IDXGIDevice1_SetGPUThreadPriority(dd, 7);
        IDXGIDevice1_Release(dd);
    }
    gpu_realtime();
    plog("d3d device ready, tearing=%d", g_tearing);
    return 1;
}

static void draw_current(void);

// Window-bound part: recreated whenever the viewer moves to another desktop (lock/unlock).
static int surface_create(HWND hwnd) {
    HRESULT hr;
    IDXGIFactory2 *fac = g_fac;
    DXGI_SWAP_CHAIN_DESC1 sd = {0};
    sd.Width = g_winW; sd.Height = g_winH;
    sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    sd.Flags = (g_tearing ? DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING : 0) | (g_vsync ? DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT : 0);
    hr = IDXGIFactory2_CreateSwapChainForHwnd(fac, (IUnknown *)g_dev, hwnd, &sd, NULL, NULL, &g_swap);
    if (FAILED(hr)) { plog("CreateSwapChainForHwnd failed %lx", hr); return 0; }
    if (g_vsync) {
        // Tear-free without a queue: never more than one frame waiting for the next refresh, so a
        // picture is shown at the very next vblank (adds 0..1 refresh, ~4 ms average at 120 Hz).
        IDXGISwapChain2 *s2;
        if (SUCCEEDED(IDXGISwapChain1_QueryInterface(g_swap, &IID_IDXGISwapChain2, (void **)&s2))) {
            IDXGISwapChain2_SetMaximumFrameLatency(s2, 1);
            g_waitable = IDXGISwapChain2_GetFrameLatencyWaitableObject(s2);
            IDXGISwapChain2_Release(s2);
        }
    }
    IDXGIFactory2_MakeWindowAssociation(fac, hwnd, DXGI_MWA_NO_ALT_ENTER);
    ID3D11Texture2D *bb;
    IDXGISwapChain1_GetBuffer(g_swap, 0, &IID_ID3D11Texture2D, (void **)&bb);
    ID3D11Device_CreateRenderTargetView(g_dev, (ID3D11Resource *)bb, NULL, &g_rtv);
    ID3D11Texture2D_Release(bb);
    if (g_nv12) draw_current();   // re-show the last picture immediately
    else {
        float black[4] = {0, 0, 0, 1};
        ID3D11DeviceContext_ClearRenderTargetView(g_ctx, g_rtv, black);
        IDXGISwapChain1_Present(g_swap, 0, g_tearing ? DXGI_PRESENT_ALLOW_TEARING : 0);
    }
    plog("surface ready %dx%d", g_winW, g_winH);
    return 1;
}

static void surface_destroy(void) {
    ID3D11DeviceContext_OMSetRenderTargets(g_ctx, 0, NULL, NULL);
    if (g_rtv) { ID3D11RenderTargetView_Release(g_rtv); g_rtv = NULL; }
    if (g_swap) { IDXGISwapChain1_Release(g_swap); g_swap = NULL; }
    if (g_waitable) { CloseHandle(g_waitable); g_waitable = NULL; }
    ID3D11DeviceContext_Flush(g_ctx);
}

static void ensure_nv12(int w, int h) {
    w &= ~1; h &= ~1;
    if (g_nv12 && g_texW == w && g_texH == h) return;
    if (g_srvY) ID3D11ShaderResourceView_Release(g_srvY);
    if (g_srvC) ID3D11ShaderResourceView_Release(g_srvC);
    if (g_nv12) ID3D11Texture2D_Release(g_nv12);
    D3D11_TEXTURE2D_DESC td = {0};
    td.Width = w; td.Height = h; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_NV12; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    ID3D11Device_CreateTexture2D(g_dev, &td, NULL, &g_nv12);
    D3D11_SHADER_RESOURCE_VIEW_DESC sv = {0};
    sv.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D; sv.Texture2D.MipLevels = 1;
    sv.Format = DXGI_FORMAT_R8_UNORM;
    ID3D11Device_CreateShaderResourceView(g_dev, (ID3D11Resource *)g_nv12, &sv, &g_srvY);
    sv.Format = DXGI_FORMAT_R8G8_UNORM;
    ID3D11Device_CreateShaderResourceView(g_dev, (ID3D11Resource *)g_nv12, &sv, &g_srvC);
    g_texW = w; g_texH = h;
    plog("stream texture %dx%d", w, h);
}

static void upload_frame(AVFrame *fr) {
    ensure_nv12(fr->width, fr->height);
    ID3D11Texture2D *src = (ID3D11Texture2D *)fr->data[0];
    UINT slice = (UINT)(intptr_t)fr->data[1];
    D3D11_BOX box = {0, 0, 0, (UINT)g_texW, (UINT)g_texH, 1};
    ID3D11DeviceContext_CopySubresourceRegion(g_ctx, (ID3D11Resource *)g_nv12, 0, 0, 0, 0, (ID3D11Resource *)src, slice, &box);
}

static void draw_current(void) {
    if (!g_swap || !g_nv12) return;
    ID3D11ShaderResourceView *srvs[2] = {g_srvY, g_srvC};
    ID3D11DeviceContext_OMSetRenderTargets(g_ctx, 1, &g_rtv, NULL);
    if (g_ins[0] | g_ins[1] | g_ins[2] | g_ins[3]) { float black[4] = {0, 0, 0, 1}; ID3D11DeviceContext_ClearRenderTargetView(g_ctx, g_rtv, black); }
    if (g_waitable) WaitForSingleObject(g_waitable, 40);   // previous frame is on screen: this one makes the next vblank
    ID3D11DeviceContext_PSSetShaderResources(g_ctx, 0, 2, srvs);
    ID3D11DeviceContext_Draw(g_ctx, 3, 0);
    IDXGISwapChain1_Present(g_swap, g_vsync ? 1 : 0, (!g_vsync && g_tearing) ? DXGI_PRESENT_ALLOW_TEARING : 0);
}

static enum AVPixelFormat get_fmt(AVCodecContext *c, const enum AVPixelFormat *f) {
    (void)c;
    for (; *f != AV_PIX_FMT_NONE; f++) if (*f == AV_PIX_FMT_D3D11) return *f;
    plog("decoder offered no D3D11 format");
    return AV_PIX_FMT_NONE;
}

// A 120 fps stream on a 144 Hz panel shows frames for 1 or 2 refreshes (judder). Switch the
// panel to the stream rate for the session; restore_refresh() puts the saved mode back on exit.
static void match_refresh(Monitor *m, int hz) {
    if (hz <= 0 || m->hz == hz) return;
    DEVMODEW dm = {0}; dm.dmSize = sizeof dm;
    EnumDisplaySettingsW(m->device, ENUM_CURRENT_SETTINGS, &dm);
    dm.dmDisplayFrequency = hz;
    dm.dmFields = DM_DISPLAYFREQUENCY;
    LONG r = ChangeDisplaySettingsExW(m->device, &dm, NULL, CDS_FULLSCREEN, NULL);
    plog("switch %ls %d Hz -> %d Hz: %s (%ld)", m->device, m->hz, hz, r == DISP_CHANGE_SUCCESSFUL ? "ok" : "failed", r);
    if (r == DISP_CHANGE_SUCCESSFUL) { m->hz = hz; g_changedHz = 1; Sleep(300); }
}

static void restore_refresh(const wchar_t *device) {
    if (!g_changedHz) return;
    LONG r = ChangeDisplaySettingsExW(device, NULL, NULL, 0, NULL);
    plog("restored %ls saved refresh (%ld)", device, r);
    g_changedHz = 0;
}

// --- desktop following: the lock screen / UAC / login UI live on the "Winlogon" desktop ---------

static wchar_t g_deskName[64];

static HDESK input_desktop(wchar_t *name, int len) {
    HDESK d = OpenInputDesktop(0, FALSE, GENERIC_ALL);
    if (!d) return NULL;
    name[0] = 0;
    GetUserObjectInformationW(d, UOI_NAME, name, len * sizeof(wchar_t), NULL);
    return d;
}

static HWND make_window(Monitor *mon) {
    HWND h = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"PaneLinkViewer", L"PaneLink",
                             WS_POPUP | WS_VISIBLE, mon->x, mon->y, mon->w, mon->h, NULL, NULL, GetModuleHandleW(NULL), NULL);
    SetWindowPos(h, HWND_TOPMOST, mon->x, mon->y, mon->w, mon->h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    SetTimer(h, 1, 100, NULL);
    return h;
}

// A thread can't change desktops once it has owned a window, so every desktop gets a fresh tiny
// thread that attaches first and then owns the window + message pump. Rendering stays on the main
// thread and just presents into whichever window is current.
typedef struct { HDESK desk; Monitor *mon; HWND hwnd; HANDLE ready, thread; } WinThread;
static WinThread *g_wt;

static DWORD WINAPI window_thread(void *arg) {
    WinThread *w = arg;
    if (!SetThreadDesktop(w->desk)) plog("SetThreadDesktop failed %lu", GetLastError());
    w->hwnd = make_window(w->mon);
    SetEvent(w->ready);
    MSG m;
    while (GetMessageW(&m, NULL, 0, 0) > 0) DispatchMessageW(&m);
    return 0;
}

// Moves the viewer onto whatever desktop is on screen (Default <-> Winlogon on lock/unlock/UAC).
// Keeps the D3D device, decoder and last picture: one swapchain rebuild, no stream restart.
static int follow_input_desktop(HWND *hwnd, Monitor *mon) {
    wchar_t name[64];
    HDESK d = input_desktop(name, 64);
    if (!d) return 0;
    if (g_wt && !wcscmp(name, g_deskName)) { CloseDesktop(d); return 0; }
    if (g_wt) {
        surface_destroy();
        PostMessageW(g_wt->hwnd, WM_CLOSE, 0, 0);
        WaitForSingleObject(g_wt->thread, 1000);
        CloseHandle(g_wt->thread); CloseHandle(g_wt->ready); CloseDesktop(g_wt->desk);
        free(g_wt); g_wt = NULL;
    }
    WinThread *w = calloc(1, sizeof *w);
    w->desk = d; w->mon = mon; w->ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    w->thread = CreateThread(NULL, 0, window_thread, w, 0, NULL);
    WaitForSingleObject(w->ready, 2000);
    g_wt = w;
    wcsncpy(g_deskName, name, 64);
    *hwnd = w->hwnd;
    if (*hwnd) surface_create(*hwnd);
    plog("now on desktop %ls", name);
    return 1;
}

// "shot" helper: screenshot of the input desktop -> BMP (diagnostics; runs as SYSTEM in the console)
// --- "dash" helper: shows klipper's rendered dashboard PNGs on every monitor ------------------
// Landscape monitors get /render/main.png, portrait ones /render/detail.png. Lives on the lock
// screen (Winlogon desktop) only: exits when someone touches the PC, logs in, or the agent says stop.

typedef struct { HWND hwnd; RECT r; int portrait; } DashWin;
static DashWin g_dw[MAX_MON];
static int g_ndw;
static HBITMAP g_dashBmp[2];            // 0 = main, 1 = detail
static int g_dashBmpW[2], g_dashBmpH[2];
static CRITICAL_SECTION g_dashLock;
static wchar_t g_dashHost[128];
static INTERNET_PORT g_dashPort;
static BYTE *dash_get(const wchar_t *path, DWORD *outSize);

// The clock is drawn here, not in the image (klipper leaves it out), so it can change smoothly:
// on a new minute the old digit slides up and fades while the new one slides in (650 ms, ~60 fps).
// Digits come from klipper as a transparent strip in the dashboard's own font (/render/glyphs.png).
typedef struct { int valid, x, y, w, h, font, h24, nsx, sx[8]; } ClockBox;   // in main-image pixels
static ClockBox g_clk;
static HBITMAP g_glyph;                 // 32-bit premultiplied BGRA strip "0123456789:"
static int g_glyphH, g_glyphFont, g_gcx[11], g_gcw[11];
static wchar_t g_clkShown[8], g_clkPrev[8];
static ULONGLONG g_clkAnimStart;
#define CLOCK_ANIM_MS 650

static int json_int(const char *js, const char *key, int *out) {
    char k[32]; snprintf(k, sizeof k, "\"%s\":", key);
    const char *p = strstr(js, k);
    return p && sscanf(p + strlen(k), " %d", out) == 1;
}

static int json_ints(const char *js, const char *key, int *out, int max) {
    char k[32]; snprintf(k, sizeof k, "\"%s\":", key);
    const char *p = strstr(js, k);
    if (!p || !(p = strchr(p, '['))) return 0;
    int n = 0;
    for (p++; n < max && *p && *p != ']';) {
        char *e; long v = strtol(p, &e, 10);
        if (e == p) { p++; continue; }
        out[n++] = (int)v; p = e;
    }
    return n;
}

static int get_json(const wchar_t *path, char *js, int cap) {
    DWORD size = 0; BYTE *b = dash_get(path, &size);
    if (!b) return 0;
    int n = size < (DWORD)cap - 1 ? (int)size : cap - 1;
    memcpy(js, b, n); js[n] = 0; free(b);
    return 1;
}

static HBITMAP dash_fetch_fmt(const wchar_t *path, int *w, int *h, REFWICPixelFormatGUID fmt);

static void dash_fetch_layout(void) {
    char js[1024];
    if (!get_json(L"/render/main.json", js, sizeof js)) return;
    ClockBox c = {0};
    c.valid = json_int(js, "x", &c.x) && json_int(js, "y", &c.y) && json_int(js, "w", &c.w) && json_int(js, "h", &c.h) && json_int(js, "font", &c.font);
    json_int(js, "h24", &c.h24);
    c.nsx = json_ints(js, "sx", c.sx, 8);
    if (c.nsx < 4) c.valid = 0;
    if (c.valid && c.font != g_glyphFont && get_json(L"/render/glyphs.json", js, sizeof js)) {   // (re)load the digit strip
        int gw, gh, cx[11], cw[11];
        if (json_ints(js, "cx", cx, 11) == 11 && json_ints(js, "cw", cw, 11) == 11) {
            HBITMAP g = dash_fetch_fmt(L"/render/glyphs.png", &gw, &gh, &GUID_WICPixelFormat32bppPBGRA);
            if (g) {
                EnterCriticalSection(&g_dashLock);
                if (g_glyph) DeleteObject(g_glyph);
                g_glyph = g; g_glyphH = gh; g_glyphFont = c.font;
                memcpy(g_gcx, cx, sizeof cx); memcpy(g_gcw, cw, sizeof cw);
                LeaveCriticalSection(&g_dashLock);
            }
        }
    }
    EnterCriticalSection(&g_dashLock);
    g_clk = c;
    LeaveCriticalSection(&g_dashLock);
}

static void clock_text(wchar_t *out, int h24) {
    SYSTEMTIME t; GetLocalTime(&t);
    int h = t.wHour;
    if (!h24) { h %= 12; if (!h) h = 12; }
    swprintf(out, 8, L"%02d:%02d", h, t.wMinute);
}

static void blit_glyph(HDC dc, HDC gdc, wchar_t ch, int x, int y, double sx, double sy, int alpha) {
    int i = ch == L':' ? 10 : (ch >= L'0' && ch <= L'9') ? ch - L'0' : -1;
    if (i < 0 || alpha <= 0) return;
    BLENDFUNCTION bf = {AC_SRC_OVER, 0, (BYTE)(alpha > 255 ? 255 : alpha), AC_SRC_ALPHA};
    AlphaBlend(dc, x, y, (int)(g_gcw[i] * sx + .5), (int)(g_glyphH * sy + .5), gdc, g_gcx[i], 0, g_gcw[i], g_glyphH, bf);
}

// Draws the clock over the already-painted image in dc (off-screen buffer). sx/sy: window px per image px.
static void draw_clock(HDC dc, double sx, double sy) {
    EnterCriticalSection(&g_dashLock);
    ClockBox c = g_clk;
    if (!c.valid || !g_glyph || !g_clkShown[0]) { LeaveCriticalSection(&g_dashLock); return; }
    double p = 1;
    if (g_clkAnimStart) {
        p = (double)(GetTickCount64() - g_clkAnimStart) / CLOCK_ANIM_MS;
        if (p >= 1) { p = 1; g_clkAnimStart = 0; }
    }
    double e = 1 - pow(1 - p, 3);   // ease-out cubic
    HDC gdc = CreateCompatibleDC(dc);
    HGDIOBJ old = SelectObject(gdc, g_glyph);
    int y = (int)(c.y * sy), h = (int)(g_glyphH * sy + .5), lift = (int)(g_glyphH * sy * 0.35);
    int n = (int)wcslen(g_clkShown);
    for (int i = 0; i < n && i < c.nsx; i++) {
        int x = (int)(c.sx[i] * sx);
        int changed = g_clkAnimStart && i < (int)wcslen(g_clkPrev) && g_clkPrev[i] != g_clkShown[i];
        if (!changed) { blit_glyph(dc, gdc, g_clkShown[i], x, y, sx, sy, 255); continue; }
        int idx = g_clkShown[i] == L':' ? 10 : g_clkShown[i] - L'0';
        SaveDC(dc);
        IntersectClipRect(dc, x, y, x + (int)(g_gcw[idx] * sx + .5), y + h);   // digits slide inside their own slot
        blit_glyph(dc, gdc, g_clkPrev[i], x, y - (int)(e * lift), sx, sy, (int)((1 - e) * 255));
        blit_glyph(dc, gdc, g_clkShown[i], x, y + (int)((1 - e) * lift), sx, sy, (int)(e * 255));
        RestoreDC(dc, -1);
    }
    SelectObject(gdc, old); DeleteDC(gdc);
    LeaveCriticalSection(&g_dashLock);
}

static BOOL CALLBACK dash_mon_cb(HMONITOR hm, HDC dc, LPRECT r, LPARAM lp) {
    (void)hm; (void)dc; (void)lp;
    if (g_ndw < MAX_MON) { g_dw[g_ndw].r = *r; g_dw[g_ndw].portrait = (r->bottom - r->top) > (r->right - r->left); g_ndw++; }
    return TRUE;
}

// Plain HTTP GET to klipper; returns a malloc'd body (caller frees) or NULL.
static BYTE *dash_get(const wchar_t *path, DWORD *outSize) {
    BYTE *body = NULL; DWORD size = 0;
    HINTERNET ses = WinHttpOpen(L"MorningDash/1.0", WINHTTP_ACCESS_TYPE_NO_PROXY, NULL, NULL, 0);
    HINTERNET con = ses ? WinHttpConnect(ses, g_dashHost, g_dashPort, 0) : NULL;
    HINTERNET req = con ? WinHttpOpenRequest(con, L"GET", path, NULL, NULL, NULL, 0) : NULL;
    if (req) WinHttpSetTimeouts(req, 3000, 3000, 5000, 10000);
    if (req && WinHttpSendRequest(req, NULL, 0, NULL, 0, 0, 0) && WinHttpReceiveResponse(req, NULL)) {
        DWORD status = 0, sl = sizeof status;
        WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, NULL, &status, &sl, NULL);
        if (status == 200) {
            DWORD avail, got;
            while (WinHttpQueryDataAvailable(req, &avail) && avail) {
                BYTE *nb = realloc(body, size + avail);
                if (!nb) break;
                body = nb;
                if (!WinHttpReadData(req, body + size, avail, &got)) break;
                size += got;
            }
        }
    }
    if (req) WinHttpCloseHandle(req);
    if (con) WinHttpCloseHandle(con);
    if (ses) WinHttpCloseHandle(ses);
    if (!size) { free(body); return NULL; }
    *outSize = size;
    return body;
}

// GET the PNG over HTTP and decode it (WIC) into a 32-bit DIB.
static HBITMAP dash_fetch_fmt(const wchar_t *path, int *w, int *h, REFWICPixelFormatGUID fmt) {
    HBITMAP bmp = NULL;
    DWORD size = 0;
    BYTE *body = dash_get(path, &size);
    if (!body) return NULL;

    IWICImagingFactory *fac = NULL; IWICStream *st = NULL; IWICBitmapDecoder *dec = NULL;
    IWICBitmapFrameDecode *fr = NULL; IWICFormatConverter *cv = NULL;
    if (SUCCEEDED(CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, (void **)&fac)) &&
        SUCCEEDED(IWICImagingFactory_CreateStream(fac, &st)) && SUCCEEDED(IWICStream_InitializeFromMemory(st, body, size)) &&
        SUCCEEDED(IWICImagingFactory_CreateDecoderFromStream(fac, (IStream *)st, NULL, WICDecodeMetadataCacheOnLoad, &dec)) &&
        SUCCEEDED(IWICBitmapDecoder_GetFrame(dec, 0, &fr)) && SUCCEEDED(IWICImagingFactory_CreateFormatConverter(fac, &cv)) &&
        SUCCEEDED(IWICFormatConverter_Initialize(cv, (IWICBitmapSource *)fr, fmt, WICBitmapDitherTypeNone, NULL, 0, WICBitmapPaletteTypeCustom))) {
        UINT bw, bh;
        IWICFormatConverter_GetSize(cv, &bw, &bh);
        BITMAPINFO bi = {0};
        bi.bmiHeader.biSize = sizeof bi.bmiHeader; bi.bmiHeader.biWidth = bw; bi.bmiHeader.biHeight = -(LONG)bh;
        bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 32; bi.bmiHeader.biCompression = BI_RGB;
        void *bits = NULL;
        bmp = CreateDIBSection(NULL, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
        if (bmp && FAILED(IWICFormatConverter_CopyPixels(cv, NULL, bw * 4, bw * 4 * bh, bits))) { DeleteObject(bmp); bmp = NULL; }
        *w = bw; *h = bh;
    }
    if (cv) IWICFormatConverter_Release(cv);
    if (fr) IWICBitmapFrameDecode_Release(fr);
    if (dec) IWICBitmapDecoder_Release(dec);
    if (st) IWICStream_Release(st);
    if (fac) IWICImagingFactory_Release(fac);
    free(body);
    return bmp;
}

static HBITMAP dash_fetch(const wchar_t *path, int *w, int *h) { return dash_fetch_fmt(path, w, h, &GUID_WICPixelFormat32bppBGRA); }

static DWORD WINAPI dash_fetch_thread(void *arg) {
    (void)arg;
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    for (int n = 0;; n++) {
        for (int i = 0; i < 2; i++) {
            int w, h;
            HBITMAP b = dash_fetch(i ? L"/render/detail.png" : L"/render/main.png", &w, &h);
            if (!b) { if (n % 12 == 0) plog("dash: fetch %s failed", i ? "detail" : "main"); continue; }
            EnterCriticalSection(&g_dashLock);
            if (g_dashBmp[i]) DeleteObject(g_dashBmp[i]);
            g_dashBmp[i] = b; g_dashBmpW[i] = w; g_dashBmpH[i] = h;
            LeaveCriticalSection(&g_dashLock);
        }
        dash_fetch_layout();
        for (int i = 0; i < g_ndw; i++) InvalidateRect(g_dw[i].hwnd, NULL, FALSE);
        Sleep(5000);
    }
    return 0;
}

static void clock_invalidate(HWND h) {
    RECT rc; GetClientRect(h, &rc);
    if (rc.bottom > rc.right || !g_clk.valid || !g_dashBmpW[0]) return;
    double sx = (double)rc.right / g_dashBmpW[0], sy = (double)rc.bottom / g_dashBmpH[0];
    RECT r = {(LONG)(g_clk.x * sx), (LONG)(g_clk.y * sy) - 10, (LONG)(g_clk.x * sx + g_clk.w * sx) + 40, (LONG)(g_clk.y * sy + g_clk.h * sy) + 10};
    InvalidateRect(h, &r, FALSE);
}

static LRESULT CALLBACK dash_wndproc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_TIMER: {
        if (w == 3) {   // twice a second: did the minute change?
            wchar_t now[8]; clock_text(now, g_clk.h24);
            if (!g_clkShown[0]) { wcscpy(g_clkShown, now); clock_invalidate(h); }
            else if (wcscmp(now, g_clkShown)) {
                wcscpy(g_clkPrev, g_clkShown); wcscpy(g_clkShown, now);
                g_clkAnimStart = GetTickCount64();
                SetTimer(h, 2, 15, NULL);
            }
        } else if (w == 2) {   // animating: ~60 fps until done, then one last frame
            if (!g_clkAnimStart) KillTimer(h, 2);
            clock_invalidate(h);
        }
        return 0;
    }
    case WM_SETCURSOR: SetCursor(NULL); return TRUE;
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        RECT rc; GetClientRect(h, &rc);
        int portrait = rc.bottom > rc.right;
        EnterCriticalSection(&g_dashLock);
        HBITMAP b = g_dashBmp[portrait];
        if (b) {
            // compose off-screen (image + clock), then one blit: no flashing
            HDC buf = CreateCompatibleDC(dc); HBITMAP bb = CreateCompatibleBitmap(dc, rc.right, rc.bottom);
            HGDIOBJ ob = SelectObject(buf, bb);
            HDC mem = CreateCompatibleDC(dc); HGDIOBJ old = SelectObject(mem, b);
            if (g_dashBmpW[portrait] == rc.right && g_dashBmpH[portrait] == rc.bottom)
                BitBlt(buf, ps.rcPaint.left, ps.rcPaint.top, ps.rcPaint.right - ps.rcPaint.left, ps.rcPaint.bottom - ps.rcPaint.top, mem, ps.rcPaint.left, ps.rcPaint.top, SRCCOPY);
            else {
                SetStretchBltMode(buf, HALFTONE);
                StretchBlt(buf, 0, 0, rc.right, rc.bottom, mem, 0, 0, g_dashBmpW[portrait], g_dashBmpH[portrait], SRCCOPY);
            }
            SelectObject(mem, old); DeleteDC(mem);
            if (!portrait) draw_clock(buf, (double)rc.right / g_dashBmpW[0], (double)rc.bottom / g_dashBmpH[0]);
            BitBlt(dc, ps.rcPaint.left, ps.rcPaint.top, ps.rcPaint.right - ps.rcPaint.left, ps.rcPaint.bottom - ps.rcPaint.top, buf, ps.rcPaint.left, ps.rcPaint.top, SRCCOPY);
            SelectObject(buf, ob); DeleteObject(bb); DeleteDC(buf);
        } else {
            FillRect(dc, &rc, GetStockObject(BLACK_BRUSH));
            SetTextColor(dc, RGB(90, 93, 101)); SetBkMode(dc, TRANSPARENT);
            DrawTextW(dc, L"Good morning — loading your dashboard…", -1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        }
        LeaveCriticalSection(&g_dashLock);
        EndPaint(h, &ps);
        return 0;
    }
    }
    return DefWindowProcW(h, m, w, l);
}

static int run_dash(const char *base) {
    log_open("dash");
    InitializeCriticalSection(&g_dashLock);
    char host[128] = ""; int port = 80;
    if (sscanf(base, "http://%127[^:/]:%d", host, &port) < 1) { plog("dash: bad url %s", base); return 1; }
    MultiByteToWideChar(CP_UTF8, 0, host, -1, g_dashHost, 128);
    g_dashPort = (INTERNET_PORT)port;

    wchar_t desk[64];
    HDESK d = input_desktop(desk, 64);
    if (!d || !SetThreadDesktop(d)) { plog("dash: can't attach to input desktop (%lu)", GetLastError()); return 1; }
    if (_wcsicmp(desk, L"Winlogon")) { plog("dash: input desktop is %ls (someone is using the PC): not showing", desk); return 2; }
    HANDLE stopEv = OpenEventW(SYNCHRONIZE, FALSE, L"Global\\MorningDashStop");
    SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);

    WNDCLASSW wc = {0};
    wc.lpfnWndProc = dash_wndproc; wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"MorningDash"; wc.hbrBackground = GetStockObject(BLACK_BRUSH);
    RegisterClassW(&wc);
    EnumDisplayMonitors(NULL, NULL, dash_mon_cb, 0);
    for (int i = 0; i < g_ndw; i++) {
        RECT r = g_dw[i].r;
        g_dw[i].hwnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"MorningDash", L"Morning", WS_POPUP | WS_VISIBLE,
                                       r.left, r.top, r.right - r.left, r.bottom - r.top, NULL, NULL, wc.hInstance, NULL);
        SetWindowPos(g_dw[i].hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
        if (!g_dw[i].portrait) SetTimer(g_dw[i].hwnd, 3, 500, NULL);
        plog("dash: monitor %d %ldx%ld at %ld,%ld -> %s", i, r.right - r.left, r.bottom - r.top, r.left, r.top, g_dw[i].portrait ? "detail" : "main");
    }
    CreateThread(NULL, 0, dash_fetch_thread, NULL, 0, NULL);

    // input: a click or a key press ends the dashboard (after a short grace). Moving the mouse doesn't,
    // and GetLastInputInfo isn't used: devices waking up bump it with no one there.
    DWORD start = GetTickCount(); int armed = 0, tick = 0;
    for (;;) {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        if (stopEv && WaitForSingleObject(stopEv, 0) == WAIT_OBJECT_0) { plog("dash: asked to stop"); break; }
        int key = 0;
        for (int vk = 1; vk < 256 && !key; vk++)   // bit 0: pressed since the last poll, bit 15: down now
            if (GetAsyncKeyState(vk) & 0x8001) key = vk;
        if (!armed) armed = GetTickCount() - start > 3000;
        else if (key) { plog("dash: someone is at the PC (%s 0x%02x)", key <= VK_XBUTTON2 && key != VK_CANCEL ? "click" : "key", key); break; }
        if (++tick % 20 == 0) {   // every ~2 s: still on the lock screen? stay on top
            wchar_t now[64]; HDESK nd = input_desktop(now, 64);
            if (nd) { int changed = wcscmp(now, desk); CloseDesktop(nd); if (changed) { plog("dash: desktop changed to %ls", now); break; } }
            for (int i = 0; i < g_ndw; i++) SetWindowPos(g_dw[i].hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
        MsgWaitForMultipleObjects(0, NULL, FALSE, 100, QS_ALLINPUT);
    }
    for (int i = 0; i < g_ndw; i++) DestroyWindow(g_dw[i].hwnd);
    SetThreadExecutionState(ES_CONTINUOUS);
    return 0;
}

// --- "pincode" helper: the pairing code, big, on every monitor (lock screen included) -------------

static const char *g_pinCode, *g_pinName;
static HFONT g_pinBig, g_pinSmall;

static LRESULT CALLBACK pin_wndproc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    if (m == WM_PAINT) {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        RECT rc; GetClientRect(h, &rc);
        HBRUSH bg = CreateSolidBrush(RGB(20, 21, 24)); FillRect(dc, &rc, bg); DeleteObject(bg);
        SetBkMode(dc, TRANSPARENT);
        wchar_t t[160];
        RECT r = rc; r.top = rc.bottom * 12 / 100; r.bottom = rc.bottom * 30 / 100;
        SelectObject(dc, g_pinSmall); SetTextColor(dc, RGB(170, 174, 184));
        swprintf(t, 160, L"PaneLink: pair with %hs", g_pinName);
        DrawTextW(dc, t, -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        r.top = r.bottom; r.bottom = rc.bottom * 78 / 100;
        SelectObject(dc, g_pinBig); SetTextColor(dc, RGB(255, 255, 255));
        swprintf(t, 160, L"%.3hs %.3hs", g_pinCode, g_pinCode + 3);
        DrawTextW(dc, t, -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        r.top = r.bottom; r.bottom = rc.bottom * 92 / 100;
        SelectObject(dc, g_pinSmall); SetTextColor(dc, RGB(120, 124, 134));
        DrawTextW(dc, L"Type this code on your Mac", -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        EndPaint(h, &ps);
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

static BOOL CALLBACK pin_mon_cb(HMONITOR hm, HDC dc, LPRECT r, LPARAM lp) {
    (void)hm; (void)dc; (void)lp;
    int w = (r->right - r->left) * 2 / 5, h = w * 9 / 20;   // a card in the middle of each monitor
    HWND wnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"PaneLinkPin", L"PaneLink", WS_POPUP | WS_VISIBLE,
                               r->left + (r->right - r->left - w) / 2, r->top + (r->bottom - r->top - h) / 2, w, h, NULL, NULL, GetModuleHandleW(NULL), NULL);
    SetWindowPos(wnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    if (!g_pinBig) {
        g_pinBig = CreateFontW(-h * 42 / 100, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
        g_pinSmall = CreateFontW(-h * 8 / 100, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    }
    return TRUE;
}

static int run_pincode(const char *code, const char *name) {
    if (strlen(code) != 6) return 1;
    g_pinCode = code; g_pinName = name;
    wchar_t desk[64];
    HDESK d = input_desktop(desk, 64);
    if (d) SetThreadDesktop(d);
    HANDLE stop = OpenEventW(SYNCHRONIZE, FALSE, L"Global\\PaneLinkPinStop");
    SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED);
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = pin_wndproc; wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"PaneLinkPin"; wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    RegisterClassW(&wc);
    EnumDisplayMonitors(NULL, NULL, pin_mon_cb, 0);
    ULONGLONG until = GetTickCount64() + PAIR_MS;
    while (GetTickCount64() < until) {   // the agent ends us when pairing finishes, fails or expires
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        DWORD r = stop ? MsgWaitForMultipleObjects(1, &stop, FALSE, 200, QS_ALLINPUT) : MsgWaitForMultipleObjects(0, NULL, FALSE, 200, QS_ALLINPUT);
        if (stop && r == WAIT_OBJECT_0) break;
    }
    SetThreadExecutionState(ES_CONTINUOUS);
    return 0;
}

static int run_shot(const char *path) {
    wchar_t name[64];
    HDESK d = input_desktop(name, 64);
    if (d) SetThreadDesktop(d);
    int x = GetSystemMetrics(SM_XVIRTUALSCREEN), y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int w = GetSystemMetrics(SM_CXVIRTUALSCREEN), h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    HDC sdc = GetDC(NULL), mdc = CreateCompatibleDC(sdc);
    BITMAPINFO bi = {0};
    bi.bmiHeader.biSize = sizeof bi.bmiHeader; bi.bmiHeader.biWidth = w; bi.bmiHeader.biHeight = h;
    bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 24; bi.bmiHeader.biCompression = BI_RGB;
    void *bits; HBITMAP bmp = CreateDIBSection(sdc, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    SelectObject(mdc, bmp);
    BitBlt(mdc, 0, 0, w, h, sdc, x, y, SRCCOPY | CAPTUREBLT);
    int stride = (w * 3 + 3) & ~3;
    BITMAPFILEHEADER fh = {0x4D42, sizeof fh + sizeof bi.bmiHeader + stride * h, 0, 0, sizeof fh + sizeof bi.bmiHeader};
    FILE *f = fopen(path, "wb");
    if (!f) return 1;
    fwrite(&fh, sizeof fh, 1, f); fwrite(&bi.bmiHeader, sizeof bi.bmiHeader, 1, f); fwrite(bits, stride * h, 1, f);
    fclose(f);
    printf("desktop %ls %dx%d\n", name, w, h);
    return 0;
}

static int run_viewer(int argc, char **argv) {
    if (argc < 5) return 1;
    wchar_t device[32];
    MultiByteToWideChar(CP_UTF8, 0, argv[2], -1, device, 32);
    int port = atoi(argv[3]);
    const char *codec = argv[4];
    g_vsync = argc > 5 ? atoi(argv[5]) : 0;
    int wantHz = argc > 6 ? atoi(argv[6]) : 0;
    g_autoStop = argc > 7 ? atoi(argv[7]) : 0;
    if (argc > 8) g_autoStopPx = atoi(argv[8]);       // 0 = only keys/clicks/scroll count
    if (argc > 9) g_autoStopGraceMs = atoi(argv[9]);
    for (int i = 0; i < 4; i++) g_ins[i] = argc > 10 + i ? atoi(argv[10 + i]) : 0;
    g_startTick = GetTickCount();
    SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);
    char role[32]; snprintf(role, sizeof role, "viewer-%d", port);
    log_open(role);
    timeBeginPeriod(1);

    enum_monitors();
    Monitor *mon = NULL;
    for (int i = 0; i < g_nmons; i++) if (!wcscmp(g_mons[i].device, device)) mon = &g_mons[i];
    if (!mon) { plog("monitor %ls not found", device); return 1; }
    match_refresh(mon, wantHz);
    g_winW = mon->w; g_winH = mon->h;

    // keep the panels awake even on the lock screen while we're showing the Mac
    SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);
    wchar_t evName[64]; swprintf(evName, 64, L"Global\\PaneLinkStop-%d", port);
    HANDLE stopEv = OpenEventW(SYNCHRONIZE, FALSE, evName);

    WNDCLASSW wc = {0};
    wc.lpfnWndProc = wndproc; wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"PaneLinkViewer"; wc.hbrBackground = GetStockObject(BLACK_BRUSH);
    RegisterClassW(&wc);
    if (!d3d_init(device)) { restore_refresh(device); return 1; }
    HWND hwnd = NULL;
    follow_input_desktop(&hwnd, mon);

    const AVCodec *dec = avcodec_find_decoder(!strcmp(codec, "h264") ? AV_CODEC_ID_H264 : AV_CODEC_ID_HEVC);
    AVCodecContext *cc = avcodec_alloc_context3(dec);
    AVBufferRef *hw = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA);
    AVD3D11VADeviceContext *d3dc = ((AVHWDeviceContext *)hw->data)->hwctx;
    d3dc->device = g_dev; ID3D11Device_AddRef(g_dev);
    if (av_hwdevice_ctx_init(hw) < 0) { plog("hwdevice init failed"); return 1; }
    cc->hw_device_ctx = av_buffer_ref(hw);
    cc->get_format = get_fmt;
    cc->flags |= AV_CODEC_FLAG_LOW_DELAY;
    cc->flags2 |= AV_CODEC_FLAG2_FAST;
    cc->thread_count = 1;
    cc->extra_hw_frames = 2;
    if (avcodec_open2(cc, dec, NULL) < 0) { plog("avcodec_open2 failed"); return 1; }

    WSADATA wsa; WSAStartup(MAKEWORD(2, 2), &wsa);
    g_udp = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    int rcvbuf = 32 * 1024 * 1024; setsockopt(g_udp, SOL_SOCKET, SO_RCVBUF, (char *)&rcvbuf, sizeof rcvbuf);
    DWORD tmo = 10; setsockopt(g_udp, SOL_SOCKET, SO_RCVTIMEO, (char *)&tmo, sizeof tmo);
    struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_port = htons((u_short)port); a.sin_addr.s_addr = INADDR_ANY;
    if (bind(g_udp, (struct sockaddr *)&a, sizeof a)) { plog("udp bind %d failed %d", port, WSAGetLastError()); return 1; }
    InitializeCriticalSection(&g_qlock);
    InitializeCriticalSection(&g_colorLock);
    g_qevent = CreateEventW(NULL, FALSE, FALSE, NULL);
    CreateThread(NULL, 0, recv_thread, NULL, 0, NULL);
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
    mmcss_join();
    plog("viewer up on %ls port %d codec %s vsync %d", device, port, codec, g_vsync);

    AVPacket *pkt = av_packet_alloc();
    AVFrame *fr = av_frame_alloc();
    double lastStats = now_us(), lastDiag = now_us(), decAcc = 0, presAcc = 0; int decN = 0; LONG lastOk = 0;
    uint32_t lastTs = 0; double lastHold = 0, lastDeskCheck = 0, lastPresentedAt = 0; int noOutput = 0;
    for (;;) {
        HANDLE hs[2] = {g_qevent, stopEv};
        DWORD nh = stopEv ? 2 : 1;
        DWORD r = MsgWaitForMultipleObjects(nh, hs, FALSE, 100, QS_ALLINPUT);
        if (stopEv && r == WAIT_OBJECT_0 + 1) { plog("stop requested"); restore_refresh(device); return 0; }
        if (r == WAIT_OBJECT_0 + nh) {
            MSG msg;
            while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
                if (msg.message == WM_QUIT) { restore_refresh(device); return 0; }
                DispatchMessageW(&msg);
            }
        }
        double tnow = now_us();
        if (tnow - lastDeskCheck > 200000) {
            lastDeskCheck = tnow;
            follow_input_desktop(&hwnd, mon);
        }
        if (InterlockedExchange(&g_colorDirty, 0)) {
            ColorParams c;
            EnterCriticalSection(&g_colorLock); c = g_color; LeaveCriticalSection(&g_colorLock);
            ID3D11DeviceContext_UpdateSubresource(g_ctx, (ID3D11Resource *)g_cbuf, 0, NULL, &c, 0, 0);
            plog("color: bright %.2f contrast %.2f sat %.2f gamma %.2f tint %.2f/%.2f/%.2f full %d",
                 c.brightness, c.contrast, c.saturation, c.gamma, c.r, c.g, c.b, (int)c.fullRange);
            draw_current();   // show it right away even if the screen is static
        }
        // decode everything that arrived, present only the newest picture
        int got = 0; double arrived = 0; uint32_t ts = 0;
        for (;;) {
            QFrame q;
            EnterCriticalSection(&g_qlock);
            int has = g_qhead != g_qtail;
            if (has) { q = g_queue[g_qhead]; g_qhead = (g_qhead + 1) % 32; }
            LeaveCriticalSection(&g_qlock);
            if (!has) break;
            if (g_needKey && !q.key) { free(q.buf); continue; }  // undecodable until the keyframe
            double t0 = now_us();
            av_packet_unref(pkt);
            pkt->data = q.buf; pkt->size = q.len;
            if (q.key) pkt->flags |= AV_PKT_FLAG_KEY;
            int ret = avcodec_send_packet(cc, pkt);
            free(q.buf); pkt->data = NULL; pkt->size = 0;
            got = ret >= 0 && avcodec_receive_frame(cc, fr) == 0;  // no reordering: one packet in, one picture out
            // Self-heal: the decoder can swallow packets without producing pictures (broken reference
            // chain). Never sit frozen - flush and ask for a keyframe after 3 silent packets.
            if (got) noOutput = 0;
            else if (ret < 0 || ++noOutput >= 3) {
                plog("decoder stalled (ret=%d, %d packets without output): flushing, requesting keyframe", ret, noOutput);
                avcodec_flush_buffers(cc);
                noOutput = 0;
                InterlockedExchange(&g_needKey, 1);
                InterlockedExchange(&g_decStall, 1);
                InterlockedIncrement(&d_lossEvents);
                d_waitKeySince = now_us();
                send_idr();
                continue;
            }
            { double d = now_us() - t0; decAcc += d; decN++; if (d > d_maxDecode) d_maxDecode = d; }
            arrived = q.arrivedUs; ts = q.ts;
            if (got) {
                double p0 = now_us();
                upload_frame(fr);
                // v-sync: a newer picture already queued replaces this one instead of waiting a refresh behind it
                int newer;
                EnterCriticalSection(&g_qlock); newer = g_qhead != g_qtail; LeaveCriticalSection(&g_qlock);
                if (!g_vsync || !newer) draw_current();
                presAcc += now_us() - p0;
                av_frame_unref(fr);
                lastTs = ts; lastHold = now_us() - arrived; lastPresentedAt = now_us();
                { double t = now_us(); if (d_lastPresent > 0 && t - d_lastPresent > d_maxPresentGap) d_maxPresentGap = t - d_lastPresent; d_lastPresent = t; }
            }
        }
        double t = now_us();
        if (t - lastDiag > 1000000) {
            LONG ok = g_ok;
            if (ok != lastOk || d_idrSent)
                plog("1s: frames=%ld pkts=%ld fecfix=%ld loss=%ld idrReq=%ld keys=%ld waitKey=%.0fms maxArrGap=%.1fms maxPresGap=%.1fms maxAssemble=%.1fms maxDecode=%.1fms",
                     ok - lastOk, InterlockedExchange(&d_pkts, 0), InterlockedExchange(&d_recovered, 0), InterlockedExchange(&d_lossEvents, 0),
                     InterlockedExchange(&d_idrSent, 0), InterlockedExchange(&d_keys, 0), d_waitKeyUs / 1000, d_maxArrivalGap / 1000,
                     d_maxPresentGap / 1000, d_maxAssembleUs / 1000, d_maxDecode / 1000);
            lastOk = ok; d_waitKeyUs = 0; d_maxArrivalGap = d_maxPresentGap = d_maxAssembleUs = d_maxDecode = 0; lastDiag = t;
        }
        if (t - lastStats > 500000 && g_havePeer) {
            double presentedAt = lastPresentedAt > 0 ? lastPresentedAt : t;
            Stats s = {0x11, {0}, lastTs, (uint32_t)lastHold, (uint32_t)g_ok, (uint32_t)g_lost,
                       decN ? (uint32_t)(decAcc / decN) : 0, decN ? (uint32_t)(presAcc / decN) : 0, (uint32_t)(t - presentedAt)};
            sendto(g_udp, (char *)&s, sizeof s, 0, (struct sockaddr *)&g_peer, sizeof g_peer);
            decAcc = presAcc = 0; decN = 0; lastStats = t;
        }
    }
}

// ---------------------------------------------------------------------------------------------

int main(int argc, char **argv) {
    LARGE_INTEGER f; QueryPerformanceFrequency(&f); g_qpf = (double)f.QuadPart;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    WSADATA wsa; WSAStartup(MAKEWORD(2, 2), &wsa);
    if (argc >= 2 && !strcmp(argv[1], "view")) return run_viewer(argc, argv);
    if (argc >= 2 && !strcmp(argv[1], "list")) return run_list();
    if (argc >= 3 && !strcmp(argv[1], "dash")) { CoInitializeEx(NULL, COINIT_MULTITHREADED); return run_dash(argv[2]); }
    if (argc >= 3 && !strcmp(argv[1], "shot")) return run_shot(argv[2]);
    if (argc >= 4 && !strcmp(argv[1], "pincode")) return run_pincode(argv[2], argv[3]);
    if (argc >= 2 && !strcmp(argv[1], "poke")) {
        wchar_t name[64]; HDESK d = input_desktop(name, 64); if (d) SetThreadDesktop(d);
        INPUT in[2] = {0};
        in[0].type = in[1].type = INPUT_KEYBOARD;
        in[0].ki.wVk = in[1].ki.wVk = VK_SHIFT; in[1].ki.dwFlags = KEYEVENTF_KEYUP;
        SendInput(2, in, sizeof(INPUT));
        return 0;
    }
    if (argc >= 3 && !strcmp(argv[1], "shot-console")) {   // from an admin shell: take the shot in the console session
        log_open("shot");
        wchar_t cmd[600]; swprintf(cmd, 600, L"\"panelink.exe\" shot %hs", argv[2]);
        PROCESS_INFORMATION pi;
        if (!spawn_console(cmd, &pi, NULL)) return 1;
        WaitForSingleObject(pi.hProcess, 10000);
        return 0;
    }
    return run_service();
}
