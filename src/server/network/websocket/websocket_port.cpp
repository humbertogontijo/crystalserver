////////////////////////////////////////////////////////////////////////
// IdleOT: optional WebSocket game port for browser OTC (binary frames).
////////////////////////////////////////////////////////////////////////

#include "server/network/websocket/websocket_port.hpp"

#include "config/configmanager.hpp"
#include "creatures/players/management/ban.hpp"
#include "game/scheduling/dispatcher.hpp"
#include "lib/di/container.hpp"
#include "server/network/connection/connection.hpp"
#include "server/network/protocol/protocolgame.hpp"
#include "server/server.hpp"
#include "utils/tools.hpp"

#include <openssl/sha.h>

#include <array>
#include <sstream>

namespace {
	std::string base64Encode(const uint8_t* data, size_t len) {
		static constexpr char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
		std::string out;
		out.reserve(((len + 2) / 3) * 4);
		for (size_t i = 0; i < len; i += 3) {
			const uint32_t n = (static_cast<uint32_t>(data[i]) << 16)
				| ((i + 1 < len ? static_cast<uint32_t>(data[i + 1]) : 0u) << 8)
				| (i + 2 < len ? static_cast<uint32_t>(data[i + 2]) : 0u);
			out.push_back(tbl[(n >> 18) & 63]);
			out.push_back(tbl[(n >> 12) & 63]);
			out.push_back(i + 1 < len ? tbl[(n >> 6) & 63] : '=');
			out.push_back(i + 2 < len ? tbl[n & 63] : '=');
		}
		return out;
	}

	std::string extractHeaderField(const std::string &headers, std::string_view name) {
		const std::string needle = std::string(name) + ":";
		const auto pos = headers.find(needle);
		if (pos == std::string::npos) {
			return {};
		}
		auto start = pos + needle.size();
		while (start < headers.size() && (headers[start] == ' ' || headers[start] == '\t')) {
			++start;
		}
		auto end = headers.find("\r\n", start);
		if (end == std::string::npos) {
			end = headers.size();
		}
		return headers.substr(start, end - start);
	}

