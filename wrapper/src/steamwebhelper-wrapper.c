/*
 * SPDX-License-Identifier: MIT
 *
 * steamwebhelper-wrapper — prepend --in-process-gpu and delegate to the
 * real Steam webhelper binary. Used on macOS / Apple Silicon to work
 * around DXMT's lack of cross-process swap-chain support (see
 * https://github.com/3Shain/dxmt/issues/141).
 *
 * Build
 * -----
 *   make -C wrapper
 * which invokes x86_64-w64-mingw32-gcc (from Homebrew mingw-w64) with:
 *   -municode -O2 -Wall -Wextra -static -lshell32 -mwindows
 *
 * Install
 * -------
 *   1. Rename Steam's original file:
 *        steamwebhelper.exe -> steamwebhelper_real.exe
 *   2. Drop the compiled wrapper in its place as steamwebhelper.exe
 *
 * Runtime behaviour
 * -----------------
 *   - Resolves its own directory via GetModuleFileNameW
 *   - Builds the child command line in the form:
 *         "<dir>\\steamwebhelper_real.exe" --in-process-gpu <original args>
 *   - Calls CreateProcessW, waits, and returns the child's exit code.
 *
 * Notes
 * -----
 *   - All string handling is wide-character; Chromium's internal args
 *     include Unicode paths like
 *     C:\users\notpop\AppData\Local\Steam\htmlcache.
 *   - Uses -mwindows so Windows treats the wrapper as a GUI app (same
 *     subsystem Steam's original helper declares). Debug prints go to
 *     stderr via _wfreopen if STEAMWEBHELPER_WRAPPER_DEBUG is set in
 *     the environment.
 */

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/*
 * Flags prepended to every invocation of steamwebhelper_real.exe.
 *
 * --in-process-gpu
 *     Run the Chromium GPU code inside the browser process. Required
 *     because DXMT (v0.74) does not yet support cross-process D3D11
 *     swap chains (https://github.com/3Shain/dxmt/issues/141).
 *
 * --single-process
 *     Collapse renderer and utility (network / storage / data_decoder)
 *     into the browser process as well. Without this flag the
 *     renderer still opens a D3D11 SwapChain from its own process and
 *     hits the same DXMT limitation; the utility process similarly
 *     opens Chromium's out-of-process NetworkService, which triggers
 *     the `handshake failed; net_error -100` SSL cascade on Wine's
 *     winsock implementation. This flag is heavier-handed but matches
 *     the workaround that DXMT users report actually working.
 */
/*
 * Step 1 of our plan (--in-process-gpu + --single-process + DXMT) merged
 * every subprocess back into the browser but the browser window still
 * refused to paint: the DXMT-accelerated composite surface hits
 * "Cannot use V8 Proxy resolver in single process mode" and related
 * CEF-in-single-process limits before drawing any HTML.
 *
 * Step 2 fallback: give Chromium CPU rasterisation by passing
 * --disable-gpu. This side-steps DXMT entirely (d3d11 is never
 * opened), lets CEF fall back to the well-trodden Skia software
 * path, and keeps --single-process so the renderer-side crash
 * still doesn't happen.
 *
 * For a 2D idle game like 幻獣大農場 software rendering is sufficient.
 */
#define EXTRA_FLAGS  L"--disable-gpu --single-process"
#define REAL_BINARY  L"steamwebhelper_real.exe"

/*
 * Debug sink. Enabled when the environment variable
 * STEAMWEBHELPER_WRAPPER_DEBUG is set to a non-empty value.
 * Opens a file next to the wrapper so we can inspect behaviour
 * even though the wrapper is a GUI subsystem binary.
 */
static FILE *dbg = NULL;

