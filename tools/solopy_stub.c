/*
 * SoloPy native launcher stub.
 *
 * Layout of the final single-file executable:
 *   [ this stub .exe ] [ runtime.zip ] [ 32-byte trailer ]
 *
 * Trailer (fixed 32 bytes at end of file):
 *   offset  0 : 16 bytes  build id            (cache key, hex-encoded for dir name)
 *   offset 16 :  8 bytes  zip length (uint64 little-endian)
 *   offset 24 :  8 bytes  magic  "SOLOPY01"
 *
 * Behaviour:
 *   - Warm path (cache already populated): read only the 32-byte trailer,
 *     locate %LOCALAPPDATA%\SoloPy\rt-<id>\python.exe and exec it directly.
 *     No archive is read, no extraction happens. Startup ~= native python.exe.
 *   - Cold path (first run for this build id): read the appended zip once,
 *     extract it (Unicode-safe) into a temp dir, atomically rename into place,
 *     then exec python.exe.
 *
 * Two build variants share this single source (selected at compile time):
 *   - Console variant (default): behaves exactly like python.exe. Inherits the
 *     console/stdio, forwards Ctrl+C to the child, waits, and propagates the
 *     child's exit code. Produces solopy.exe.
 *   - Windowed variant (define SOLOPY_WINDOWED): behaves like pythonw.exe.
 *     Built as a GUI-subsystem exe so NO console window ever appears. It
 *     launches the bundled pythonw.exe fire-and-forget (does not wait) so the
 *     GUI runs independently, and reports fatal errors via a message box.
 *     Produces solopyw.exe.
 *
 * Transparency goals (behave like the bundled interpreter):
 *   - argv is forwarded verbatim via GetCommandLineW (original quoting kept).
 *   - Console variant inherits stdio (pipes, redirection, TTY all work).
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* miniz: only the zip reader is needed. */
#define MINIZ_NO_STDIO           /* we do all file I/O ourselves (Unicode-safe) */
#define MINIZ_NO_TIME
#include "vendor/miniz.h"

#define TRAILER_SIZE   32
#define MAGIC          "SOLOPY01"
#define MAGIC_LEN      8
#define BUILDID_LEN    16

/* Interpreter launched from the extracted runtime. The windowed variant uses
 * pythonw.exe (GUI subsystem, no console); the console variant uses python.exe.
 * Both live in the same extracted runtime, so the two exes can share one cache. */
#ifdef SOLOPY_WINDOWED
#  define INTERP_EXE L"pythonw.exe"
#else
#  define INTERP_EXE L"python.exe"
#endif

/* ---- tiny helpers -------------------------------------------------------- */

static void die(const wchar_t *msg)
{
#ifdef SOLOPY_WINDOWED
    /* No console in the windowed variant: surface errors via a message box. */
    MessageBoxW(NULL, msg, L"SoloPy", MB_OK | MB_ICONERROR);
#else
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    DWORD written = 0;
    if (h && h != INVALID_HANDLE_VALUE) {
        WriteConsoleW(h, msg, lstrlenW(msg), &written, NULL);
        WriteConsoleW(h, L"\r\n", 2, &written, NULL);
    }
#endif
    ExitProcess(2);
}

static void *xalloc(size_t n)
{
    void *p = HeapAlloc(GetProcessHeap(), 0, n);
    if (!p) die(L"[SoloPy] out of memory");
    return p;
}

static void xfree(void *p)
{
    if (p) HeapFree(GetProcessHeap(), 0, p);
}

/* Concatenate wide strings into a freshly allocated buffer. */
static wchar_t *wjoin(const wchar_t *a, const wchar_t *b)
{
    size_t la = a ? lstrlenW(a) : 0;
    size_t lb = b ? lstrlenW(b) : 0;
    wchar_t *r = (wchar_t *)xalloc((la + lb + 1) * sizeof(wchar_t));
    if (la) CopyMemory(r, a, la * sizeof(wchar_t));
    if (lb) CopyMemory(r + la, b, lb * sizeof(wchar_t));
    r[la + lb] = 0;
    return r;
}

static BOOL path_exists(const wchar_t *path)
{
    DWORD a = GetFileAttributesW(path);
    return a != INVALID_FILE_ATTRIBUTES;
}

