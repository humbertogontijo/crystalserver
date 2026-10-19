////////////////////////////////////////////////////////////////////////
// IdleOT: optional WebSocket game port for browser OTC (binary frames).
////////////////////////////////////////////////////////////////////////

#pragma once

#include "server/server_definitions.hpp"

#include <memory>

class Connection;
using Connection_ptr = std::shared_ptr<Connection>;
class ServiceBase;
using Service_ptr = std::shared_ptr<ServiceBase>;

class WebSocketServicePort : public std::enable_shared_from_this<WebSocketServicePort> {
public:
	explicit WebSocketServicePort(asio::io_service &initIoService);
	~WebSocketServicePort();

	WebSocketServicePort(const WebSocketServicePort &) = delete;
	WebSocketServicePort &operator=(const WebSocketServicePort &) = delete;

	static void openAcceptor(const std::weak_ptr<WebSocketServicePort> &weakService, uint16_t port);
	void open(uint16_t port);
	void close() const;
	void onStopServer() const;

private:
	using Acceptor = std::shared_ptr<asio::ip::tcp::acceptor>;

	void accept(const Acceptor &which);
	void onAccept(const Acceptor &which, const Connection_ptr &connection, const std::error_code &error);
	void doHandshake(const Connection_ptr &connection);

	asio::io_service &io_service;
	// v4 and v6 are separate sockets. Browsers resolve "localhost" to ::1 first;
	// a v4-only listen is "connection lost" in Safari/Chrome. shared_ptr keeps
	// the socket alive until an in-flight accept callback finishes.
	Acceptor acceptor;
	Acceptor acceptor6;
	Service_ptr gameService;
	uint16_t serverPort = 0;
	bool pendingStart = false;
};
