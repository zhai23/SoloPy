/* SoloPy native cache loader and CPython host; see README for its contract. */
#define WIN32_LEAN_AND_MEAN
#define PY_SSIZE_T_CLEAN
/* Only declarations/types are needed; all Python functions are loaded dynamically. */
#define Py_NO_ENABLE_SHARED
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <wchar.h>
#include <Python.h>
#ifndef SOLOPY_HOST_ONLY
#define MINIZ_NO_STDIO
#define MINIZ_NO_TIME
#include "vendor/miniz.h"
#endif
#define MAGIC "SOLOPY02"
#define MANIFEST L"\\.solopy-manifest"
#define PATH_CAP 32768
#ifdef SOLOPY_WINDOWED
#define INTERPRETER L"pythonw.exe"
#else
#define INTERPRETER L"python.exe"
#endif

static void die(const wchar_t *message)
{
    DWORD error = GetLastError();
    wchar_t text[2048];
    _snwprintf(text, 2047, L"[SoloPy] %ls (Windows error %lu)\r\n", message, error);
    text[2047] = 0;
#ifdef SOLOPY_WINDOWED
    MessageBoxW(NULL, text, L"SoloPy", MB_OK | MB_ICONERROR);
#else
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    DWORD mode, written;
    if (GetConsoleMode(h, &mode)) {
        WriteConsoleW(h, text, (DWORD)wcslen(text), &written, NULL);
    } else {
        char bytes[8192];
        int n = WideCharToMultiByte(CP_UTF8, 0, text, -1, bytes, sizeof(bytes), NULL, NULL);
        if (n > 1) WriteFile(h, bytes, (DWORD)n - 1, &written, NULL);
    }
#endif
    ExitProcess(2);
}

static void *alloc(size_t n)
{
    void *p = calloc(1, n ? n : 1);
    if (!p) die(L"out of memory");
    return p;
}
static wchar_t *join(const wchar_t *a, const wchar_t *b)
{
    size_t n = wcslen(a) + wcslen(b) + 1;
    if (n >= PATH_CAP) die(L"path too long");
    wchar_t *p = alloc(n * sizeof(wchar_t));
    wcscpy(p, a); wcscat(p, b); return p;
}
static wchar_t *wide(const char *s)
{
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
    if (!n) die(L"invalid UTF-8 runtime path");
    wchar_t *p = alloc((size_t)n * sizeof(wchar_t));
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, p, n))
        die(L"cannot decode runtime path");
    for (wchar_t *q = p; *q; ++q) if (*q == L'/') *q = L'\\';
    return p;
}
static wchar_t *long_path(const wchar_t *path)
{
    if (!wcsncmp(path, L"\\\\?\\", 4)) return join(path, L"");
    if (!wcsncmp(path, L"\\\\", 2)) return join(L"\\\\?\\UNC\\", path + 2);
    return join(L"\\\\?\\", path);
}

/* Keep CPython's native CLI parser. Explicit module paths avoid both registry
 * discovery and ._pth isolation. The cached hosts also use this same code. */
