/* Bounded diagnostics for the local Astra development driver.
 * Called outside DllMain; error and Present metadata budgets are independent. */
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <ctype.h>
#include "../astra_gpu_trace.h"

static volatile LONG trace_count;

void astra_gpu_trace(const char *kind, const char *text)
{
    DWORD saved_error=GetLastError();
    if(InterlockedIncrement(&trace_count)>128) {SetLastError(saved_error);return;}
    char temp[MAX_PATH],path[MAX_PATH],image[MAX_PATH],record[2048];
    DWORD n=GetTempPathA(sizeof(temp),temp);
    if(!n || n>=sizeof(temp)) {SetLastError(saved_error);return;}
    _snprintf_s(path,sizeof(path),_TRUNCATE,"%sAstraGpu-errors-%lu.log",temp,GetCurrentProcessId());
    n=GetModuleFileNameA(NULL,image,sizeof(image));
    if(!n || n>=sizeof(image)) strcpy_s(image,sizeof(image),"unknown");
    const char *client=strrchr(image,'\\');client=client?client+1:image;
    SYSTEMTIME now;GetSystemTime(&now);
    _snprintf_s(record,sizeof(record),_TRUNCATE,
        "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ build=resource-convert-v1 pid=%lu tid=%lu client=%s event=%s %s\n",
        now.wYear,now.wMonth,now.wDay,now.wHour,now.wMinute,now.wSecond,now.wMilliseconds,
        GetCurrentProcessId(),GetCurrentThreadId(),client,kind,text?text:"");
    HANDLE file=CreateFileA(path,FILE_APPEND_DATA,FILE_SHARE_READ|FILE_SHARE_WRITE,
                            NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    if(file!=INVALID_HANDLE_VALUE) {
        DWORD written;WriteFile(file,record,(DWORD)strlen(record),&written,NULL);CloseHandle(file);
    }
    SetLastError(saved_error);
}

void astra_gpu_tracef(const char *kind,const char *format,...)
{
    DWORD saved_error=GetLastError();
    char text[1400];va_list ap;va_start(ap,format);
    _vsnprintf_s(text,sizeof(text),_TRUNCATE,format,ap);va_end(ap);
    astra_gpu_trace(kind,text);SetLastError(saved_error);
}

void astra_gpu_trace_filtered(const char *kind,const char *text)
{
    char lowered[1400];size_t i=0;
    for(;text[i] && i+1<sizeof(lowered);i++)lowered[i]=(char)tolower((unsigned char)text[i]);
    lowered[i]=0;
    if(strstr(lowered,"fail") || strstr(lowered,"fatal") || strstr(lowered,"error") ||
       strstr(lowered,"lost") || strstr(lowered,"watchdog") ||
       strstr(lowered,"triton: createdevice: interface=") ||
       strstr(lowered,"triton: stub getresourcelayout ")) astra_gpu_trace(kind,text);
}

void astra_npt_log(const char *format,...)
{
    DWORD saved_error=GetLastError();
    char text[1400];va_list ap;va_start(ap,format);
    _vsnprintf_s(text,sizeof(text),_TRUNCATE,format,ap);va_end(ap);
    fputs(text,stderr);astra_gpu_trace_filtered("neptune",text);SetLastError(saved_error);
}

#define ASTRA_PRESENT_DISTINCT_LIMIT 64u
#define ASTRA_PRESENT_RECORD_LIMIT 256u
#define ASTRA_PRESENT_BYTE_LIMIT (512ull * 1024ull)

struct astra_present_tuple {
    uint32_t src_ctx, dst_ctx;
    uint64_t src_object, dst_object;
    uint32_t method, submitted, drop_mask;
};

static SRWLOCK present_seen_lock = SRWLOCK_INIT;
static struct astra_present_tuple present_seen[ASTRA_PRESENT_DISTINCT_LIMIT];
static uint32_t present_seen_count;
static uint64_t present_sequence;
/* Separate from the short identity lock and all driver presentation locks. */
static SRWLOCK present_writer_lock = SRWLOCK_INIT;
static uint32_t present_records;
static uint64_t present_bytes;

static int astra_present_same_tuple(const struct astra_present_tuple *a,
                                    const struct astra_present_tuple *b)
{
    return a->src_ctx == b->src_ctx && a->dst_ctx == b->dst_ctx &&
           a->src_object == b->src_object && a->dst_object == b->dst_object &&
           a->method == b->method && a->submitted == b->submitted &&
           a->drop_mask == b->drop_mask;
}

void astra_gpu_trace_present(const struct astra_present_metadata *metadata)
{
    DWORD saved_error = GetLastError();
    struct astra_present_tuple tuple;
    uint64_t sequence;
    char temp[MAX_PATH], path[MAX_PATH], image[MAX_PATH], client[37];
    char record[1024], callback_hr[24];
    DWORD n, written = 0;
    int record_size;
    SYSTEMTIME now;
    HANDLE file = INVALID_HANDLE_VALUE;
    LARGE_INTEGER file_size;
    if (!metadata) goto done;

    tuple.src_ctx = metadata->src_ctx;
    tuple.dst_ctx = metadata->dst_ctx;
    tuple.src_object = metadata->src_object;
    tuple.dst_object = metadata->dst_object;
    tuple.method = metadata->method;
    tuple.submitted = metadata->submitted;
    tuple.drop_mask = metadata->drop_mask;
    AcquireSRWLockExclusive(&present_seen_lock);
    sequence = ++present_sequence;
    if (present_seen_count >= ASTRA_PRESENT_DISTINCT_LIMIT) {
        ReleaseSRWLockExclusive(&present_seen_lock);
        goto done;
    }
    for (uint32_t i = 0; i < present_seen_count; ++i) {
        if (astra_present_same_tuple(&present_seen[i], &tuple)) {
            ReleaseSRWLockExclusive(&present_seen_lock);
            goto done;
        }
    }
    present_seen[present_seen_count++] = tuple;
    ReleaseSRWLockExclusive(&present_seen_lock);

    n = GetTempPathA(sizeof(temp), temp);
    if (!n || n >= sizeof(temp)) goto done;
    if (_snprintf_s(path, sizeof(path), _TRUNCATE, "%sAstraGpu-present-%lu.log",
                    temp, GetCurrentProcessId()) < 0) goto done;
    n = GetModuleFileNameA(NULL, image, sizeof(image));
    astra_gpu_sanitized_basename(client, sizeof(client),
                                 n && n < sizeof(image) ? image : "unknown");
    if (metadata->submitted)
        _snprintf_s(callback_hr, sizeof(callback_hr), _TRUNCATE, "0x%08x",
                     (unsigned)metadata->result_hr);
    else
        strcpy_s(callback_hr, sizeof(callback_hr), "not_called");
    GetSystemTime(&now);
    record_size = _snprintf_s(record, sizeof(record), _TRUNCATE,
        "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ build=resource-convert-v1 "
        "event=present_join pid=%lu tid=%lu client=%s seq=%llu method=%s "
        "src_ctx=%u src_object=0x%016llx dst_ctx=%u dst_object=0x%016llx "
        "primary=%u shared=%u width=%u height=%u format=%u "
        "src_allocation=0x%08x dst_allocation=0x%08x "
        "submitted=%u outcome=%s drop_mask=0x%x callback_hr=%s return_hr=0x%08x\n",
        (unsigned)now.wYear, (unsigned)now.wMonth, (unsigned)now.wDay,
        (unsigned)now.wHour, (unsigned)now.wMinute, (unsigned)now.wSecond,
        (unsigned)now.wMilliseconds, GetCurrentProcessId(), GetCurrentThreadId(),
        client, (unsigned long long)sequence,
        metadata->method == ASTRA_PRESENT_METHOD_PRESENT1 ? "Present1" : "Present",
        (unsigned)metadata->src_ctx, (unsigned long long)metadata->src_object,
        (unsigned)metadata->dst_ctx, (unsigned long long)metadata->dst_object,
        (unsigned)metadata->primary, (unsigned)metadata->shared,
        (unsigned)metadata->width, (unsigned)metadata->height, (unsigned)metadata->format,
        (unsigned)metadata->src_allocation, (unsigned)metadata->dst_allocation,
        (unsigned)metadata->submitted,
        metadata->submitted ? "submitted_callback" : "dropped_missing_prerequisite",
        (unsigned)metadata->drop_mask, callback_hr, (unsigned)metadata->result_hr);
    if (record_size <= 0) goto done;

    AcquireSRWLockExclusive(&present_writer_lock);
    if (present_records >= ASTRA_PRESENT_RECORD_LIMIT ||
        present_bytes > ASTRA_PRESENT_BYTE_LIMIT - (uint64_t)record_size)
        goto writer_done;
    /* Append only. Read permission is for GetFileSizeEx, never file contents.
     * Deny other writers while the size check and append are in progress. */
    file = CreateFileA(path, GENERIC_READ | FILE_APPEND_DATA, FILE_SHARE_READ,
                        NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) goto writer_done;
    if (!GetFileSizeEx(file, &file_size) || file_size.QuadPart < 0 ||
        (uint64_t)file_size.QuadPart > ASTRA_PRESENT_BYTE_LIMIT - (uint64_t)record_size)
        goto writer_done;
    /* Reserve attempted bytes too, so a failed/partial write cannot expand
     * the process lifetime budget through retries or external truncation. */
    ++present_records;
    present_bytes += (uint64_t)record_size;
    if (!WriteFile(file, record, (DWORD)record_size, &written, NULL) ||
        written != (DWORD)record_size)
        present_records = ASTRA_PRESENT_RECORD_LIMIT;
writer_done:
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    ReleaseSRWLockExclusive(&present_writer_lock);
done:
    SetLastError(saved_error);
}

#define ASTRA_BC6_SOURCE_RECORD_LIMIT 6144u
#define ASTRA_BC6_SOURCE_TIGHT_LIMIT (32ull * 1024ull * 1024ull)
#define ASTRA_BC6_SOURCE_LOG_LIMIT (16ull * 1024ull * 1024ull)
#define ASTRA_BC6_SOURCE_TIME_MS 120000ull

/* This diagnostic state is process-local, independent of Present/error
 * budgets, and serialized across both upload call sites and all ring threads.
 * The lock is always released before the ordinary transport dispatch. */
static SRWLOCK bc6_source_lock = SRWLOCK_INIT;
static uint32_t bc6_source_records;
static uint64_t bc6_source_tight_bytes, bc6_source_log_bytes, bc6_source_first_ms;
static int bc6_source_started, bc6_source_stopped;

void astra_gpu_trace_bc6_source(const struct astra_bc6_source_metadata *metadata,
                               const void *source)
{
    DWORD saved_error = GetLastError();
    char image[MAX_PATH], temp[MAX_PATH], path[MAX_PATH], record[768];
    const char *client;
    DWORD n, written = 0;
    uint32_t mip, side, rows, tight_row, tight_bytes, reserved = 0;
    uint64_t now_ms, required, hash = 14695981039346656037ull;
    int record_size;
    SYSTEMTIME timestamp;
    HANDLE file = INVALID_HANDLE_VALUE;
    LARGE_INTEGER file_size;

    /* 1D descriptors have height=1; 3D descriptors have array_size=1.
     * These cached scalars therefore select only the specified Texture2D
     * family, including its *1 interface, without a new COM or driver call.
     * DXGI_FORMAT_BC6H_UF16=95; D3D11_USAGE_DEFAULT=0. */
    if (!metadata || !source || metadata->width != 128 || metadata->height != 128 ||
        metadata->depth != 1 || metadata->mip_levels != 8 || metadata->array_size != 6 ||
        metadata->format != 95 || metadata->sample_count != 1 || metadata->usage != 0 ||
        metadata->subresource >= 48 || metadata->origin > ASTRA_BC6_SOURCE_UPDATE)
        goto done;
    mip = metadata->subresource % 8;
    side = 128u >> mip;
    rows = (side + 3u) / 4u;
    tight_row = rows * 16u;
    tight_bytes = rows * tight_row;
    required = (uint64_t)(rows - 1u) * metadata->row_pitch + tight_row;
    if (metadata->row_pitch < tight_row || required > metadata->copy_size)
        goto done;

    /* Match the full actual basename before hashing. Truncated image paths,
     * partial client names, and sanitized near-matches are not admitted. */
    n = GetModuleFileNameA(NULL, image, sizeof(image));
    if (!n || n >= sizeof(image)) goto done;
    client = image;
    for (const char *p = image; *p; ++p)
        if (*p == '\\' || *p == '/') client = p + 1;
    if (strcmp(client, "GenshinImpact.exe") && strcmp(client, "AstraBC6.exe") &&
        strcmp(client, "AstraBC6MapCreate-x64.exe"))
        goto done;

    AcquireSRWLockExclusive(&bc6_source_lock);
    now_ms = GetTickCount64();
    if (bc6_source_stopped) goto writer_done;
    if (!bc6_source_started) {
        bc6_source_started = 1;
        bc6_source_first_ms = now_ms;
    }
    if (now_ms - bc6_source_first_ms >= ASTRA_BC6_SOURCE_TIME_MS ||
        bc6_source_records >= ASTRA_BC6_SOURCE_RECORD_LIMIT ||
        bc6_source_tight_bytes > ASTRA_BC6_SOURCE_TIGHT_LIMIT - tight_bytes) {
        bc6_source_stopped = 1;
        goto writer_done;
    }
    /* Charge attempted work before touching payload or opening the log, so
     * failed writes and external log truncation cannot enlarge these caps. */
    ++bc6_source_records;
    bc6_source_tight_bytes += tight_bytes;
    for (uint32_t y = 0; y < rows; ++y) {
        const uint8_t *row = (const uint8_t *)source + (size_t)y * metadata->row_pitch;
        for (uint32_t x = 0; x < tight_row; ++x) {
            hash ^= row[x];
            hash *= 1099511628211ull;
        }
        for (uint32_t x = 0; x < tight_row; x += 16u) {
            const unsigned mode = row[x] & 31u;
            if ((row[x] & 3u) == 3u &&
                (mode == 19u || mode == 23u || mode == 27u || mode == 31u))
                ++reserved;
        }
    }
    GetSystemTime(&timestamp);
    record_size = _snprintf_s(record, sizeof(record), _TRUNCATE,
        "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ build=resource-convert-v1 "
        "event=bc6_source pid=%lu client=%s ctx=%u resource_id=%016llx "
        "subresource=%u row_pitch=%u copy_size=%u tightbytes=%u "
        "fnv1a64=%016llx reserved_blocks=%u origin=%s\n",
        (unsigned)timestamp.wYear, (unsigned)timestamp.wMonth, (unsigned)timestamp.wDay,
        (unsigned)timestamp.wHour, (unsigned)timestamp.wMinute, (unsigned)timestamp.wSecond,
        (unsigned)timestamp.wMilliseconds, GetCurrentProcessId(), client,
        (unsigned)metadata->ctx, (unsigned long long)metadata->resource_id,
        (unsigned)metadata->subresource, (unsigned)metadata->row_pitch,
        (unsigned)metadata->copy_size, (unsigned)tight_bytes,
        (unsigned long long)hash, (unsigned)reserved,
        metadata->origin == ASTRA_BC6_SOURCE_INITIAL ? "initial" : "update");
    if (record_size <= 0 || bc6_source_log_bytes > ASTRA_BC6_SOURCE_LOG_LIMIT - (uint64_t)record_size) {
        bc6_source_stopped = 1;
        goto writer_done;
    }
    n = GetTempPathA(sizeof(temp), temp);
    if (!n || n >= sizeof(temp) ||
        _snprintf_s(path, sizeof(path), _TRUNCATE, "%sAstraGpu-bc6-source-%lu.log",
                    temp, GetCurrentProcessId()) < 0) {
        bc6_source_stopped = 1;
        goto writer_done;
    }
    /* Append-only file access follows the existing Present logger. Read
     * access is solely for the file size cap; no file contents are read. */
    file = CreateFileA(path, GENERIC_READ | FILE_APPEND_DATA, FILE_SHARE_READ,
                        NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE || !GetFileSizeEx(file, &file_size) ||
        file_size.QuadPart < 0 ||
        (uint64_t)file_size.QuadPart > ASTRA_BC6_SOURCE_LOG_LIMIT - (uint64_t)record_size ||
        GetTickCount64() - bc6_source_first_ms >= ASTRA_BC6_SOURCE_TIME_MS) {
        bc6_source_stopped = 1;
        goto writer_done;
    }
    bc6_source_log_bytes += (uint64_t)record_size;
    if (!WriteFile(file, record, (DWORD)record_size, &written, NULL) ||
        written != (DWORD)record_size)
        bc6_source_stopped = 1;
writer_done:
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    ReleaseSRWLockExclusive(&bc6_source_lock);
done:
    SetLastError(saved_error);
}

/* Map-origin observer: addresses exist only in this fixed private registry.
 * No function below reads through them or keeps a COM/resource reference. */
#define ASTRA_BC6_MAP_RECORDS 512u
#define ASTRA_BC6_MAP_TRANSITIONS 32768u
#define ASTRA_BC6_MAP_QUERIES 6144u
#define ASTRA_BC6_MAP_TIME_MS 120000ull
#define ASTRA_BC6_MAP_RETIRED_MS 10000ull
#define ASTRA_BC6_MAP_LOG_LIMIT (16ull * 1024ull * 1024ull)

struct astra_bc6_map_span {
    uintptr_t start;
    uint64_t resource_id, generation, mapped_ms, retired_ms;
    uint32_t state, ctx, subresource, bytes, map_type, kind, scope;
    uint32_t row_pitch, depth_pitch;
};
static SRWLOCK bc6_map_lock = SRWLOCK_INIT;
static struct astra_bc6_map_span bc6_map_spans[ASTRA_BC6_MAP_RECORDS];
static uint32_t bc6_map_count, bc6_map_transitions, bc6_map_queries;
static uint32_t bc6_map_evictions, bc6_map_overwrites, bc6_map_expired;
static uint32_t bc6_map_dropped, bc6_map_probe_maps;
static uint64_t bc6_map_first_ms, bc6_map_generation;
static int bc6_map_started, bc6_map_history_lost;
static uint32_t bc6_map_stop_reason;
static volatile LONG bc6_map_client_cache;
static __declspec(thread) uint32_t bc6_map_probe_depth;
/* File I/O uses a separate lock, never the registry lock or a Map call. */
static SRWLOCK bc6_map_log_lock = SRWLOCK_INIT;
static uint32_t bc6_map_log_records;
static uint64_t bc6_map_log_bytes;
static int bc6_map_log_stopped;

static void bc6_map_add_dropped(uint32_t count)
{
    bc6_map_dropped = count > UINT32_MAX - bc6_map_dropped
        ? UINT32_MAX : bc6_map_dropped + count;
}

static unsigned bc6_map_client_kind(void)
{
    LONG cached = InterlockedCompareExchange(&bc6_map_client_cache, 0, 0);
    if (cached) return cached > 0 ? (unsigned)cached : 0u;
    char image[MAX_PATH];
    DWORD size = GetModuleFileNameA(NULL, image, sizeof(image));
    LONG kind = -1;
    if (size && size < sizeof(image)) {
        const char *name = image;
        for (const char *p = image; *p; ++p)
            if (*p == '\\' || *p == '/') name = p + 1;
        if (!strcmp(name, "GenshinImpact.exe")) kind = 1;
        else if (!strcmp(name, "AstraBC6.exe")) kind = 2;
        else if (!strcmp(name, "AstraBC6MapCreate-x64.exe")) kind = 3;
    }
    cached = InterlockedCompareExchange(&bc6_map_client_cache, kind, 0);
    if (cached) kind = cached;
    return kind > 0 ? (unsigned)kind : 0u;
}

static int bc6_map_span_valid(const void *data, uint32_t bytes)
{
    return data && bytes && (uintptr_t)data <= UINTPTR_MAX - (bytes - 1u);
}

static int bc6_map_overlap(uintptr_t start, uint32_t bytes,
                           const struct astra_bc6_map_span *span)
{
    /* Difference-based comparison avoids overflowing an exclusive end. */
    return span->state && (start >= span->start
        ? start - span->start < span->bytes : span->start - start < bytes);
}

static void bc6_map_stop_locked(uint32_t reason)
{
    if (!bc6_map_stop_reason) bc6_map_stop_reason = reason;
    bc6_map_history_lost = 1;
    bc6_map_add_dropped(bc6_map_count);
    memset(bc6_map_spans, 0, sizeof(bc6_map_spans));
    bc6_map_count = 0;
}

static int bc6_map_charge_locked(uint32_t count)
{
    if (bc6_map_stop_reason) return 0;
    if (count > ASTRA_BC6_MAP_TRANSITIONS - bc6_map_transitions) {
        bc6_map_stop_locked(ASTRA_BC6_MAP_TRANSITION_LIMIT);
        return 0;
    }
    bc6_map_transitions += count;
    return 1;
}

static int bc6_map_ready_locked(uint64_t now)
{
    if (bc6_map_stop_reason) return 0;
    if (bc6_map_started && now - bc6_map_first_ms >= ASTRA_BC6_MAP_TIME_MS) {
        bc6_map_stop_locked(ASTRA_BC6_MAP_TIME_LIMIT);
        return 0;
    }
    uint32_t expired = 0;
    for (uint32_t i = 0; i < ASTRA_BC6_MAP_RECORDS; ++i)
        if (bc6_map_spans[i].state == ASTRA_BC6_MAP_RETIRED &&
            now - bc6_map_spans[i].retired_ms >= ASTRA_BC6_MAP_RETIRED_MS)
            ++expired;
    if (!bc6_map_charge_locked(expired)) return 0;
    if (expired) {
        for (uint32_t i = 0; i < ASTRA_BC6_MAP_RECORDS; ++i)
            if (bc6_map_spans[i].state == ASTRA_BC6_MAP_RETIRED &&
                now - bc6_map_spans[i].retired_ms >= ASTRA_BC6_MAP_RETIRED_MS)
                bc6_map_spans[i].state = 0;
        bc6_map_count -= expired;
        bc6_map_expired += expired;
        bc6_map_history_lost = 1;
    }
    return 1;
}

void astra_gpu_trace_map_probe_begin(void)
{
    DWORD saved_error = GetLastError();
    if (bc6_map_probe_depth != UINT32_MAX) ++bc6_map_probe_depth;
    SetLastError(saved_error);
}

void astra_gpu_trace_map_probe_end(void)
{
    DWORD saved_error = GetLastError();
    if (bc6_map_probe_depth) --bc6_map_probe_depth;
    SetLastError(saved_error);
}

void astra_gpu_trace_map_return(
    uint32_t ctx, uint64_t resource_id, uint32_t subresource,
    uint32_t map_type, const void *data, uint32_t bytes, uint32_t source_kind,
    uint32_t row_pitch, uint32_t depth_pitch)
{
    DWORD saved_error = GetLastError();
    const int readable = map_type == 1u || map_type == 3u;
    if (!bc6_map_client_kind()) goto done;
    AcquireSRWLockExclusive(&bc6_map_lock);
    if (!bc6_map_span_valid(data, bytes) || !ctx || !resource_id ||
        (source_kind != ASTRA_BC6_MAP_BUFFER && source_kind != ASTRA_BC6_MAP_TEXTURE)) {
        /* This observer follows a successful Map. An invalid descriptor
         * cannot establish non-overlap, including for write-only Maps, so
         * no previously retained interval remains usable as live evidence. */
        if (bc6_map_charge_locked(bc6_map_count)) {
            bc6_map_add_dropped(bc6_map_count + 1u);
            memset(bc6_map_spans, 0, sizeof(bc6_map_spans));
            bc6_map_count = 0;
        }
        bc6_map_history_lost = 1;
        goto unlocked;
    }
    /* Write-only Maps neither start the window nor scan an empty registry. */
    if (!readable && !bc6_map_count) goto unlocked;
    uint64_t now = GetTickCount64();
    if (!bc6_map_ready_locked(now)) goto unlocked;
    uint32_t overlap_count = 0;
    for (uint32_t i = 0; i < ASTRA_BC6_MAP_RECORDS; ++i)
        if (bc6_map_overlap((uintptr_t)data, bytes, &bc6_map_spans[i]))
            ++overlap_count;
    if (!readable && !overlap_count) goto unlocked;
    if (!bc6_map_charge_locked(overlap_count)) goto unlocked;
    if (overlap_count) {
        for (uint32_t i = 0; i < ASTRA_BC6_MAP_RECORDS; ++i)
            if (bc6_map_overlap((uintptr_t)data, bytes, &bc6_map_spans[i]))
                bc6_map_spans[i].state = 0;
        bc6_map_count -= overlap_count;
        bc6_map_overwrites += overlap_count;
        bc6_map_history_lost = 1;
    }
    if (!readable) goto unlocked;

    uint32_t slot = ASTRA_BC6_MAP_RECORDS;
    uint32_t victim = ASTRA_BC6_MAP_RECORDS;
    uint64_t oldest = UINT64_MAX;
    for (uint32_t i = 0; i < ASTRA_BC6_MAP_RECORDS; ++i) {
        if (!bc6_map_spans[i].state) { slot = i; break; }
        if (bc6_map_spans[i].state == ASTRA_BC6_MAP_RETIRED &&
            bc6_map_spans[i].generation < oldest) {
            oldest = bc6_map_spans[i].generation;
            victim = i;
        }
    }
    if (slot == ASTRA_BC6_MAP_RECORDS && victim == ASTRA_BC6_MAP_RECORDS) {
        /* Never evict a known live Map just to admit another one. */
        bc6_map_add_dropped(1);
        bc6_map_history_lost = 1;
        goto unlocked;
    }
    if (!bc6_map_charge_locked(slot == ASTRA_BC6_MAP_RECORDS ? 2u : 1u))
        goto unlocked;
    if (slot == ASTRA_BC6_MAP_RECORDS) {
        slot = victim;
        --bc6_map_count;
        ++bc6_map_evictions;
        bc6_map_history_lost = 1;
    }
    if (!bc6_map_started) {
        bc6_map_started = 1;
        bc6_map_first_ms = now;
    }
    struct astra_bc6_map_span *span = &bc6_map_spans[slot];
    memset(span, 0, sizeof(*span));
    span->start = (uintptr_t)data;
    span->resource_id = resource_id;
    span->generation = ++bc6_map_generation;
    span->mapped_ms = now;
    span->state = ASTRA_BC6_MAP_ACTIVE;
    span->ctx = ctx; span->subresource = subresource; span->bytes = bytes;
    span->map_type = map_type; span->kind = source_kind;
    span->scope = bc6_map_probe_depth ? 1u : 0u;
    span->row_pitch = row_pitch; span->depth_pitch = depth_pitch;
    ++bc6_map_count;
    if (span->scope) ++bc6_map_probe_maps;
unlocked:
    ReleaseSRWLockExclusive(&bc6_map_lock);
done:
    SetLastError(saved_error);
}

void astra_gpu_trace_map_unmap(
    uint32_t ctx, uint64_t resource_id, uint32_t subresource,
    const void *data, uint32_t bytes)
{
    DWORD saved_error = GetLastError();
    if (!bc6_map_client_kind() || !bc6_map_span_valid(data, bytes)) goto done;
    AcquireSRWLockExclusive(&bc6_map_lock);
    if (!bc6_map_count) goto unlocked;
    uint64_t now = GetTickCount64();
    if (!bc6_map_ready_locked(now)) goto unlocked;
    uint32_t count = 0;
    for (uint32_t i = 0; i < ASTRA_BC6_MAP_RECORDS; ++i) {
        const struct astra_bc6_map_span *span = &bc6_map_spans[i];
        if (span->state == ASTRA_BC6_MAP_ACTIVE && span->ctx == ctx &&
            span->resource_id == resource_id && span->subresource == subresource &&
            span->start == (uintptr_t)data &&
            span->bytes == bytes) ++count;
    }
    if (!bc6_map_charge_locked(count)) goto unlocked;
    for (uint32_t i = 0; i < ASTRA_BC6_MAP_RECORDS; ++i) {
        struct astra_bc6_map_span *span = &bc6_map_spans[i];
        if (span->state == ASTRA_BC6_MAP_ACTIVE && span->ctx == ctx &&
            span->resource_id == resource_id && span->subresource == subresource &&
            span->start == (uintptr_t)data &&
            span->bytes == bytes) {
            span->state = ASTRA_BC6_MAP_RETIRED;
            span->retired_ms = now;
        }
    }
unlocked:
    ReleaseSRWLockExclusive(&bc6_map_lock);
done:
    SetLastError(saved_error);
}

void astra_gpu_trace_map_storage_release(const void *data, uint32_t bytes)
{
    DWORD saved_error = GetLastError();
    if (!bc6_map_client_kind() || !bc6_map_span_valid(data, bytes)) goto done;
    AcquireSRWLockExclusive(&bc6_map_lock);
    if (!bc6_map_count || !bc6_map_ready_locked(GetTickCount64())) goto unlocked;
    uint32_t count = 0;
    for (uint32_t i = 0; i < ASTRA_BC6_MAP_RECORDS; ++i)
        if (bc6_map_overlap((uintptr_t)data, bytes, &bc6_map_spans[i])) ++count;
    if (!bc6_map_charge_locked(count)) goto unlocked;
    for (uint32_t i = 0; i < ASTRA_BC6_MAP_RECORDS; ++i)
        if (bc6_map_overlap((uintptr_t)data, bytes, &bc6_map_spans[i]))
            bc6_map_spans[i].state = 0;
    if (count) {
        bc6_map_count -= count;
        bc6_map_add_dropped(count);
        bc6_map_history_lost = 1;
    }
unlocked:
    ReleaseSRWLockExclusive(&bc6_map_lock);
done:
    SetLastError(saved_error);
}

static void bc6_map_query(const void *data, uint32_t bytes,
                           struct astra_bc6_map_origin *result)
{
    DWORD saved_error = GetLastError();
    memset(result, 0, sizeof(*result));
    result->match_state = ASTRA_BC6_MAP_UNAVAILABLE;
    result->query_bytes = bytes;
    AcquireSRWLockExclusive(&bc6_map_lock);
    uint64_t now = GetTickCount64();
    if (bc6_map_queries >= ASTRA_BC6_MAP_QUERIES)
        bc6_map_stop_locked(ASTRA_BC6_MAP_QUERY_LIMIT);
    else
        ++bc6_map_queries;
    if (!bc6_map_span_valid(data, bytes)) {
        result->reason = ASTRA_BC6_MAP_INVALID_QUERY;
        goto counters;
    }
    if (!bc6_map_ready_locked(now)) {
        result->reason = bc6_map_stop_reason;
        goto counters;
    }
    if (!bc6_map_started) {
        result->reason = ASTRA_BC6_MAP_NOT_STARTED;
        goto counters;
    }
    uint32_t chosen = ASTRA_BC6_MAP_RECORDS;
    for (uint32_t i = 0; i < ASTRA_BC6_MAP_RECORDS; ++i) {
        const struct astra_bc6_map_span *span = &bc6_map_spans[i];
        if (span->state && (uintptr_t)data >= span->start &&
            (uintptr_t)data - span->start <= span->bytes &&
            bytes <= span->bytes - ((uintptr_t)data - span->start)) {
            chosen = i;
            ++result->match_count;
        }
    }
    result->reason = bc6_map_history_lost ? ASTRA_BC6_MAP_HISTORY_LOSS : ASTRA_BC6_MAP_OK;
    result->tracking_complete = !bc6_map_history_lost;
    if (result->match_count > 1) {
        result->match_state = ASTRA_BC6_MAP_AMBIGUOUS;
        result->tracking_complete = 0;
    } else if (!result->match_count) {
        result->match_state = bc6_map_history_lost ? ASTRA_BC6_MAP_UNAVAILABLE : ASTRA_BC6_MAP_NO_MATCH;
    } else {
        const struct astra_bc6_map_span *span = &bc6_map_spans[chosen];
        result->match_state = span->state;
        result->source_ctx = span->ctx;
        result->source_resource_id = span->resource_id;
        result->source_subresource = span->subresource;
        result->source_kind = span->kind;
        result->source_map_type = span->map_type;
        result->source_scope = span->scope;
        result->source_bytes = span->bytes;
        result->relative_offset = (uint32_t)((uintptr_t)data - span->start);
        result->source_row_pitch = span->row_pitch;
        result->source_depth_pitch = span->depth_pitch;
        result->map_age_ms = now - span->mapped_ms;
        result->retired_age_ms = span->state == ASTRA_BC6_MAP_RETIRED ? now - span->retired_ms : 0;
        result->source_generation = span->generation;
    }
counters:
    result->transitions = bc6_map_transitions; result->queries = bc6_map_queries;
    result->evictions = bc6_map_evictions; result->overwrites = bc6_map_overwrites;
    result->expired = bc6_map_expired; result->dropped = bc6_map_dropped;
    result->probe_maps = bc6_map_probe_maps;
    for (uint32_t i = 0; i < ASTRA_BC6_MAP_RECORDS; ++i) {
        result->active += bc6_map_spans[i].state == ASTRA_BC6_MAP_ACTIVE;
        result->retired += bc6_map_spans[i].state == ASTRA_BC6_MAP_RETIRED;
    }
    ReleaseSRWLockExclusive(&bc6_map_lock);
    SetLastError(saved_error);
}

#define ASTRA_BC6_ENTRY_RECORD_LIMIT 6144u
#define ASTRA_BC6_ENTRY_TIGHT_LIMIT (32ull * 1024ull * 1024ull)
#define ASTRA_BC6_ENTRY_LOG_LIMIT (16ull * 1024ull * 1024ull)
#define ASTRA_BC6_ENTRY_TIME_MS 120000ull
/* Six complete128-square faces, each with8 BC6 mips. Reserve the whole
 * checkpoint before reading payload, so an admitted capture is never split
 * by the attempted-row/byte limits halfway through a selected cube. */
#define ASTRA_BC6_ENTRY_CUBE_TIGHT_BYTES 131232ull

static SRWLOCK bc6_entry_lock = SRWLOCK_INIT;
static uint32_t bc6_entry_attempted_rows, bc6_entry_log_records;
static uint64_t bc6_entry_tight_bytes, bc6_entry_log_bytes, bc6_entry_first_ms;
static int bc6_entry_started, bc6_entry_work_stopped, bc6_entry_log_stopped;

int astra_gpu_trace_bc6_entry_begin(
    struct astra_bc6_entry_snapshot *snapshot,
    const struct astra_bc6_source_metadata *shape)
{
    DWORD saved_error = GetLastError();
    char image[MAX_PATH];
    const char *client;
    DWORD n;
    uint32_t client_kind;
    uint64_t now_ms;
    int admitted = 0;
    if (!snapshot) goto done;
    snapshot->active = snapshot->complete = 0;
    if (!shape || shape->width != 128u || shape->height != 128u ||
        shape->depth != 1u || shape->mip_levels != 8u || shape->array_size != 6u ||
        shape->format != 95u || shape->sample_count != 1u || shape->usage != 0u)
        goto done;
    n = GetModuleFileNameA(NULL, image, sizeof(image));
    if (!n || n >= sizeof(image)) goto done;
    client = image;
    for (const char *p = image; *p; ++p)
        if (*p == '\\' || *p == '/') client = p + 1;
    if (!strcmp(client, "GenshinImpact.exe")) client_kind = 1u;
    else if (!strcmp(client, "AstraBC6.exe")) client_kind = 2u;
    else if (!strcmp(client, "AstraBC6MapCreate-x64.exe")) client_kind = 3u;
    else goto done;

    AcquireSRWLockExclusive(&bc6_entry_lock);
    now_ms = GetTickCount64();
    if (bc6_entry_work_stopped || bc6_entry_log_stopped) goto rejected;
    if (!bc6_entry_started) {
        bc6_entry_started = 1;
        bc6_entry_first_ms = now_ms;
    }
    if (now_ms - bc6_entry_first_ms >= ASTRA_BC6_ENTRY_TIME_MS ||
        bc6_entry_attempted_rows > ASTRA_BC6_ENTRY_RECORD_LIMIT - ASTRA_BC6_ENTRY_SUBRESOURCES ||
        bc6_entry_tight_bytes > ASTRA_BC6_ENTRY_TIGHT_LIMIT - ASTRA_BC6_ENTRY_CUBE_TIGHT_BYTES) {
        bc6_entry_work_stopped = 1;
        goto rejected;
    }
    bc6_entry_attempted_rows += ASTRA_BC6_ENTRY_SUBRESOURCES;
    bc6_entry_tight_bytes += ASTRA_BC6_ENTRY_CUBE_TIGHT_BYTES;
    memset(snapshot, 0, sizeof(*snapshot));
    snapshot->client_kind = client_kind;
    snapshot->active = 1u;
    admitted = 1;
    /* The caller's bounded48-iteration capture owns this lock until end.
     * It is released before self-device access, host RPC, or ring access. */
    goto done;
rejected:
    ReleaseSRWLockExclusive(&bc6_entry_lock);
done:
    SetLastError(saved_error);
    return admitted;
}

void astra_gpu_trace_bc6_entry_hash(
    struct astra_bc6_entry_snapshot *snapshot, uint32_t subresource,
    uint32_t row_pitch, const void *source)
{
    DWORD saved_error = GetLastError();
    uint32_t side, rows, tight_row, tight_bytes, reserved = 0;
    uint64_t full, required, hash = 14695981039346656037ull;
    SYSTEMTIME timestamp;
    struct astra_bc6_entry_fingerprint *row_metadata;
    if (!snapshot || !snapshot->active || !source ||
        subresource >= ASTRA_BC6_ENTRY_SUBRESOURCES || bc6_entry_work_stopped)
        goto done;
    row_metadata = &snapshot->rows[subresource];
    if (row_metadata->valid) goto done;
    side = 128u >> (subresource % 8u);
    rows = (side + 3u) / 4u;
    tight_row = rows * 16u;
    tight_bytes = rows * tight_row;
    full = (uint64_t)rows * row_pitch;
    required = (uint64_t)(rows - 1u) * row_pitch + tight_row;
    /* Match the existing selected BC6 initial-upload readable extent. No
     * padding bytes are hashed, and the source span cannot wrap uintptr_t.
     * As at the original D3D path, readable lifetime is the caller contract. */
    if (row_pitch < tight_row || full == 0 || full > (64ull << 20) ||
        required > full || required > UINT32_MAX ||
        (uintptr_t)source > UINTPTR_MAX - (required - 1u))
        goto done;
    bc6_map_query(source, (uint32_t)required, &row_metadata->map_origin);
    GetSystemTime(&timestamp);
    row_metadata->year = timestamp.wYear;
    row_metadata->month = timestamp.wMonth;
    row_metadata->day = timestamp.wDay;
    row_metadata->hour = timestamp.wHour;
    row_metadata->minute = timestamp.wMinute;
    row_metadata->second = timestamp.wSecond;
    row_metadata->millisecond = timestamp.wMilliseconds;
    for (uint32_t y = 0; y < rows; ++y) {
        if (GetTickCount64() - bc6_entry_first_ms >= ASTRA_BC6_ENTRY_TIME_MS) {
            bc6_entry_work_stopped = 1;
            goto done;
        }
        const uint8_t *row = (const uint8_t *)source + (size_t)y * row_pitch;
        for (uint32_t x = 0; x < tight_row; ++x) {
            hash ^= row[x];
            hash *= 1099511628211ull;
        }
        for (uint32_t x = 0; x < tight_row; x += 16u) {
            const unsigned mode = row[x] & 31u;
            if ((row[x] & 3u) == 3u &&
                (mode == 19u || mode == 23u || mode == 27u || mode == 31u))
                ++reserved;
        }
    }
    row_metadata->fnv1a64 = hash;
    row_metadata->reserved_blocks = reserved;
    row_metadata->row_pitch = row_pitch;
    row_metadata->copy_size = (uint32_t)required;
    row_metadata->tightbytes = tight_bytes;
    row_metadata->valid = 1u;
    ++snapshot->captured_rows;
done:
    SetLastError(saved_error);
}

void astra_gpu_trace_bc6_entry_end(struct astra_bc6_entry_snapshot *snapshot)
{
    DWORD saved_error = GetLastError();
    if (!snapshot || !snapshot->active) goto done;
    snapshot->complete =
        snapshot->captured_rows == ASTRA_BC6_ENTRY_SUBRESOURCES &&
        GetTickCount64() - bc6_entry_first_ms < ASTRA_BC6_ENTRY_TIME_MS;
    if (GetTickCount64() - bc6_entry_first_ms >= ASTRA_BC6_ENTRY_TIME_MS)
        bc6_entry_work_stopped = 1;
    snapshot->active = 0;
    ReleaseSRWLockExclusive(&bc6_entry_lock);
done:
    SetLastError(saved_error);
}

static const char *bc6_map_match_name(uint32_t value)
{
    switch (value) {
    case ASTRA_BC6_MAP_ACTIVE: return "active";
    case ASTRA_BC6_MAP_RETIRED: return "retired";
    case ASTRA_BC6_MAP_AMBIGUOUS: return "ambiguous";
    case ASTRA_BC6_MAP_NO_MATCH: return "no_match";
    default: return "unavailable";
    }
}

static const char *bc6_map_reason_name(uint32_t value)
{
    switch (value) {
    case ASTRA_BC6_MAP_OK: return "ok";
    case ASTRA_BC6_MAP_NOT_STARTED: return "not_started";
    case ASTRA_BC6_MAP_HISTORY_LOSS: return "history_loss";
    case ASTRA_BC6_MAP_TIME_LIMIT: return "time_limit";
    case ASTRA_BC6_MAP_TRANSITION_LIMIT: return "transition_limit";
    case ASTRA_BC6_MAP_QUERY_LIMIT: return "query_limit";
    default: return "invalid_query";
    }
}

static void bc6_map_emit_snapshot(const struct astra_bc6_entry_snapshot *snapshot,
                                  uint32_t ctx, uint64_t resource_id,
                                  const char *client)
{
    DWORD saved_error = GetLastError();
    char temp[MAX_PATH], path[MAX_PATH], record[1536];
    DWORD n, written = 0;
    HANDLE file = INVALID_HANDLE_VALUE;
    LARGE_INTEGER file_size;
    AcquireSRWLockExclusive(&bc6_map_log_lock);
    if (bc6_map_log_stopped) goto writer_done;
    if (GetTickCount64() - bc6_entry_first_ms >= ASTRA_BC6_ENTRY_TIME_MS) {
        bc6_map_log_stopped = 1;
        goto writer_done;
    }
    n = GetTempPathA(sizeof(temp), temp);
    if (!n || n >= sizeof(temp) ||
        _snprintf_s(path, sizeof(path), _TRUNCATE, "%sAstraGpu-bc6-map-origin-%lu.log",
                    temp, GetCurrentProcessId()) < 0) {
        bc6_map_log_stopped = 1;
        goto writer_done;
    }
    file = CreateFileA(path, GENERIC_READ | FILE_APPEND_DATA, FILE_SHARE_READ,
                        NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE || !GetFileSizeEx(file, &file_size) ||
        file_size.QuadPart < 0) {
        bc6_map_log_stopped = 1;
        goto writer_done;
    }
    for (uint32_t sub = 0; sub < ASTRA_BC6_ENTRY_SUBRESOURCES; ++sub) {
        const struct astra_bc6_entry_fingerprint *fingerprint = &snapshot->rows[sub];
        const struct astra_bc6_map_origin *origin = &fingerprint->map_origin;
        int size = _snprintf_s(record, sizeof(record), _TRUNCATE,
            "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ build=resource-convert-v1 "
            "event=bc6_map_origin pid=%lu client=%s ctx=%u resource_id=%016llx "
            "subresource=%u query_bytes=%u match_state=%s tracking_complete=%u "
            "reason=%s match_count=%u transitions=%u queries=%u evictions=%u "
            "overwrites=%u expired=%u dropped=%u active=%u retired=%u probe_maps=%u",
            (unsigned)fingerprint->year, (unsigned)fingerprint->month,
            (unsigned)fingerprint->day, (unsigned)fingerprint->hour,
            (unsigned)fingerprint->minute, (unsigned)fingerprint->second,
            (unsigned)fingerprint->millisecond, GetCurrentProcessId(), client,
            (unsigned)ctx, (unsigned long long)resource_id, (unsigned)sub,
            (unsigned)origin->query_bytes, bc6_map_match_name(origin->match_state),
            (unsigned)origin->tracking_complete, bc6_map_reason_name(origin->reason),
            (unsigned)origin->match_count, (unsigned)origin->transitions,
            (unsigned)origin->queries, (unsigned)origin->evictions,
            (unsigned)origin->overwrites, (unsigned)origin->expired,
            (unsigned)origin->dropped, (unsigned)origin->active,
            (unsigned)origin->retired, (unsigned)origin->probe_maps);
        if (size <= 0) { bc6_map_log_stopped = 1; goto writer_done; }
        if (origin->match_state == ASTRA_BC6_MAP_ACTIVE ||
            origin->match_state == ASTRA_BC6_MAP_RETIRED) {
            int extra = _snprintf_s(record + size, sizeof(record) - (size_t)size, _TRUNCATE,
                " source_ctx=%u source_resource_id=%016llx source_subresource=%u "
                "source_kind=%s source_map_type=%u source_scope=%s source_bytes=%u "
                "relative_offset=%u source_row_pitch=%u source_depth_pitch=%u "
                "map_age_ms=%llu retired_age_ms=%llu source_generation=%llu",
                (unsigned)origin->source_ctx, (unsigned long long)origin->source_resource_id,
                (unsigned)origin->source_subresource,
                origin->source_kind == ASTRA_BC6_MAP_BUFFER ? "buffer" : "texture",
                (unsigned)origin->source_map_type,
                origin->source_scope ? "staging_busy_probe" : "ordinary",
                (unsigned)origin->source_bytes, (unsigned)origin->relative_offset,
                (unsigned)origin->source_row_pitch, (unsigned)origin->source_depth_pitch,
                (unsigned long long)origin->map_age_ms,
                (unsigned long long)origin->retired_age_ms,
                (unsigned long long)origin->source_generation);
            if (extra <= 0) { bc6_map_log_stopped = 1; goto writer_done; }
            size += extra;
        }
        if ((size_t)size + 1u >= sizeof(record) ||
            bc6_map_log_records >= ASTRA_BC6_ENTRY_RECORD_LIMIT ||
            bc6_map_log_bytes > ASTRA_BC6_MAP_LOG_LIMIT - (uint64_t)(size + 1) ||
            (uint64_t)file_size.QuadPart > ASTRA_BC6_MAP_LOG_LIMIT - (uint64_t)(size + 1) ||
            GetTickCount64() - bc6_entry_first_ms >= ASTRA_BC6_ENTRY_TIME_MS) {
            bc6_map_log_stopped = 1;
            goto writer_done;
        }
        record[size++] = '\n';
        ++bc6_map_log_records;
        bc6_map_log_bytes += (uint64_t)size;
        if (!WriteFile(file, record, (DWORD)size, &written, NULL) || written != (DWORD)size) {
            bc6_map_log_stopped = 1;
            goto writer_done;
        }
        file_size.QuadPart += size;
    }
writer_done:
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    ReleaseSRWLockExclusive(&bc6_map_log_lock);
    SetLastError(saved_error);
}

void astra_gpu_trace_bc6_entry_emit(
    const struct astra_bc6_entry_snapshot *snapshot,
    uint32_t ctx, uint64_t resource_id)
{
    DWORD saved_error = GetLastError();
    char temp[MAX_PATH], path[MAX_PATH], record[768];
    const char *client;
    DWORD n, written = 0;
    HANDLE file = INVALID_HANDLE_VALUE;
    LARGE_INTEGER file_size;
    if (!snapshot || snapshot->active || !snapshot->complete ||
        snapshot->captured_rows != ASTRA_BC6_ENTRY_SUBRESOURCES || !ctx || !resource_id)
        goto done;
    client = snapshot->client_kind == 1u ? "GenshinImpact.exe" :
             snapshot->client_kind == 2u ? "AstraBC6.exe" :
             snapshot->client_kind == 3u ? "AstraBC6MapCreate-x64.exe" : NULL;
    if (!client) goto done;
    for (uint32_t sub = 0; sub < ASTRA_BC6_ENTRY_SUBRESOURCES; ++sub)
        if (!snapshot->rows[sub].valid) goto done;

    /* Results were copied at entry, before payload hashing. Only now do we
     * correlate them with the successful Create's opaque destination ID. */
    bc6_map_emit_snapshot(snapshot, ctx, resource_id, client);
    AcquireSRWLockExclusive(&bc6_entry_lock);
    if (bc6_entry_log_stopped) goto writer_done;
    if (GetTickCount64() - bc6_entry_first_ms >= ASTRA_BC6_ENTRY_TIME_MS) {
        bc6_entry_work_stopped = bc6_entry_log_stopped = 1;
        goto writer_done;
    }
    n = GetTempPathA(sizeof(temp), temp);
    if (!n || n >= sizeof(temp) ||
        _snprintf_s(path, sizeof(path), _TRUNCATE, "%sAstraGpu-bc6-entry-%lu.log",
                    temp, GetCurrentProcessId()) < 0) {
        bc6_entry_work_stopped = bc6_entry_log_stopped = 1;
        goto writer_done;
    }
    file = CreateFileA(path, GENERIC_READ | FILE_APPEND_DATA, FILE_SHARE_READ,
                        NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE || !GetFileSizeEx(file, &file_size) ||
        file_size.QuadPart < 0) {
        bc6_entry_work_stopped = bc6_entry_log_stopped = 1;
        goto writer_done;
    }
    for (uint32_t sub = 0; sub < ASTRA_BC6_ENTRY_SUBRESOURCES; ++sub) {
        const struct astra_bc6_entry_fingerprint *fingerprint = &snapshot->rows[sub];
        int record_size = _snprintf_s(record, sizeof(record), _TRUNCATE,
            "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ build=resource-convert-v1 "
            "event=bc6_entry pid=%lu client=%s ctx=%u resource_id=%016llx "
            "subresource=%u row_pitch=%u copy_size=%u tightbytes=%u "
            "fnv1a64=%016llx reserved_blocks=%u origin=initial\n",
            (unsigned)fingerprint->year, (unsigned)fingerprint->month,
            (unsigned)fingerprint->day, (unsigned)fingerprint->hour,
            (unsigned)fingerprint->minute, (unsigned)fingerprint->second,
            (unsigned)fingerprint->millisecond, GetCurrentProcessId(), client,
            (unsigned)ctx, (unsigned long long)resource_id, (unsigned)sub,
            (unsigned)fingerprint->row_pitch, (unsigned)fingerprint->copy_size,
            (unsigned)fingerprint->tightbytes,
            (unsigned long long)fingerprint->fnv1a64,
            (unsigned)fingerprint->reserved_blocks);
        if (record_size <= 0 ||
            bc6_entry_log_records >= ASTRA_BC6_ENTRY_RECORD_LIMIT ||
            bc6_entry_log_bytes > ASTRA_BC6_ENTRY_LOG_LIMIT - (uint64_t)record_size ||
            (uint64_t)file_size.QuadPart > ASTRA_BC6_ENTRY_LOG_LIMIT - (uint64_t)record_size ||
            GetTickCount64() - bc6_entry_first_ms >= ASTRA_BC6_ENTRY_TIME_MS) {
            bc6_entry_work_stopped = bc6_entry_log_stopped = 1;
            goto writer_done;
        }
        /* Attempted writes and preexisting on-disk bytes both count. */
        ++bc6_entry_log_records;
        bc6_entry_log_bytes += (uint64_t)record_size;
        if (!WriteFile(file, record, (DWORD)record_size, &written, NULL) ||
            written != (DWORD)record_size) {
            bc6_entry_work_stopped = bc6_entry_log_stopped = 1;
            goto writer_done;
        }
        file_size.QuadPart += record_size;
    }
writer_done:
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    ReleaseSRWLockExclusive(&bc6_entry_lock);
done:
    SetLastError(saved_error);
}

/* Independent descriptor admission/write budgets. No diagnostic lock survives
 * begin or spans the existing Create call. A failed Create still uses its
 * admission; an uncorrelated or expired snapshot produces no evidence row. */
#define ASTRA_BC6_DDI_DESC_LIMIT 128u
#define ASTRA_BC6_DDI_DESC_TIME_MS 120000ull
#define ASTRA_BC6_DDI_DESC_LOG_LIMIT (16ull * 1024ull * 1024ull)
static SRWLOCK bc6_ddi_desc_lock = SRWLOCK_INIT;
static uint32_t bc6_ddi_desc_admissions, bc6_ddi_desc_records;
static uint64_t bc6_ddi_desc_first_ms, bc6_ddi_desc_log_bytes;
static int bc6_ddi_desc_started, bc6_ddi_desc_stopped;

int astra_gpu_trace_bc6_ddi_desc_allowed(void)
{
    DWORD saved_error = GetLastError();
    int allowed = bc6_map_client_kind() != 0;
    SetLastError(saved_error);
    return allowed;
}

void astra_gpu_trace_bc6_ddi_desc_begin(struct astra_bc6_ddi_desc_snapshot *snapshot)
{
    DWORD saved_error = GetLastError();
    if (!snapshot) goto done;
    snapshot->admitted = snapshot->converted_valid = 0;
    unsigned client_kind = bc6_map_client_kind();
    if (!client_kind) goto done;
    AcquireSRWLockExclusive(&bc6_ddi_desc_lock);
    uint64_t now_ms = GetTickCount64();
    if (bc6_ddi_desc_stopped || bc6_ddi_desc_admissions >= ASTRA_BC6_DDI_DESC_LIMIT)
        goto unlocked;
    if (!bc6_ddi_desc_started) {
        bc6_ddi_desc_started = 1;
        bc6_ddi_desc_first_ms = now_ms;
    }
    if (now_ms - bc6_ddi_desc_first_ms >= ASTRA_BC6_DDI_DESC_TIME_MS) {
        bc6_ddi_desc_stopped = 1;
        goto unlocked;
    }
    snapshot->seq = ++bc6_ddi_desc_admissions;
    snapshot->client_kind = client_kind;
    SYSTEMTIME timestamp;
    GetSystemTime(&timestamp);
    snapshot->year = timestamp.wYear;
    snapshot->month = timestamp.wMonth;
    snapshot->day = timestamp.wDay;
    snapshot->hour = timestamp.wHour;
    snapshot->minute = timestamp.wMinute;
    snapshot->second = timestamp.wSecond;
    snapshot->millisecond = timestamp.wMilliseconds;
    snapshot->admitted = 1;
unlocked:
    ReleaseSRWLockExclusive(&bc6_ddi_desc_lock);
done:
    SetLastError(saved_error);
}

void astra_gpu_trace_bc6_ddi_desc_emit(
    const struct astra_bc6_ddi_desc_snapshot *snapshot,
    uint32_t ctx, uint64_t resource_id)
{
    DWORD saved_error = GetLastError();
    char temp[MAX_PATH], path[MAX_PATH], record[2048];
    HANDLE file = INVALID_HANDLE_VALUE;
    LARGE_INTEGER file_size;
    DWORD n, written = 0;
    if (!snapshot || !snapshot->admitted || !snapshot->converted_valid ||
        !snapshot->seq || snapshot->seq > ASTRA_BC6_DDI_DESC_LIMIT || !ctx || !resource_id)
        goto done;
    const char *client = snapshot->client_kind == 1u ? "GenshinImpact.exe" :
                         snapshot->client_kind == 2u ? "AstraBC6.exe" :
                         snapshot->client_kind == 3u ? "AstraBC6MapCreate-x64.exe" : NULL;
    if (!client) goto done;
    const struct astra_bc6_ddi_raw_desc *raw = &snapshot->raw;
    const struct astra_bc6_ddi_converted_desc *converted = &snapshot->converted;
    AcquireSRWLockExclusive(&bc6_ddi_desc_lock);
    if (bc6_ddi_desc_stopped || !bc6_ddi_desc_started) goto writer_done;
    if (GetTickCount64() - bc6_ddi_desc_first_ms >= ASTRA_BC6_DDI_DESC_TIME_MS ||
        bc6_ddi_desc_records >= ASTRA_BC6_DDI_DESC_LIMIT) {
        bc6_ddi_desc_stopped = 1;
        goto writer_done;
    }
    int record_size = _snprintf_s(record, sizeof(record), _TRUNCATE,
        "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ build=resource-convert-v1 "
        "event=bc6_ddi_desc pid=%lu client=%s ctx=%u resource_id=%016llx seq=%u "
        "raw_dimension=%u raw_format=%u raw_usage=%u raw_map_flags=%u "
        "raw_mip_levels=%u raw_array_size=%u raw_sample_count=%u raw_sample_quality=%u "
        "raw_byte_stride=%u raw_bind_flags=%u raw_misc_flags=%u "
        "raw_initial_data_present=%u raw_mip_info_present=%u raw_primary_desc_present=%u "
        "raw_texel_width=%u raw_texel_height=%u raw_texel_depth=%u "
        "raw_physical_width=%u raw_physical_height=%u raw_physical_depth=%u "
        "converted_width=%u converted_height=%u converted_mip_levels=%u converted_array_size=%u "
        "converted_format=%u converted_sample_count=%u converted_sample_quality=%u "
        "converted_usage=%u converted_bind_flags=%u converted_cpu_access_flags=%u "
        "converted_misc_flags=%u converted_initial_data_present=%u\n",
        (unsigned)snapshot->year, (unsigned)snapshot->month, (unsigned)snapshot->day,
        (unsigned)snapshot->hour, (unsigned)snapshot->minute, (unsigned)snapshot->second,
        (unsigned)snapshot->millisecond, GetCurrentProcessId(), client,
        (unsigned)ctx, (unsigned long long)resource_id, (unsigned)snapshot->seq,
        (unsigned)raw->dimension, (unsigned)raw->format, (unsigned)raw->usage,
        (unsigned)raw->map_flags, (unsigned)raw->mip_levels, (unsigned)raw->array_size,
        (unsigned)raw->sample_count, (unsigned)raw->sample_quality, (unsigned)raw->byte_stride,
        (unsigned)raw->bind_flags, (unsigned)raw->misc_flags,
        (unsigned)raw->initial_data_present, (unsigned)raw->mip_info_present,
        (unsigned)raw->primary_desc_present, (unsigned)raw->texel_width,
        (unsigned)raw->texel_height, (unsigned)raw->texel_depth,
        (unsigned)raw->physical_width, (unsigned)raw->physical_height, (unsigned)raw->physical_depth,
        (unsigned)converted->width, (unsigned)converted->height,
        (unsigned)converted->mip_levels, (unsigned)converted->array_size,
        (unsigned)converted->format, (unsigned)converted->sample_count,
        (unsigned)converted->sample_quality, (unsigned)converted->usage,
        (unsigned)converted->bind_flags, (unsigned)converted->cpu_access_flags,
        (unsigned)converted->misc_flags, (unsigned)converted->initial_data_present);
    if (record_size <= 0 ||
        bc6_ddi_desc_log_bytes > ASTRA_BC6_DDI_DESC_LOG_LIMIT - (uint64_t)record_size) {
        bc6_ddi_desc_stopped = 1;
        goto writer_done;
    }
    n = GetTempPathA(sizeof(temp), temp);
    if (!n || n >= sizeof(temp) ||
        _snprintf_s(path, sizeof(path), _TRUNCATE, "%sAstraGpu-bc6-ddi-desc-%lu.log",
                    temp, GetCurrentProcessId()) < 0) {
        bc6_ddi_desc_stopped = 1;
        goto writer_done;
    }
    file = CreateFileA(path, GENERIC_READ | FILE_APPEND_DATA, FILE_SHARE_READ,
                        NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE || !GetFileSizeEx(file, &file_size) ||
        file_size.QuadPart < 0 ||
        (uint64_t)file_size.QuadPart > ASTRA_BC6_DDI_DESC_LOG_LIMIT - (uint64_t)record_size ||
        GetTickCount64() - bc6_ddi_desc_first_ms >= ASTRA_BC6_DDI_DESC_TIME_MS) {
        bc6_ddi_desc_stopped = 1;
        goto writer_done;
    }
    /* Charge attempted bytes before writing; truncation cannot renew quota. */
    ++bc6_ddi_desc_records;
    bc6_ddi_desc_log_bytes += (uint64_t)record_size;
    if (!WriteFile(file, record, (DWORD)record_size, &written, NULL) ||
        written != (DWORD)record_size)
        bc6_ddi_desc_stopped = 1;
writer_done:
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    ReleaseSRWLockExclusive(&bc6_ddi_desc_lock);
done:
    SetLastError(saved_error);
}

/* Original-DDI hashes have independent work/log budgets. No file or Map
 * observer operation occurs during capture, and end releases this lock before
 * any normal resource write, conversion, allocation, COM call, or Create. */
#define ASTRA_BC6_DDI_SOURCE_CREATE_LIMIT 128u
#define ASTRA_BC6_DDI_SOURCE_RECORD_LIMIT 6144u
#define ASTRA_BC6_DDI_SOURCE_TIGHT_LIMIT (32ull * 1024ull * 1024ull)
#define ASTRA_BC6_DDI_SOURCE_BATCH_TIGHT_BYTES 131232ull
#define ASTRA_BC6_DDI_SOURCE_TIME_MS 120000ull
#define ASTRA_BC6_DDI_SOURCE_LOG_LIMIT (16ull * 1024ull * 1024ull)
static SRWLOCK bc6_ddi_source_lock = SRWLOCK_INIT;
static uint32_t bc6_ddi_source_creates, bc6_ddi_source_attempted_rows, bc6_ddi_source_log_records;
static uint64_t bc6_ddi_source_tight_bytes, bc6_ddi_source_log_bytes, bc6_ddi_source_first_ms;
static int bc6_ddi_source_started, bc6_ddi_source_work_stopped, bc6_ddi_source_log_stopped;

int astra_gpu_trace_bc6_ddi_source_begin(struct astra_bc6_ddi_source_snapshot *snapshot)
{
    DWORD saved_error = GetLastError();
    int admitted = 0;
    if (!snapshot) goto done;
    snapshot->active = snapshot->complete = 0;
    unsigned client_kind = bc6_map_client_kind();
    if (!client_kind) goto done;
    AcquireSRWLockExclusive(&bc6_ddi_source_lock);
    uint64_t now_ms = GetTickCount64();
    if (bc6_ddi_source_work_stopped || bc6_ddi_source_log_stopped) goto rejected;
    if (!bc6_ddi_source_started) {
        bc6_ddi_source_started = 1;
        bc6_ddi_source_first_ms = now_ms;
    }
    if (now_ms - bc6_ddi_source_first_ms >= ASTRA_BC6_DDI_SOURCE_TIME_MS ||
        bc6_ddi_source_creates >= ASTRA_BC6_DDI_SOURCE_CREATE_LIMIT ||
        bc6_ddi_source_attempted_rows > ASTRA_BC6_DDI_SOURCE_RECORD_LIMIT - ASTRA_BC6_DDI_SOURCE_SUBRESOURCES ||
        bc6_ddi_source_tight_bytes > ASTRA_BC6_DDI_SOURCE_TIGHT_LIMIT - ASTRA_BC6_DDI_SOURCE_BATCH_TIGHT_BYTES) {
        bc6_ddi_source_work_stopped = 1;
        goto rejected;
    }
    /* Reserve and charge the whole attempt before reading any UP payload.
     * Invalid later descriptors, failed Creates, and failed writes refund none. */
    ++bc6_ddi_source_creates;
    bc6_ddi_source_attempted_rows += ASTRA_BC6_DDI_SOURCE_SUBRESOURCES;
    bc6_ddi_source_tight_bytes += ASTRA_BC6_DDI_SOURCE_BATCH_TIGHT_BYTES;
    memset(snapshot, 0, sizeof(*snapshot));
    snapshot->client_kind = client_kind;
    snapshot->active = 1;
    admitted = 1;
    goto done;
rejected:
    ReleaseSRWLockExclusive(&bc6_ddi_source_lock);
done:
    SetLastError(saved_error);
    return admitted;
}

int astra_gpu_trace_bc6_ddi_source_hash(
    struct astra_bc6_ddi_source_snapshot *snapshot, uint32_t subresource,
    uint32_t row_pitch, const void *source)
{
    DWORD saved_error = GetLastError();
    int captured = 0;
    uint32_t side, rows, tight_row, tight_bytes, reserved = 0;
    uint64_t full, required, hash = 14695981039346656037ull;
    SYSTEMTIME timestamp;
    struct astra_bc6_ddi_source_fingerprint *row_metadata;
    if (!snapshot || !snapshot->active || !source ||
        subresource >= ASTRA_BC6_DDI_SOURCE_SUBRESOURCES ||
        subresource != snapshot->captured_rows || bc6_ddi_source_work_stopped)
        goto done;
    row_metadata = &snapshot->rows[subresource];
    side = 128u >> (subresource % 8u);
    rows = (side + 3u) / 4u;
    tight_row = rows * 16u;
    tight_bytes = rows * tight_row;
    full = (uint64_t)rows * row_pitch;
    required = (uint64_t)(rows - 1u) * row_pitch + tight_row;
    /* Same bounded 2D readable-span contract and tight-row kernel as entry.
     * The caller owns readable lifetime; no padding or slice pitch is read. */
    if (row_pitch < tight_row || full == 0 || full > (64ull << 20) ||
        required > full || required > UINT32_MAX ||
        (uintptr_t)source > UINTPTR_MAX - (required - 1u))
        goto done;
    GetSystemTime(&timestamp);
    row_metadata->year = timestamp.wYear;
    row_metadata->month = timestamp.wMonth;
    row_metadata->day = timestamp.wDay;
    row_metadata->hour = timestamp.wHour;
    row_metadata->minute = timestamp.wMinute;
    row_metadata->second = timestamp.wSecond;
    row_metadata->millisecond = timestamp.wMilliseconds;
    for (uint32_t y = 0; y < rows; ++y) {
        if (GetTickCount64() - bc6_ddi_source_first_ms >= ASTRA_BC6_DDI_SOURCE_TIME_MS) {
            bc6_ddi_source_work_stopped = 1;
            goto done;
        }
        const uint8_t *row = (const uint8_t *)source + (size_t)y * row_pitch;
        for (uint32_t x = 0; x < tight_row; ++x) {
            hash ^= row[x];
            hash *= 1099511628211ull;
        }
        for (uint32_t x = 0; x < tight_row; x += 16u) {
            const unsigned mode = row[x] & 31u;
            if ((row[x] & 3u) == 3u &&
                (mode == 19u || mode == 23u || mode == 27u || mode == 31u))
                ++reserved;
        }
    }
    row_metadata->fnv1a64 = hash;
    row_metadata->reserved_blocks = reserved;
    row_metadata->row_pitch = row_pitch;
    row_metadata->copy_size = (uint32_t)required;
    row_metadata->tightbytes = tight_bytes;
    row_metadata->valid = 1;
    ++snapshot->captured_rows;
    captured = 1;
done:
    SetLastError(saved_error);
    return captured;
}

void astra_gpu_trace_bc6_ddi_source_end(struct astra_bc6_ddi_source_snapshot *snapshot)
{
    DWORD saved_error = GetLastError();
    if (!snapshot || !snapshot->active) goto done;
    if (GetTickCount64() - bc6_ddi_source_first_ms >= ASTRA_BC6_DDI_SOURCE_TIME_MS)
        bc6_ddi_source_work_stopped = 1;
    snapshot->complete = snapshot->captured_rows == ASTRA_BC6_DDI_SOURCE_SUBRESOURCES &&
                         !bc6_ddi_source_work_stopped;
    snapshot->active = 0;
    ReleaseSRWLockExclusive(&bc6_ddi_source_lock);
done:
    SetLastError(saved_error);
}

void astra_gpu_trace_bc6_ddi_source_emit(
    const struct astra_bc6_ddi_source_snapshot *snapshot,
    uint32_t ctx, uint64_t resource_id)
{
    DWORD saved_error = GetLastError();
    char temp[MAX_PATH], path[MAX_PATH], record[768];
    HANDLE file = INVALID_HANDLE_VALUE;
    LARGE_INTEGER file_size;
    DWORD n, written = 0;
    if (!snapshot || snapshot->active || !snapshot->complete ||
        snapshot->captured_rows != ASTRA_BC6_DDI_SOURCE_SUBRESOURCES || !ctx || !resource_id)
        goto done;
    const char *client = snapshot->client_kind == 1u ? "GenshinImpact.exe" :
                         snapshot->client_kind == 2u ? "AstraBC6.exe" :
                         snapshot->client_kind == 3u ? "AstraBC6MapCreate-x64.exe" : NULL;
    if (!client) goto done;
    for (uint32_t sub = 0; sub < ASTRA_BC6_DDI_SOURCE_SUBRESOURCES; ++sub)
        if (!snapshot->rows[sub].valid) goto done;
    AcquireSRWLockExclusive(&bc6_ddi_source_lock);
    if (bc6_ddi_source_log_stopped) goto writer_done;
    if (GetTickCount64() - bc6_ddi_source_first_ms >= ASTRA_BC6_DDI_SOURCE_TIME_MS) {
        bc6_ddi_source_work_stopped = bc6_ddi_source_log_stopped = 1;
        goto writer_done;
    }
    n = GetTempPathA(sizeof(temp), temp);
    if (!n || n >= sizeof(temp) ||
        _snprintf_s(path, sizeof(path), _TRUNCATE, "%sAstraGpu-bc6-ddi-source-%lu.log",
                    temp, GetCurrentProcessId()) < 0) {
        bc6_ddi_source_work_stopped = bc6_ddi_source_log_stopped = 1;
        goto writer_done;
    }
    file = CreateFileA(path, GENERIC_READ | FILE_APPEND_DATA, FILE_SHARE_READ,
                        NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE || !GetFileSizeEx(file, &file_size) || file_size.QuadPart < 0) {
        bc6_ddi_source_work_stopped = bc6_ddi_source_log_stopped = 1;
        goto writer_done;
    }
    for (uint32_t sub = 0; sub < ASTRA_BC6_DDI_SOURCE_SUBRESOURCES; ++sub) {
        const struct astra_bc6_ddi_source_fingerprint *row = &snapshot->rows[sub];
        int record_size = _snprintf_s(record, sizeof(record), _TRUNCATE,
            "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ build=resource-convert-v1 "
            "event=bc6_ddi_source pid=%lu client=%s ctx=%u resource_id=%016llx "
            "subresource=%u row_pitch=%u copy_size=%u tightbytes=%u "
            "fnv1a64=%016llx reserved_blocks=%u origin=initial\n",
            (unsigned)row->year, (unsigned)row->month, (unsigned)row->day,
            (unsigned)row->hour, (unsigned)row->minute, (unsigned)row->second,
            (unsigned)row->millisecond, GetCurrentProcessId(), client,
            (unsigned)ctx, (unsigned long long)resource_id, (unsigned)sub,
            (unsigned)row->row_pitch, (unsigned)row->copy_size, (unsigned)row->tightbytes,
            (unsigned long long)row->fnv1a64, (unsigned)row->reserved_blocks);
        if (record_size <= 0 ||
            bc6_ddi_source_log_records >= ASTRA_BC6_DDI_SOURCE_RECORD_LIMIT ||
            bc6_ddi_source_log_bytes > ASTRA_BC6_DDI_SOURCE_LOG_LIMIT - (uint64_t)record_size ||
            (uint64_t)file_size.QuadPart > ASTRA_BC6_DDI_SOURCE_LOG_LIMIT - (uint64_t)record_size ||
            GetTickCount64() - bc6_ddi_source_first_ms >= ASTRA_BC6_DDI_SOURCE_TIME_MS) {
            bc6_ddi_source_work_stopped = bc6_ddi_source_log_stopped = 1;
            goto writer_done;
        }
        ++bc6_ddi_source_log_records;
        bc6_ddi_source_log_bytes += (uint64_t)record_size;
        if (!WriteFile(file, record, (DWORD)record_size, &written, NULL) ||
            written != (DWORD)record_size) {
            bc6_ddi_source_work_stopped = bc6_ddi_source_log_stopped = 1;
            goto writer_done;
        }
        file_size.QuadPart += record_size;
    }
writer_done:
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    ReleaseSRWLockExclusive(&bc6_ddi_source_lock);
done:
    SetLastError(saved_error);
}