static void debug_open(const wchar_t *self_path)
{
    const wchar_t *flag = _wgetenv(L"STEAMWEBHELPER_WRAPPER_DEBUG");
    if (!flag || !*flag) return;

    wchar_t log_path[MAX_PATH];
    if (wcslen(self_path) + 16 >= MAX_PATH) return;
    wcscpy(log_path, self_path);

    wchar_t *slash = wcsrchr(log_path, L'\\');
    if (!slash) return;
    wcscpy(slash + 1, L"wrapper-debug.log");

    dbg = _wfopen(log_path, L"a");
}

static void debug_log(const wchar_t *fmt, ...)
{
    if (!dbg) return;
    va_list ap;
    va_start(ap, fmt);
    vfwprintf(dbg, fmt, ap);
    va_end(ap);
    fflush(dbg);
}

/* Allocate a wide string holding "<wrapper_dir>\\steamwebhelper_real.exe". */
static wchar_t *resolve_real_binary(wchar_t *out_self_dir, size_t out_cap)
{
    wchar_t self[MAX_PATH];
    DWORD len = GetModuleFileNameW(NULL, self, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) return NULL;

    if (out_self_dir && wcslen(self) < out_cap) {
        wcscpy(out_self_dir, self);
    }

    wchar_t *slash = wcsrchr(self, L'\\');
    if (!slash) return NULL;
    *(slash + 1) = L'\0';

    size_t cap = wcslen(self) + wcslen(REAL_BINARY) + 1;
    wchar_t *real = (wchar_t *)calloc(cap, sizeof(wchar_t));
    if (!real) return NULL;
    wcscpy(real, self);
    wcscat(real, REAL_BINARY);
    return real;
}

/*
 * GetCommandLineW returns the whole line, starting with the wrapper
 * binary's own path. We skip past that first token to return just the
 * arguments Steam actually passed.
 */
static const wchar_t *args_tail(void)
{
    const wchar_t *cmd = GetCommandLineW();
    if (!cmd) return L"";

    int in_quotes = 0;
    while (*cmd) {
        wchar_t c = *cmd;
        if (c == L'"') in_quotes = !in_quotes;
        else if (c == L' ' && !in_quotes) break;
        ++cmd;
    }
    while (*cmd == L' ') ++cmd;
    return cmd;
}

int wmain(void)
{
    wchar_t self_path[MAX_PATH] = {0};
    wchar_t *real = resolve_real_binary(self_path, MAX_PATH);
    if (!real) {
        return 1;
    }

    debug_open(self_path);
    debug_log(L"[wrapper] self=%ls\n", self_path);
    debug_log(L"[wrapper] real=%ls\n", real);

    const wchar_t *tail = args_tail();
    debug_log(L"[wrapper] forwarded args=%ls\n", tail);

    size_t cap = wcslen(real) + wcslen(EXTRA_FLAGS) + wcslen(tail) + 8;
    wchar_t *cmdline = (wchar_t *)calloc(cap, sizeof(wchar_t));
    if (!cmdline) {
        free(real);
        return 1;
    }
    _snwprintf(cmdline, cap, L"\"%ls\" %ls %ls", real, EXTRA_FLAGS, tail);
    debug_log(L"[wrapper] invoking: %ls\n", cmdline);

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    BOOL ok = CreateProcessW(
        real,       /* lpApplicationName */
        cmdline,    /* lpCommandLine     */
        NULL,       /* lpProcessAttributes */
        NULL,       /* lpThreadAttributes  */
        TRUE,       /* bInheritHandles     */
        0,          /* dwCreationFlags     */
        NULL,       /* lpEnvironment       */
        NULL,       /* lpCurrentDirectory  */
        &si,
        &pi
    );

    if (!ok) {
        DWORD err = GetLastError();
        debug_log(L"[wrapper] CreateProcessW failed: %lu\n", err);
        free(cmdline);
        free(real);
        return 1;
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    debug_log(L"[wrapper] child exited with %lu\n", code);

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    free(cmdline);
    free(real);
    if (dbg) fclose(dbg);

    return (int)code;
}
