/*-------------------------------------------------------------------------
 *
 * efm_cache.h
 *      Shared memory cache for EFM status data
 *
 * Copyright (c) 2024, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 */
#ifndef EFM_CACHE_H
#define EFM_CACHE_H

#include "postgres.h"
#include "utils/timestamp.h"

/* Maximum size for cached JSON status data */
#define EFM_CACHE_SIZE (64 * 1024)  /* 64KB */

/* Cache statistics */
typedef struct EfmCacheStats
{
    uint64      hits;
    uint64      misses;
    uint64      updates;
    TimestampTz last_update;
    TimestampTz last_access;
} EfmCacheStats;

/* Function declarations */
extern void efm_shmem_request(void);
extern void efm_shmem_startup(void);
extern Size efm_shmem_size(void);

extern bool efm_cache_valid(void);
extern char *efm_get_cached_status(void);
extern void efm_update_cache(const char *json_data, Size len);
extern void efm_invalidate_cache(void);
extern EfmCacheStats efm_get_cache_stats(void);

/* GUC variable for cache TTL */
extern int efm_cache_ttl;

#endif /* EFM_CACHE_H */
