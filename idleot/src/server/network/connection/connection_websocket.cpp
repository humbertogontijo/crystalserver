////////////////////////////////////////////////////////////////////////
// IdleOT: WebSocket transport for browser OTC (binary frames over TCP).
////////////////////////////////////////////////////////////////////////

#include "server/network/connection/connection.hpp"

#include "game/game.hpp"
#include "server/network/message/outputmessage.hpp"

#include <algorithm>
#include <cstring>

void Connection::enableWebSocket() {
	std::scoped_lock lock(connectionLock);
	useWebSocket = true;
}

void Connection::scheduleRead(size_t nbytes, uint8_t* buffer, std::function<void(const std::error_code &)> handler) {
	if (!useWebSocket) {
		asio::async_read(socket, asio::buffer(buffer, nbytes), [self = shared_from_this(), handler](const std::error_code &error, std::size_t) {
			handler(error);
		});
		return;
	}

	wsPendingRead = PendingRead { buffer, nbytes, 0, std::move(handler) };
	wsPumpRead();
}

void Connection::wsPumpRead() {
	if (!wsPendingRead) {
		return;
	}

	auto &pending = *wsPendingRead;
	while (pending.offset < pending.length) {
		if (wsStream.empty()) {
			wsReadNextFrame();
			return;
		}

		const size_t chunk = std::min(pending.length - pending.offset, wsStream.size());
		std::memcpy(pending.buffer + pending.offset, wsStream.data(), chunk);
		wsStream.erase(wsStream.begin(), wsStream.begin() + static_cast<std::ptrdiff_t>(chunk));
		pending.offset += chunk;
	}

	auto handler = std::move(pending.handler);
	wsPendingRead.reset();
	handler({});
}

void Connection::wsReadNextFrame() {
	if (wsReadingFrame || connectionState == CONNECTION_STATE_CLOSED) {
		return;
	}

	wsReadingFrame = true;
	const auto header = std::make_shared<std::array<uint8_t, 2>>();
	asio::async_read(socket, asio::buffer(*header), [self = shared_from_this(), header](const std::error_code &error, std::size_t) {
		self->wsOnFrameHeader(error, *header);
	});
}

void Connection::wsOnFrameHeader(const std::error_code &error, const std::array<uint8_t, 2> &header) {
	std::scoped_lock lock(connectionLock);
	wsReadingFrame = false;

	if (error || connectionState == CONNECTION_STATE_CLOSED) {
		if (error && error != asio::error::operation_aborted && error != asio::error::eof && error != asio::error::connection_reset) {
			g_logger().debug("[Connection::wsOnFrameHeader] - Read error: {}", error.message());
		}
		close(FORCE_CLOSE);
		return;
	}

	const uint8_t opcode = header[0] & 0x0F;
	const bool masked = (header[1] & 0x80) != 0;
	uint64_t payloadLen = header[1] & 0x7F;

	size_t extraBytes = 0;
	if (payloadLen == 126) {
		extraBytes = 2;
	} else if (payloadLen == 127) {
		extraBytes = 8;
	}
	if (masked) {
		extraBytes += 4;
	}

	if (extraBytes == 0) {
		if (payloadLen > INPUTMESSAGE_MAXSIZE) {
			close(FORCE_CLOSE);
			return;
		}
		const auto payload = std::make_shared<std::vector<uint8_t>>(payloadLen);
		if (payloadLen == 0) {
			wsOnFramePayload({}, payload, {}, opcode);
			return;
		}
		asio::async_read(socket, asio::buffer(*payload), [self = shared_from_this(), payload, opcode](const std::error_code &readError, std::size_t) {
			self->wsOnFramePayload(readError, payload, {}, opcode);
		});
		return;
	}

	const auto extra = std::make_shared<std::vector<uint8_t>>(extraBytes);
	asio::async_read(socket, asio::buffer(*extra), [self = shared_from_this(), extra, opcode, payloadLen, masked](const std::error_code &readError, std::size_t) {
		self->wsOnFrameExtended(readError, *extra, opcode, payloadLen, masked);
	});
}

