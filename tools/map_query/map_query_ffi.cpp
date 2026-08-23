////////////////////////////////////////////////////////////////////////
// C ABI wrapper around map_query::MapQuerySession.
////////////////////////////////////////////////////////////////////////

#include "map_query_ffi.h"

#include "map_query_session.hpp"

#include <nlohmann/json.hpp>

#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>

namespace {

thread_local std::string g_lastError;

void setLastError(const std::string &msg) {
	g_lastError = msg;
}

char *dupString(const std::string &s) {
	char *out = static_cast<char *>(std::malloc(s.size() + 1));
	if (!out) {
		setLastError("out of memory");
		return nullptr;
	}
	std::memcpy(out, s.data(), s.size());
	out[s.size()] = '\0';
	return out;
}

struct MqSessionImpl {
	std::unique_ptr<map_query::MapQuerySession> session;
};

} // namespace

extern "C" {

MqSession *mq_session_create(const char *config_path, const char *otbm_path) {
	g_lastError.clear();
	if (!config_path || !otbm_path) {
		setLastError("config_path and otbm_path are required");
		return nullptr;
	}
	try {
		auto session = map_query::MapQuerySession::create(config_path, otbm_path);
		auto wrapper = new MqSessionImpl();
		wrapper->session = std::move(session);
		return reinterpret_cast<MqSession *>(wrapper);
	} catch (const std::exception &e) {
		setLastError(e.what());
		return nullptr;
	}
}

char *mq_session_ready_json(MqSession *session) {
	g_lastError.clear();
	auto *impl = reinterpret_cast<MqSessionImpl *>(session);
	if (!impl || !impl->session) {
		setLastError("null session");
		return nullptr;
	}
	try {
		return dupString(impl->session->readyJson().dump());
	} catch (const std::exception &e) {
		setLastError(e.what());
		return nullptr;
	}
}

char *mq_session_query(MqSession *session, const char *request_json) {
	g_lastError.clear();
	auto *impl = reinterpret_cast<MqSessionImpl *>(session);
	if (!impl || !impl->session) {
		setLastError("null session");
		return nullptr;
	}
	if (!request_json) {
		setLastError("null request_json");
		return nullptr;
	}
	try {
		const auto req = nlohmann::json::parse(request_json);
		return dupString(impl->session->query(req).dump());
	} catch (const std::exception &e) {
		return dupString(nlohmann::json { { "error", e.what() } }.dump());
	}
}

void mq_session_destroy(MqSession *session) {
	delete reinterpret_cast<MqSessionImpl *>(session);
}

void mq_free_string(char *ptr) {
	std::free(ptr);
}

const char *mq_last_error(void) {
	return g_lastError.c_str();
}

} // extern "C"
