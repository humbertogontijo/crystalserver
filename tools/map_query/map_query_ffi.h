////////////////////////////////////////////////////////////////////////
// C ABI for in-process map-query (Rust / Bun FFI — no subprocess IPC).
////////////////////////////////////////////////////////////////////////

#pragma once

#include <stddef.h>

#ifdef _WIN32
	#ifdef MAP_QUERY_FFI_EXPORTS
		#define MQ_API __declspec(dllexport)
	#else
		#define MQ_API __declspec(dllimport)
	#endif
#else
	#define MQ_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MqSession MqSession;

/** Load config + OTBM once. Returns null on failure (see mq_last_error). */
MQ_API MqSession *mq_session_create(const char *config_path, const char *otbm_path);

/** JSON response for ready line (ready, loadMs, tiles). Caller frees with mq_free_string. */
MQ_API char *mq_session_ready_json(MqSession *session);

/** Execute one JSON request (same ops as map-query serve). Caller frees with mq_free_string. */
MQ_API char *mq_session_query(MqSession *session, const char *request_json);

MQ_API void mq_session_destroy(MqSession *session);

MQ_API void mq_free_string(char *ptr);

/** Thread-local last error from create/query (empty when none). */
MQ_API const char *mq_last_error(void);

#ifdef __cplusplus
}
#endif