void Connection::wsOnFrameExtended(const std::error_code &error, const std::vector<uint8_t> &extra, uint8_t opcode, uint64_t payloadLen, bool masked) {
	std::scoped_lock lock(connectionLock);

	if (error || connectionState == CONNECTION_STATE_CLOSED) {
		close(FORCE_CLOSE);
		return;
	}

	size_t offset = 0;
	if (payloadLen == 126) {
		payloadLen = (static_cast<uint64_t>(extra[0]) << 8) | extra[1];
		offset = 2;
	} else if (payloadLen == 127) {
		payloadLen = 0;
		for (int i = 0; i < 8; ++i) {
			payloadLen = (payloadLen << 8) | extra[i];
		}
		offset = 8;
	}

	if (payloadLen > INPUTMESSAGE_MAXSIZE) {
		close(FORCE_CLOSE);
		return;
	}

	std::array<uint8_t, 4> mask {};
	if (masked) {
		std::copy_n(extra.begin() + static_cast<std::ptrdiff_t>(offset), 4, mask.begin());
		offset += 4;
	}

	const auto payload = std::make_shared<std::vector<uint8_t>>(payloadLen);
	if (payloadLen == 0) {
		wsOnFramePayload({}, payload, mask, opcode);
		return;
	}

	asio::async_read(socket, asio::buffer(*payload), [self = shared_from_this(), payload, mask, opcode](const std::error_code &readError, std::size_t) {
		self->wsOnFramePayload(readError, payload, mask, opcode);
	});
}

void Connection::wsOnFramePayload(const std::error_code &error, const std::shared_ptr<std::vector<uint8_t>> &payload, const std::array<uint8_t, 4> &mask, uint8_t opcode) {
	std::scoped_lock lock(connectionLock);

	if (error || connectionState == CONNECTION_STATE_CLOSED) {
		close(FORCE_CLOSE);
		return;
	}

	if (opcode == 0x8) {
		close(FORCE_CLOSE);
		return;
	}

	if (opcode == 0x9) {
		// Ping — reply with pong (unmasked server frame).
		static constexpr uint8_t pong[] = { 0x8A, 0x00 };
		asio::async_write(socket, asio::buffer(pong), [](const std::error_code &, std::size_t) {});
		wsPumpRead();
		return;
	}

	if (opcode != 0x2 && opcode != 0x0) {
		wsPumpRead();
		return;
	}

	if (!payload->empty()) {
		if (mask[0] | mask[1] | mask[2] | mask[3]) {
			for (size_t i = 0; i < payload->size(); ++i) {
				(*payload)[i] ^= mask[i % 4];
			}
		}
		wsStream.insert(wsStream.end(), payload->begin(), payload->end());
	}

	wsPumpRead();
}

void Connection::wsSendBinary(const OutputMessage_ptr &outputMessage) {
	const auto* data = outputMessage->getOutputBuffer();
	const auto len = static_cast<size_t>(outputMessage->getLength());

	auto frame = std::make_shared<std::vector<uint8_t>>();
	frame->reserve(len + 14);
	frame->push_back(0x82);
	if (len < 126) {
		frame->push_back(static_cast<uint8_t>(len));
	} else if (len < 65536) {
		frame->push_back(126);
		frame->push_back(static_cast<uint8_t>((len >> 8) & 0xFF));
		frame->push_back(static_cast<uint8_t>(len & 0xFF));
	} else {
		frame->push_back(127);
		for (int i = 7; i >= 0; --i) {
			frame->push_back(static_cast<uint8_t>((len >> (i * 8)) & 0xFF));
		}
	}
	frame->insert(frame->end(), data, data + len);

	writeTimer.expires_from_now(std::chrono::seconds(CONNECTION_WRITE_TIMEOUT));
	writeTimer.async_wait([self = std::weak_ptr<Connection>(shared_from_this())](const std::error_code &timerError) { Connection::handleTimeout(self, timerError); });

	asio::async_write(socket, asio::buffer(*frame), [self = shared_from_this(), frame](const std::error_code &writeError, std::size_t) {
		self->onWriteOperation(writeError);
	});
}