static int run_python(const wchar_t *root, int argc, wchar_t **argv)
{
    wchar_t dllname[64], zipname[64];
    _snwprintf(dllname, 64, L"\\python%d%d.dll", PY_MAJOR_VERSION, PY_MINOR_VERSION);
    _snwprintf(zipname, 64, L"\\python%d%d.zip", PY_MAJOR_VERSION, PY_MINOR_VERSION);
    wchar_t *dllpath = join(root, dllname);
    HMODULE dll = LoadLibraryExW(dllpath, NULL,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!dll) die(L"cannot load bundled Python DLL; try --solopy-repair");
    free(dllpath);
#define API(ret, name, params) typedef ret (*name##_fn) params; \
    name##_fn p##name = (name##_fn)GetProcAddress(dll, #name); \
    if (!p##name) die(L"incompatible Python DLL")
    API(void, PyConfig_InitPythonConfig, (PyConfig *));
    API(PyStatus, PyConfig_SetString, (PyConfig *, wchar_t **, const wchar_t *));
    API(PyStatus, PyConfig_SetArgv, (PyConfig *, Py_ssize_t, wchar_t * const *));
    API(PyStatus, PyConfig_Read, (PyConfig *));
    API(PyStatus, PyWideStringList_Append, (PyWideStringList *, const wchar_t *));
    API(PyStatus, Py_InitializeFromConfig, (const PyConfig *));
    API(void, PyConfig_Clear, (PyConfig *));
    API(void, Py_ExitStatusException, (PyStatus));
    API(int, Py_RunMain, (void));
#define CHECK(expr) do { PyStatus status = (expr); \
    if (status._type != _PyStatus_TYPE_OK) pPy_ExitStatusException(status); } while (0)
    PyConfig config;
    pPyConfig_InitPythonConfig(&config);
    config.user_site_directory = 0; /* private packages; explicit PYTHONPATH is supported */
    wchar_t *sep = join(root, L"\\"), *exe = join(sep, INTERPRETER);
    free(sep);
    CHECK(pPyConfig_SetString(&config, &config.home, root));
    CHECK(pPyConfig_SetString(&config, &config.executable, exe));
    CHECK(pPyConfig_SetString(&config, &config.base_executable, exe));
    CHECK(pPyConfig_SetString(&config, &config.prefix, root));
    CHECK(pPyConfig_SetString(&config, &config.exec_prefix, root));
    CHECK(pPyConfig_SetString(&config, &config.base_prefix, root));
    CHECK(pPyConfig_SetString(&config, &config.base_exec_prefix, root));
    CHECK(pPyConfig_SetArgv(&config, argc, argv));
    CHECK(pPyConfig_Read(&config));
    config.module_search_paths_set = 1;
    if (config.use_environment && config.pythonpath_env) {
        wchar_t *paths = join(config.pythonpath_env, L""), *part = paths;
        for (;;) {
            wchar_t *end = wcschr(part, L';');
            if (end) *end = 0;
            wchar_t full[PATH_CAP];
            DWORD n = GetFullPathNameW(*part ? part : L".", PATH_CAP, full, NULL);
            if (!n || n >= PATH_CAP) die(L"invalid PYTHONPATH");
            CHECK(pPyWideStringList_Append(&config.module_search_paths, full));
            if (!end) break;
            part = end + 1;
        }
        free(paths);
    }
    wchar_t *zip = join(root, zipname), *lib = join(root, L"\\Lib");
    CHECK(pPyWideStringList_Append(&config.module_search_paths, zip));
    CHECK(pPyWideStringList_Append(&config.module_search_paths, root));
    CHECK(pPyWideStringList_Append(&config.module_search_paths, lib));
    CHECK(pPy_InitializeFromConfig(&config));
    pPyConfig_Clear(&config);
    free(zip); free(lib); free(exe);
    return pPy_RunMain();
#undef CHECK
#undef API
}