/* mkdir -p for a wide path (accepts \\?\ prefixed paths). */
static void ensure_dirs(wchar_t *path)
{
    for (wchar_t *p = path; *p; ++p) {
        if (*p == L'\\' || *p == L'/') {
            wchar_t save = *p;
            *p = 0;
            /* Skip drive root ("C:") and the \\?\ prefix segments. */
            if (lstrlenW(path) > 3)
                CreateDirectoryW(path, NULL);
            *p = save;
        }
    }
    CreateDirectoryW(path, NULL);
}

static void ensure_parent_dirs(const wchar_t *fullpath)
{
    size_t n = lstrlenW(fullpath);
    wchar_t *tmp = (wchar_t *)xalloc((n + 1) * sizeof(wchar_t));
    CopyMemory(tmp, fullpath, (n + 1) * sizeof(wchar_t));
    for (size_t i = n; i > 0; --i) {
        if (tmp[i - 1] == L'\\' || tmp[i - 1] == L'/') {
            tmp[i - 1] = 0;
            ensure_dirs(tmp);
            break;
        }
    }
    xfree(tmp);
}

static wchar_t *utf8_to_wide(const char *s)
{
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) { wchar_t *e = (wchar_t *)xalloc(sizeof(wchar_t)); e[0] = 0; return e; }
    wchar_t *w = (wchar_t *)xalloc((size_t)n * sizeof(wchar_t));
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    for (wchar_t *p = w; *p; ++p) if (*p == L'/') *p = L'\\';
    return w;
}

/* Read the whole of our own executable's trailer + optionally the zip. */
static HANDLE open_self(const wchar_t *self, LARGE_INTEGER *size_out)
{
    HANDLE f = CreateFileW(self, GENERIC_READ, FILE_SHARE_READ, NULL,
                           OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (f == INVALID_HANDLE_VALUE) die(L"[SoloPy] cannot open self");
    if (!GetFileSizeEx(f, size_out)) die(L"[SoloPy] cannot stat self");
    return f;
}

static void read_at(HANDLE f, LONGLONG off, void *buf, DWORD len)
{
    LARGE_INTEGER li; li.QuadPart = off;
    if (!SetFilePointerEx(f, li, NULL, FILE_BEGIN)) die(L"[SoloPy] seek failed");
    DWORD got = 0, total = 0;
    while (total < len) {
        if (!ReadFile(f, (char *)buf + total, len - total, &got, NULL) || got == 0)
            die(L"[SoloPy] read failed");
        total += got;
    }
}

/* Build hex directory suffix from the 16-byte build id. */
static void buildid_hex(const unsigned char *id, wchar_t *out /* >=33 */)
{
    static const wchar_t *H = L"0123456789abcdef";
    for (int i = 0; i < BUILDID_LEN; ++i) {
        out[i * 2 + 0] = H[(id[i] >> 4) & 0xF];
        out[i * 2 + 1] = H[id[i] & 0xF];
    }
    out[BUILDID_LEN * 2] = 0;
}

/* Extract the in-memory zip to destRoot (a \\?\-prefixed directory). */
static void extract_zip(const void *zip, size_t zip_len, const wchar_t *destRoot)
{
    mz_zip_archive za;
    memset(&za, 0, sizeof(za));
    if (!mz_zip_reader_init_mem(&za, zip, zip_len, 0))
        die(L"[SoloPy] invalid embedded runtime archive");

    mz_uint count = mz_zip_reader_get_num_files(&za);
    for (mz_uint i = 0; i < count; ++i) {
        mz_zip_archive_file_stat st;
        if (!mz_zip_reader_file_stat(&za, i, &st)) continue;

        wchar_t *rel = utf8_to_wide(st.m_filename);
        wchar_t *sep = wjoin(destRoot, L"\\");
        wchar_t *full = wjoin(sep, rel);
        xfree(sep);
        xfree(rel);

        if (mz_zip_reader_is_file_a_directory(&za, i)) {
            ensure_dirs(full);
            xfree(full);
            continue;
        }

        ensure_parent_dirs(full);

        size_t out_sz = 0;
        void *data = mz_zip_reader_extract_to_heap(&za, i, &out_sz, 0);
        if (!data) { xfree(full); die(L"[SoloPy] failed to decompress a runtime file"); }

        HANDLE h = CreateFileW(full, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                               FILE_ATTRIBUTE_NORMAL, NULL);
        if (h == INVALID_HANDLE_VALUE) { mz_free(data); xfree(full); die(L"[SoloPy] cannot write runtime file"); }

        const char *p = (const char *)data;
        size_t left = out_sz;
        while (left) {
            DWORD chunk = left > 0x400000 ? 0x400000 : (DWORD)left;
            DWORD wrote = 0;
            if (!WriteFile(h, p, chunk, &wrote, NULL) || wrote == 0) {
                CloseHandle(h); mz_free(data); xfree(full); die(L"[SoloPy] write error");
            }
            p += wrote; left -= wrote;
        }
        CloseHandle(h);
        mz_free(data);
        xfree(full);
    }
    mz_zip_reader_end(&za);
}

/* Recursively delete a directory tree (best-effort). */
static void rmtree(const wchar_t *dir)
{
    wchar_t *pattern = wjoin(dir, L"\\*");
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pattern, &fd);
    xfree(pattern);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (!lstrcmpW(fd.cFileName, L".") || !lstrcmpW(fd.cFileName, L"..")) continue;
            wchar_t *sep = wjoin(dir, L"\\");
            wchar_t *child = wjoin(sep, fd.cFileName);
            xfree(sep);
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                rmtree(child);
            } else {
                SetFileAttributesW(child, FILE_ATTRIBUTE_NORMAL);
                DeleteFileW(child);
            }
            xfree(child);
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    RemoveDirectoryW(dir);
}

