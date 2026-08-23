////////////////////////////////////////////////////////////////////////
// Crystal Server - an opensource roleplaying game
////////////////////////////////////////////////////////////////////////
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
////////////////////////////////////////////////////////////////////////

#pragma once

#include "declarations.hpp"
// TODO: Remove circular includes (maybe shared_ptr?)
#include "server/network/message/networkmessage.hpp"
#include "server/network/protocol/protocolgame.hpp"

#include <array>
#include <functional>
#include <optional>
#include <vector>

static constexpr int32_t CONNECTION_WRITE_TIMEOUT = 30;
static constexpr int32_t CONNECTION_READ_TIMEOUT = 30;

class Protocol;
using Protocol_ptr = std::shared_ptr<Protocol>;
class ProtocolGame;
using ProtocolGame_ptr = std::shared_ptr<ProtocolGame>;
class OutputMessage;
using OutputMessage_ptr = std::shared_ptr<OutputMessage>;
class Connection;
using Connection_ptr = std::shared_ptr<Connection>;
using ConnectionWeak_ptr = std::weak_ptr<Connection>;
class ServiceBase;
using Service_ptr = std::shared_ptr<ServiceBase>;
class ServicePort;
using ServicePort_ptr = std::shared_ptr<ServicePort>;
using ConstServicePort_ptr = std::shared_ptr<const ServicePort>;
class NetworkMessage;
class WebSocketServicePort;

class ConnectionManager {
public:
	ConnectionManager() = default;

	static ConnectionManager &getInstance();

	Connection_ptr createConnection(asio::io_service &io_service, const ConstServicePort_ptr &servicePort);
	void releaseConnection(const Connection_ptr &connection);
	void closeAll();

private:
	phmap::parallel_flat_hash_set_m<Connection_ptr> connections;
};

class Connection : public std::enable_shared_from_this<Connection> {
public:
	// Constructor
	Connection(asio::io_service &initIoService, ConstServicePort_ptr initservicePort);
	// Constructor end

	// Destructor
	~Connection() = default;

	// Singleton - ensures we don't accidentally copy it
	Connection(const Connection &) = delete;
	Connection &operator=(const Connection &) = delete;

	void close(bool force = false);
	// Used by protocols that require server to send first
	void accept(Protocol_ptr protocolPtr);
	void acceptInternal(bool toggleParseHeader = true);

	void resumeWork();

	void send(const OutputMessage_ptr &outputMessage);

	uint32_t getIP();

	void enableWebSocket();

private:
	void scheduleRead(size_t nbytes, uint8_t* buffer, std::function<void(const std::error_code &)> handler);
	void wsPumpRead();
	void wsReadNextFrame();
	void wsOnFrameHeader(const std::error_code &error, const std::array<uint8_t, 2> &header);
	void wsOnFrameExtended(const std::error_code &error, const std::vector<uint8_t> &extra, uint8_t opcode, uint64_t payloadLen, bool masked);
	void wsOnFramePayload(const std::error_code &error, const std::shared_ptr<std::vector<uint8_t>> &payload, const std::array<uint8_t, 4> &mask, uint8_t opcode);
	void wsSendBinary(const OutputMessage_ptr &outputMessage);

	bool useWebSocket = false;
	asio::streambuf wsHttpBuffer;
	std::vector<uint8_t> wsStream;
	bool wsReadingFrame = false;
	struct PendingRead {
		uint8_t* buffer = nullptr;
		size_t length = 0;
		size_t offset = 0;
		std::function<void(const std::error_code &)> handler;
	};
	std::optional<PendingRead> wsPendingRead;

	void parseProxyIdentification(const std::error_code &error);
	void parseHeader(const std::error_code &error);
	void parsePacket(const std::error_code &error);

	void onWriteOperation(const std::error_code &error);

	static void handleTimeout(ConnectionWeak_ptr connectionWeak, const std::error_code &error);

	void closeSocket();
	void internalWorker();
	void internalSend(const OutputMessage_ptr &outputMessage);

	asio::ip::tcp::socket &getSocket() {
		return socket;
	}

	asio::high_resolution_timer readTimer;
	asio::high_resolution_timer writeTimer;

	std::recursive_mutex connectionLock;

	std::list<OutputMessage_ptr> messageQueue;

	ConstServicePort_ptr service_port;
	Protocol_ptr protocol;

	asio::ip::tcp::socket socket;

	NetworkMessage m_msg;

	std::time_t timeConnected = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
	uint32_t packetsSent = 0;
	uint32_t ip = 1;

	std::underlying_type_t<ConnectionState_t> connectionState = CONNECTION_STATE_OPEN;
	bool receivedFirst = false;

	friend class ServicePort;
	friend class WebSocketServicePort;
	friend class ConnectionManager;
};