#ifndef SOLOPY_HOST_ONLY
static BOOL regular_file(const wchar_t *path, uint64_t size)
{
    WIN32_FILE_ATTRIBUTE_DATA data;
    return GetFileAttributesExW(path, GetFileExInfoStandard, &data) &&
        !(data.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) &&
        (((uint64_t)data.nFileSizeHigh << 32) | data.nFileSizeLow) == size;
}
static BOOL read_bytes(HANDLE f, void *out, size_t size)
{
    char *p = out;
    while (size) {
        DWORD n = size > 1024 * 1024 ? 1024 * 1024 : (DWORD)size, got;
        if (!ReadFile(f, p, n, &got, NULL) || !got) return FALSE;
        size -= got; p += got;
    }
    return TRUE;
}
/* Reject traversal, absolute names, ADS and Win32 normalization aliases. */
static BOOL safe_relative(const wchar_t *path)
{
    if (!*path || *path == L'/' || *path == L'\\') return FALSE;
    const wchar_t *part = path;
    for (const wchar_t *p = path;; ++p) {
        if (*p == L':' || (*p && *p < 32)) return FALSE;
        if (!*p || *p == L'/' || *p == L'\\') {
            size_t n = p - part;
            if (!n || part[n-1] == L'.' || part[n-1] == L' ') return FALSE;
            if (!*p || !p[1]) return TRUE;
            part = p + 1;
        }
    }
}
static BOOL cache_valid(const wchar_t *root)
{
    DWORD attrs = GetFileAttributesW(root);
    if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY) ||
        (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) return FALSE;
    wchar_t *name = join(root, MANIFEST);
    HANDLE f = CreateFileW(name, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    free(name);
    if (f == INVALID_HANDLE_VALUE) return FALSE;
    char magic[8]; uint32_t count;
    BOOL ok = read_bytes(f, magic, 8) && !memcmp(magic, "SPMF0001", 8) &&
        read_bytes(f, &count, 4) && count > 0 && count < 1000000;
    for (uint32_t i = 0; ok && i < count; ++i) {
        uint64_t size; uint32_t len;
        ok = read_bytes(f, &size, 8) && read_bytes(f, &len, 4) && len > 0 && len < PATH_CAP * 4;
        if (!ok) break;
        char *bytes = alloc((size_t)len + 1);
        ok = read_bytes(f, bytes, len) && !memchr(bytes, 0, len);
        int n = ok ? MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes, -1, NULL, 0) : 0;
        if (!n || (size_t)n + wcslen(root) + 1 >= PATH_CAP) {
            free(bytes); ok = FALSE; break;
        }
        wchar_t *rel = wide(bytes); free(bytes);
        ok = safe_relative(rel);
        wchar_t *sep = join(root, L"\\"), *full = join(sep, rel);
        free(sep); free(rel);
        if (ok) ok = regular_file(full, size);
        free(full);
    }
    CloseHandle(f); return ok;
}
static void ensure_dirs(wchar_t *path)
{
    for (wchar_t *p = path + 4; *p; ++p) {
        if (*p == L'\\' || *p == L'/') {
            wchar_t ch = *p; *p = 0;
            CreateDirectoryW(path, NULL); *p = ch;
        }
    }
    if (!CreateDirectoryW(path, NULL)) {
        DWORD a = GetFileAttributesW(path);
        if (a == INVALID_FILE_ATTRIBUTES || !(a & FILE_ATTRIBUTE_DIRECTORY) ||
            (a & FILE_ATTRIBUTE_REPARSE_POINT)) die(L"cannot create runtime directory");
    }
}
static void extract_zip(const void *zip, size_t size, const wchar_t *root)
{
    mz_zip_archive archive; memset(&archive, 0, sizeof(archive));
    if (!mz_zip_reader_init_mem(&archive, zip, size, 0)) die(L"invalid runtime ZIP");
    mz_uint count = mz_zip_reader_get_num_files(&archive);
    for (mz_uint i = 0; i < count; ++i) {
        mz_uint len = mz_zip_reader_get_filename(&archive, i, NULL, 0);
        if (!len || len > PATH_CAP * 4) die(L"invalid ZIP filename length");
        char *name = alloc(len);
        if (mz_zip_reader_get_filename(&archive, i, name, len) != len) die(L"invalid ZIP filename");
        wchar_t *rel = wide(name); free(name);
        if (!safe_relative(rel)) die(L"unsafe path in runtime ZIP");
        for (wchar_t *p = rel; *p; ++p) if (*p == L'/') *p = L'\\';
        wchar_t *sep = join(root, L"\\"), *full = join(sep, rel);
        free(sep); free(rel);
        size_t length = wcslen(full);
        if (full[length - 1] == L'\\') {
            full[length - 1] = 0; ensure_dirs(full); free(full); continue;
        }
        wchar_t *last = wcsrchr(full, L'\\');
        *last = 0; ensure_dirs(full); *last = L'\\';
        size_t out_size;
        void *data = mz_zip_reader_extract_to_heap(&archive, i, &out_size, 0);
        if (!data) die(L"runtime decompression failed");
        HANDLE f = CreateFileW(full, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
        if (f == INVALID_HANDLE_VALUE) die(L"cannot write runtime file");
        const char *p = data;
        for (size_t left = out_size; left;) {
            DWORD n = left > 1024 * 1024 ? 1024 * 1024 : (DWORD)left, written;
            if (!WriteFile(f, p, n, &written, NULL) || !written) die(L"runtime write failed");
            left -= written; p += written;
        }
        CloseHandle(f); mz_free(data); free(full);
    }
    mz_zip_reader_end(&archive);
}
/* Never follow junctions, including when the deletion root is a junction. */
static void remove_tree(const wchar_t *dir)
{
    DWORD a = GetFileAttributesW(dir);
    if (a == INVALID_FILE_ATTRIBUTES) return;
    if (a & FILE_ATTRIBUTE_REPARSE_POINT) { RemoveDirectoryW(dir); return; }
    wchar_t *pattern = join(dir, L"\\*"); WIN32_FIND_DATAW entry;
    HANDLE find = FindFirstFileW(pattern, &entry); free(pattern);
    if (find != INVALID_HANDLE_VALUE) {
        do {
            if (!wcscmp(entry.cFileName, L".") || !wcscmp(entry.cFileName, L"..")) continue;
            wchar_t *sep = join(dir, L"\\"), *child = join(sep, entry.cFileName); free(sep);
            if (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) remove_tree(child);
            else {
                if (!(entry.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
                    SetFileAttributesW(child, FILE_ATTRIBUTE_NORMAL);
                DeleteFileW(child);
            }
            free(child);
        } while (FindNextFileW(find, &entry));
        FindClose(find);
    }
    RemoveDirectoryW(dir);
}
static wchar_t *prepare_cache(const wchar_t *self, BOOL repair)
{
    HANDLE f = CreateFileW(self, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (f == INVALID_HANDLE_VALUE) die(L"cannot read launcher");
    LARGE_INTEGER size, offset;
    if (!GetFileSizeEx(f, &size) || size.QuadPart < 32) die(L"missing runtime trailer");
    offset.QuadPart = size.QuadPart - 32;
    unsigned char trailer[32]; uint64_t zip_size;
    if (!SetFilePointerEx(f, offset, NULL, FILE_BEGIN) || !read_bytes(f, trailer, 32) ||
        memcmp(trailer + 24, MAGIC, 8)) die(L"invalid runtime trailer");
    memcpy(&zip_size, trailer + 16, 8);
    if (!zip_size || zip_size > (uint64_t)(size.QuadPart - 32) || zip_size > SIZE_MAX)
        die(L"invalid runtime length");
    wchar_t id[33];
    for (int i = 0; i < 16; ++i) swprintf(id + i * 2, 3, L"%02x", trailer[i]);
    wchar_t base[PATH_CAP], absolute[PATH_CAP];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", base, PATH_CAP);
    if (!n || n >= PATH_CAP) n = GetEnvironmentVariableW(L"TEMP", base, PATH_CAP);
    if (!n || n >= PATH_CAP) die(L"LOCALAPPDATA/TEMP not available");
    n = GetFullPathNameW(base, PATH_CAP, absolute, NULL);
    if (!n || n >= PATH_CAP) die(L"invalid cache location");
    wchar_t *root = join(absolute, L"\\SoloPy"), *prefix = join(root, L"\\rt-"), *cache = join(prefix, id);
    wchar_t *long_root = long_path(root), *long_cache = long_path(cache);
    ensure_dirs(long_root);
    if (repair || !cache_valid(long_cache)) {
        wchar_t *lock_name = join(long_cache, L".lock");
        HANDLE lock = INVALID_HANDLE_VALUE; ULONGLONG deadline = GetTickCount64() + 120000;
        do {
            lock = CreateFileW(lock_name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_ALWAYS, 0, NULL);
            if (lock != INVALID_HANDLE_VALUE) break;
            if (GetLastError() != ERROR_SHARING_VIOLATION || GetTickCount64() > deadline)
                die(L"cannot lock runtime cache");
            Sleep(50);
        } while (1);
        free(lock_name);
        if (repair || !cache_valid(long_cache)) {
            wchar_t suffix[80];
            _snwprintf(suffix, 80, L".tmp.%lu.%llu", GetCurrentProcessId(), GetTickCount64());
            wchar_t *temp = join(long_cache, suffix), *old = join(temp, L".old");
            if (!CreateDirectoryW(temp, NULL)) die(L"cannot create fresh extraction directory");
            void *zip = alloc((size_t)zip_size);
            offset.QuadPart = size.QuadPart - 32 - (LONGLONG)zip_size;
            if (!SetFilePointerEx(f, offset, NULL, FILE_BEGIN) || !read_bytes(f, zip, (size_t)zip_size))
                die(L"cannot read runtime archive");
            extract_zip(zip, (size_t)zip_size, temp); free(zip);
            if (!cache_valid(temp)) die(L"extracted runtime does not match manifest");
            BOOL had_old = GetFileAttributesW(long_cache) != INVALID_FILE_ATTRIBUTES;
            if (had_old && !MoveFileExW(long_cache, old, 0))
                die(L"runtime cache is busy; close its Python processes and retry repair");
            if (!MoveFileExW(temp, long_cache, 0)) {
                DWORD error = GetLastError();
                if (had_old) MoveFileExW(old, long_cache, 0);
                SetLastError(error); die(L"cannot install runtime cache");
            }
            if (had_old) remove_tree(old);
            free(temp); free(old);
        }
        CloseHandle(lock);
    }
    CloseHandle(f); free(root); free(prefix); free(long_root); free(long_cache);
    return cache;
}
#endif

int wmain(int argc, wchar_t **argv)
{
    wchar_t self[PATH_CAP];
    DWORD n = GetModuleFileNameW(NULL, self, PATH_CAP);
    if (!n || n >= PATH_CAP) die(L"cannot resolve executable path");
#ifdef SOLOPY_HOST_ONLY
    wchar_t *last = wcsrchr(self, L'\\');
    if (!last) die(L"cannot resolve runtime path");
    *last = 0; return run_python(self, argc, argv);
#else
    BOOL repair = argc == 2 && !wcscmp(argv[1], L"--solopy-repair");
    wchar_t *cache = prepare_cache(self, repair);
    if (repair) { free(cache); return 0; }
#ifdef SOLOPY_WINDOWED
    /* GUI launch remains asynchronous. Console uses CPython in this process. */
    wchar_t *sep = join(cache, L"\\"), *exe = join(sep, INTERPRETER);
    wchar_t *tail = GetCommandLineW();
    if (*tail == L'"') { ++tail; while (*tail && *tail != L'"') ++tail; if (*tail) ++tail; }
    else { while (*tail && *tail != L' ' && *tail != L'\t') ++tail; }
    wchar_t *quoted = join(L"\"", exe), *end = join(quoted, L"\" "), *cmd = join(end, tail);
    STARTUPINFOW si; PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si)); ZeroMemory(&pi, sizeof(pi)); si.cb = sizeof(si);
    if (!CreateProcessW(exe, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi))
        die(L"cannot start GUI interpreter");
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    free(sep); free(exe); free(quoted); free(end); free(cmd); free(cache); return 0;
#else
    int code = run_python(cache, argc, argv); free(cache); return code;
#endif
#endif
}