/* Skip argv[0] in a raw command line, return pointer to the args tail. */
static wchar_t *args_tail(wchar_t *cmdline)
{
    wchar_t *p = cmdline;
    if (*p == L'"') {
        ++p;
        while (*p && *p != L'"') ++p;
        if (*p == L'"') ++p;
    } else {
        while (*p && *p != L' ' && *p != L'\t') ++p;
    }
    while (*p == L' ' || *p == L'\t') ++p;
    return p;
}

#ifndef SOLOPY_WINDOWED
static BOOL WINAPI ctrl_handler(DWORD type)
{
    (void)type;
    /* Let the child process handle Ctrl+C / Ctrl+Break like real python.
       Returning TRUE stops the stub from being terminated so it can keep
       waiting and then propagate the child's exit code. */
    return TRUE;
}
#endif

int main(void)
{
    /* --- locate self --- */
    wchar_t self[MAX_PATH * 2];
    DWORD n = GetModuleFileNameW(NULL, self, MAX_PATH * 2);
    if (n == 0 || n >= MAX_PATH * 2) die(L"[SoloPy] cannot resolve own path");

    LARGE_INTEGER fsize;
    HANDLE f = open_self(self, &fsize);
    if (fsize.QuadPart < TRAILER_SIZE) die(L"[SoloPy] corrupt executable (no trailer)");

    unsigned char trailer[TRAILER_SIZE];
    read_at(f, fsize.QuadPart - TRAILER_SIZE, trailer, TRAILER_SIZE);
    if (memcmp(trailer + 24, MAGIC, MAGIC_LEN) != 0)
        die(L"[SoloPy] corrupt executable (bad magic)");

    unsigned char build_id[BUILDID_LEN];
    CopyMemory(build_id, trailer, BUILDID_LEN);
    unsigned long long zip_len =
        (unsigned long long)trailer[16]        | ((unsigned long long)trailer[17] << 8)  |
        ((unsigned long long)trailer[18] << 16) | ((unsigned long long)trailer[19] << 24) |
        ((unsigned long long)trailer[20] << 32) | ((unsigned long long)trailer[21] << 40) |
        ((unsigned long long)trailer[22] << 48) | ((unsigned long long)trailer[23] << 56);

    /* --- cache location --- */
    wchar_t idhex[BUILDID_LEN * 2 + 1];
    buildid_hex(build_id, idhex);

    wchar_t base[MAX_PATH * 2];
    DWORD bl = GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH * 2);
    if (bl == 0 || bl >= MAX_PATH * 2) {
        bl = GetEnvironmentVariableW(L"TEMP", base, MAX_PATH * 2);
        if (bl == 0 || bl >= MAX_PATH * 2) die(L"[SoloPy] no LOCALAPPDATA/TEMP");
    }

    wchar_t *rootA = wjoin(base, L"\\SoloPy");
    wchar_t *sepB = wjoin(rootA, L"\\rt-");
    wchar_t *cacheDir = wjoin(sepB, idhex);      /* final runtime dir */
    xfree(sepB);

    wchar_t *pySep = wjoin(cacheDir, L"\\");
    wchar_t *pythonExe = wjoin(pySep, INTERP_EXE);
    xfree(pySep);

    /* --- cold path: extract once --- */
    if (!path_exists(pythonExe)) {
        /* read the appended zip */
        void *zip = xalloc((size_t)zip_len);
        LONGLONG zip_off = fsize.QuadPart - TRAILER_SIZE - (LONGLONG)zip_len;
        if (zip_off < 0) die(L"[SoloPy] corrupt executable (bad zip length)");
        read_at(f, zip_off, zip, (DWORD)zip_len);   /* zip < 4GB */

        CreateDirectoryW(rootA, NULL);

        /* extract to a unique temp dir, then atomically move into place */
        wchar_t pidbuf[32];
        wsprintfW(pidbuf, L".tmp.%lu", GetCurrentProcessId());
        wchar_t *tmpDir = wjoin(cacheDir, pidbuf);

        wchar_t *tmpPrefixed = wjoin(L"\\\\?\\", tmpDir);
        ensure_dirs(tmpPrefixed);
        extract_zip(zip, (size_t)zip_len, tmpPrefixed);
        xfree(tmpPrefixed);
        xfree(zip);

        if (!MoveFileExW(tmpDir, cacheDir, 0)) {
            /* Another instance won the race, or a stale dir exists. */
            if (path_exists(pythonExe)) {
                rmtree(tmpDir);              /* discard our copy, reuse existing */
            } else {
                rmtree(cacheDir);
                if (!MoveFileExW(tmpDir, cacheDir, 0)) {
                    rmtree(tmpDir);
                    die(L"[SoloPy] failed to install runtime cache");
                }
            }
        }
        xfree(tmpDir);
    }

    CloseHandle(f);
    xfree(rootA);
    xfree(cacheDir);

    if (!path_exists(pythonExe))
        die(L"[SoloPy] runtime interpreter missing after extraction");

    /* --- build child command line: "<python.exe>" <original args...> --- */
    wchar_t *tail = args_tail(GetCommandLineW());
    wchar_t *q1 = wjoin(L"\"", pythonExe);
    wchar_t *quotedPy = wjoin(q1, L"\"");
    xfree(q1);
    wchar_t *withSpace = wjoin(quotedPy, L" ");
    wchar_t *cmdline = wjoin(withSpace, tail);
    xfree(quotedPy);
    xfree(withSpace);

    /* --- launch --- */
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    memset(&pi, 0, sizeof(pi));

#ifdef SOLOPY_WINDOWED
    /* Windowed: no console at all. pythonw.exe is a GUI-subsystem program, so it
     * never allocates a console; CREATE_NO_WINDOW is added as belt-and-suspenders.
     * Fire-and-forget: do not wait so the GUI runs independently and this
     * launcher exits immediately. */
    BOOL ok = CreateProcessW(pythonExe, cmdline, NULL, NULL, FALSE,
                             CREATE_NO_WINDOW, NULL, NULL, &si, &pi);
    if (!ok) die(L"[SoloPy] failed to start interpreter");

    xfree(pythonExe);
    xfree(cmdline);

    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 0;
#else
    /* Console: inherit console/stdio, forward Ctrl+C to the child, wait, and
     * propagate the child's exact exit code. */
    SetConsoleCtrlHandler(ctrl_handler, TRUE);

    BOOL ok = CreateProcessW(pythonExe, cmdline, NULL, NULL, TRUE,
                             0, NULL, NULL, &si, &pi);
    if (!ok) die(L"[SoloPy] failed to start interpreter");

    xfree(pythonExe);
    xfree(cmdline);

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
#endif
}
