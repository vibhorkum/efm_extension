/*-------------------------------------------------------------------------
 *
 * efm_cache.c
 *      Shared memory cache for EFM status data
 *
 * This module provides a shared memory cache to avoid frequent shell calls
 * to EFM for status information. The cache is automatically invalidated
 * based on a configurable TTL.
 *
 * Copyright (c) 2024, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "efm_cache.h"

#include "miscadmin.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "utils/timestamp.h"

/* Shared memory structure for cache */
typedef struct EfmStatusCache
{
    LWLock      lock;
    TimestampTz last_update;
    uint64      hits;
    uint64      misses;
    uint64      updates;
    Size        data_len;
    char        data[EFM_CACHE_SIZE];
} EfmStatusCache;

/* Pointer to shared memory segment */
static EfmStatusCache *efm_cache = NULL;

/* GUC variable */
int efm_cache_ttl = 5;  /* Default 5 seconds */

/*
 * Calculate shared memory size needed
 */
Size
efm_shmem_size(void)
{
    return MAXALIGN(sizeof(EfmStatusCache));
}

/*
 * Request shared memory space during postmaster startup
 */
void
efm_shmem_request(void)
{
#if PG_VERSION_NUM >= 150000
    if (process_shared_preload_libraries_in_progress)
    {
        RequestAddinShmemSpace(efm_shmem_size());
        /* We use an embedded LWLock in the cache struct, no need for named tranche */
    }
#endif
}

/*
 * Initialize shared memory segment during postmaster startup
 */
void
efm_shmem_startup(void)
{
    bool found;

    LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);

    efm_cache = ShmemInitStruct("efm_status_cache",
                                efm_shmem_size(),
                                &found);

    if (!found)
    {
        /* First time - initialize the cache */
        memset(efm_cache, 0, sizeof(EfmStatusCache));

        /*
         * Initialize an embedded LWLock with a dynamically allocated tranche ID.
         * This is the standard approach for extension-owned locks.
         */
        LWLockInitialize(&efm_cache->lock, LWLockNewTrancheId());
        LWLockRegisterTranche(efm_cache->lock.tranche, "efm_extension");

        efm_cache->last_update = 0;
        efm_cache->hits = 0;
        efm_cache->misses = 0;
        efm_cache->updates = 0;
        efm_cache->data_len = 0;
    }

    LWLockRelease(AddinShmemInitLock);
}

/*
 * Check if the cache contains valid (non-expired) data
 */
bool
efm_cache_valid(void)
{
    TimestampTz now;
    TimestampTz expiry;
    bool valid;

    /* Cache disabled if TTL is 0 or negative */
    if (efm_cache_ttl <= 0)
        return false;

    /* Cache not initialized */
    if (efm_cache == NULL)
        return false;

    now = GetCurrentTimestamp();

    LWLockAcquire(&efm_cache->lock, LW_SHARED);

    /* Check if we have data and it's not expired */
    if (efm_cache->data_len == 0)
    {
        valid = false;
    }
    else
    {
        /* Calculate expiry time */
        expiry = TimestampTzPlusMilliseconds(efm_cache->last_update,
                                             efm_cache_ttl * 1000);
        valid = (now <= expiry);
    }

    LWLockRelease(&efm_cache->lock);

    return valid;
}

/*
 * Get cached status data
 *
 * Returns a palloc'd copy of the cached data, or NULL if no data is cached.
 *
 * IMPORTANT: This function does NOT check TTL/expiry. Callers must call
 * efm_cache_valid() first to verify the cache is not stale. This function
 * only checks if data exists, not whether it's still valid.
 *
 * Usage pattern:
 *   if (efm_cache_valid()) {
 *       char *data = efm_get_cached_status();
 *       if (data) { ... }
 *   }
 */
char *
efm_get_cached_status(void)
{
    char *result = NULL;

    if (efm_cache == NULL)
        return NULL;

    LWLockAcquire(&efm_cache->lock, LW_SHARED);

    if (efm_cache->data_len > 0)
    {
        result = palloc(efm_cache->data_len + 1);
        memcpy(result, efm_cache->data, efm_cache->data_len);
        result[efm_cache->data_len] = '\0';

        /* Update hit counter (need exclusive lock) */
        LWLockRelease(&efm_cache->lock);
        LWLockAcquire(&efm_cache->lock, LW_EXCLUSIVE);
        efm_cache->hits++;
        LWLockRelease(&efm_cache->lock);

        return result;
    }

    /* Update miss counter */
    LWLockRelease(&efm_cache->lock);
    LWLockAcquire(&efm_cache->lock, LW_EXCLUSIVE);
    efm_cache->misses++;
    LWLockRelease(&efm_cache->lock);

    return NULL;
}

/*
 * Update cache with new status data
 */
void
efm_update_cache(const char *json_data, Size len)
{
    if (efm_cache == NULL)
        return;

    if (len > EFM_CACHE_SIZE)
    {
        elog(WARNING, "EFM status too large to cache (%zu bytes, max %d)",
             len, EFM_CACHE_SIZE);
        return;
    }

    LWLockAcquire(&efm_cache->lock, LW_EXCLUSIVE);

    memcpy(efm_cache->data, json_data, len);
    efm_cache->data_len = len;
    efm_cache->last_update = GetCurrentTimestamp();
    efm_cache->updates++;

    LWLockRelease(&efm_cache->lock);
}

/*
 * Invalidate the cache (force refresh on next access)
 */
void
efm_cache_invalidate(void)
{
    if (efm_cache == NULL)
        return;

    LWLockAcquire(&efm_cache->lock, LW_EXCLUSIVE);
    efm_cache->data_len = 0;
    efm_cache->last_update = 0;
    LWLockRelease(&efm_cache->lock);
}

/*
 * Get cache statistics
 */
EfmCacheStats
efm_get_cache_stats(void)
{
    EfmCacheStats stats;

    memset(&stats, 0, sizeof(stats));

    if (efm_cache == NULL)
        return stats;

    LWLockAcquire(&efm_cache->lock, LW_SHARED);

    stats.hits = efm_cache->hits;
    stats.misses = efm_cache->misses;
    stats.updates = efm_cache->updates;
    stats.last_update = efm_cache->last_update;
    stats.last_access = GetCurrentTimestamp();

    LWLockRelease(&efm_cache->lock);

    return stats;
}