	std::string computeWebSocketAccept(const std::string &key) {
		static constexpr char GUID[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
		const std::string input = key + GUID;
		std::array<unsigned char, SHA_DIGEST_LENGTH> digest {};
		SHA1(reinterpret_cast<const unsigned char*>(input.data()), input.size(), digest.data());
		return base64Encode(digest.data(), digest.size());
	}
}

WebSocketServicePort::WebSocketServicePort(asio::io_service &initIoService) :
	io_service(initIoService),
	gameService(std::make_shared<Service<ProtocolGame>>()) {
}

WebSocketServicePort::~WebSocketServicePort() {
	close();
}

void WebSocketServicePort::openAcceptor(const std::weak_ptr<WebSocketServicePort> &weakService, uint16_t port) {
	if (const auto service = weakService.lock()) {
		service->open(port);
	}
}

void WebSocketServicePort::open(uint16_t port) {
	close();

	serverPort = port;
	pendingStart = false;

	try {
		const std::string ipString = g_configManager().getString(IP);
		asio::ip::tcp::endpoint endpoint;
		if (g_configManager().getBoolean(BIND_ONLY_GLOBAL_ADDRESS)) {
			asio::ip::address ipAddress = asio::ip::address_v4::from_string(ipString);
			endpoint = asio::ip::tcp::endpoint(ipAddress, port);
		} else {
			endpoint = asio::ip::tcp::endpoint(asio::ip::address_v4::any(), port);
		}

		acceptor = std::make_shared<asio::ip::tcp::acceptor>(io_service, endpoint);
		acceptor->set_option(asio::ip::tcp::no_delay(true));
		acceptor->set_option(asio::socket_base::reuse_address(true));

		g_logger().info("[WebSocketServicePort] - Listening on {}:{}", ipString, port);
		accept(acceptor);
	} catch (const std::exception &e) {
		g_logger().error("[WebSocketServicePort::open] - Failed to bind port {}: {}", port, e.what());
	}

	// v6_only so this does not collide with the v4 socket already bound above.
	try {
		acceptor6 = std::make_shared<asio::ip::tcp::acceptor>(io_service);
		acceptor6->open(asio::ip::tcp::v6());
		acceptor6->set_option(asio::ip::v6_only(true));
		acceptor6->set_option(asio::ip::tcp::no_delay(true));
		acceptor6->set_option(asio::socket_base::reuse_address(true));
		acceptor6->bind(asio::ip::tcp::endpoint(asio::ip::address_v6::any(), port));
		acceptor6->listen();
		g_logger().info("[WebSocketServicePort] - Listening on [::]:{}", port);
		accept(acceptor6);
	} catch (const std::exception &e) {
		acceptor6.reset();
		g_logger().warn("[WebSocketServicePort::open] - IPv6 port {} not bound: {}", port, e.what());
	}
}

void WebSocketServicePort::close() const {
	for (const auto &which : { acceptor.get(), acceptor6.get() }) {
		if (!which || !which->is_open()) {
			continue;
		}
		std::error_code error;
		which->close(error);
		if (error) {
			g_logger().error("[WebSocketServicePort::close] - {}", error.message());
		}
	}
}

void WebSocketServicePort::onStopServer() const {
	close();
}

void WebSocketServicePort::accept(const Acceptor &which) {
	if (!which || !which->is_open()) {
		return;
	}

	// Dummy ServicePort — Connection needs make_protocol; WS always uses ProtocolGame.
	auto servicePort = std::make_shared<ServicePort>(io_service);
	servicePort->add_service(gameService);

	const auto connection = ConnectionManager::getInstance().createConnection(io_service, servicePort);
	which->async_accept(connection->getSocket(), [self = shared_from_this(), which, connection](const std::error_code &error) {
		self->onAccept(which, connection, error);
	});
}

void WebSocketServicePort::onAccept(const Acceptor &which, const Connection_ptr &connection, const std::error_code &error) {
	if (!error) {
		const auto remoteIp = connection->getIP();
		if (remoteIp != 0 && inject<Ban>().acceptConnection(remoteIp)) {
			doHandshake(connection);
		} else {
			connection->close(FORCE_CLOSE);
		}
		accept(which);
	} else if (error != asio::error::operation_aborted) {
		if (!pendingStart) {
			close();
			pendingStart = true;
			g_dispatcher().scheduleEvent(
				15000,
				[self = shared_from_this(), serverPort = serverPort] {
					WebSocketServicePort::openAcceptor(std::weak_ptr<WebSocketServicePort>(self), serverPort);
				},
				"WebSocketServicePort::openAcceptor"
			);
		}
	}
}

void WebSocketServicePort::doHandshake(const Connection_ptr &connection) {
	auto &buffer = connection->wsHttpBuffer;
	asio::async_read_until(
		connection->getSocket(),
		buffer,
		"\r\n\r\n",
		[connection, self = shared_from_this()](const std::error_code &error, std::size_t) {
			if (error) {
				connection->close(FORCE_CLOSE);
				return;
			}

			std::istream stream(&connection->wsHttpBuffer);
			std::string requestLine;
			std::getline(stream, requestLine);
			if (!requestLine.starts_with("GET ")) {
				g_logger().warn("[WebSocketServicePort] - Rejected non-GET upgrade");
				connection->close(FORCE_CLOSE);
				return;
			}

			std::string headers;
			std::string line;
			while (std::getline(stream, line) && line != "\r") {
				if (!line.empty() && line.back() == '\r') {
					line.pop_back();
				}
				headers.append(line).append("\r\n");
			}

			const auto key = extractHeaderField(headers, "Sec-WebSocket-Key");
			if (key.empty()) {
				g_logger().warn("[WebSocketServicePort] - Missing Sec-WebSocket-Key");
				connection->close(FORCE_CLOSE);
				return;
			}

			const auto accept = computeWebSocketAccept(key);
			std::ostringstream response;
			response << "HTTP/1.1 101 Switching Protocols\r\n"
			            "Upgrade: websocket\r\n"
			            "Connection: Upgrade\r\n"
			            "Sec-WebSocket-Accept: "
			         << accept << "\r\n\r\n";

			const auto payload = std::make_shared<std::string>(response.str());
			asio::async_write(
				connection->getSocket(),
				asio::buffer(*payload),
				[connection, self, payload](const std::error_code &writeError, std::size_t) {
					if (writeError) {
						connection->close(FORCE_CLOSE);
						return;
					}
					connection->enableWebSocket();
					connection->accept(self->gameService->make_protocol(connection));
				}
			);
		}
	);
}
