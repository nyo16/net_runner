#ifndef NET_RUNNER_UTILS_H
#define NET_RUNNER_UTILS_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

/* Debug logging - enabled via NET_RUNNER_DEBUG env var at runtime */
#ifdef NET_RUNNER_DEBUG_BUILD
#define DEBUG_LOG(fmt, ...)                                                    \
  do {                                                                         \
    fprintf(stderr, "[net_runner:%s:%d] " fmt "\n", __func__, __LINE__,        \
            ##__VA_ARGS__);                                                    \
  } while (0)
#else
#define DEBUG_LOG(fmt, ...) ((void)0)
#endif

/* Error logging - always enabled */
#define ERROR_LOG(fmt, ...)                                                    \
  do {                                                                         \
    fprintf(stderr, "[net_runner:ERROR:%s:%d] " fmt "\n", __func__, __LINE__,  \
            ##__VA_ARGS__);                                                    \
  } while (0)

/* NIF argc assertion */
#define ASSERT_ARGC(env, argc, expected)                                       \
  do {                                                                         \
    if ((argc) != (expected)) {                                                \
      return enif_make_badarg(env);                                            \
    }                                                                          \
  } while (0)

#endif /* NET_RUNNER_UTILS_H */
