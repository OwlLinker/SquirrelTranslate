#!/usr/bin/env python3
"""Translate text through DeepL's current anonymous web session.

The server mode keeps one anonymous session in memory and reconnects when it
expires.  It does not read browser cookies or persist session tokens.
"""

import argparse
import json
import struct
import sys
import time
import urllib.parse
import urllib.request
import uuid


class ProtocolError(Exception):
    pass


class Extension:
    def __init__(self, kind, data):
        self.kind = kind
        self.data = data


def varint(value):
    value = int(value)
    result = bytearray()
    while value > 0x7f:
        result.append((value & 0x7f) | 0x80)
        value >>= 7
    result.append(value & 0x7f)
    return bytes(result)


def protobuf_varint(field_number, value):
    return varint((field_number << 3) | 0) + varint(value)


def protobuf_bytes(field_number, value):
    return varint((field_number << 3) | 2) + varint(len(value)) + value


def parse_protobuf_fields(data):
    fields = {}
    position = 0
    while position < len(data):
        tag, position = read_varint(data, position)
        field_number = tag >> 3
        wire_type = tag & 7
        if wire_type == 0:
            value, position = read_varint(data, position)
        elif wire_type == 2:
            size, position = read_varint(data, position)
            end = position + size
            if end > len(data):
                raise ProtocolError("truncated protobuf field")
            value = data[position:end]
            position = end
        elif wire_type == 1:
            end = position + 8
            if end > len(data):
                raise ProtocolError("truncated fixed64 protobuf field")
            value = data[position:end]
            position = end
        elif wire_type == 5:
            end = position + 4
            if end > len(data):
                raise ProtocolError("truncated fixed32 protobuf field")
            value = data[position:end]
            position = end
        else:
            raise ProtocolError("unsupported protobuf wire type")
        fields.setdefault(field_number, []).append(value)
    return fields


def read_varint(data, position):
    value = 0
    shift = 0
    while position < len(data):
        byte = data[position]
        position += 1
        value |= (byte & 0x7f) << shift
        if byte < 0x80:
            return value, position
        shift += 7
        if shift > 63:
            break
    raise ProtocolError("invalid varint")


def first(fields, number, default=None):
    values = fields.get(number)
    return values[0] if values else default


def target_code(value):
    value = (value or "en").strip()
    upper = value.upper()
    if upper == "ZH" or upper == "ZH-CN":
        return "zh"
    if upper == "EN":
        return "en"
    return value


def source_code(text):
    """Return a source language only when the script can identify it safely."""
    for character in text:
        if (
            "\u3400" <= character <= "\u4dbf"
            or "\u4e00" <= character <= "\u9fff"
            or "\uf900" <= character <= "\ufaff"
        ):
            return "zh"
    return None


def start_request(target):
    # Match the anonymous web translator's initial document.  The source text
    # is appended after Participate, not included in StartSessionRequest.
    maximum_length = protobuf_varint(1, 14)
    maximum_length += protobuf_bytes(14, protobuf_varint(1, 1500))
    target_language = protobuf_bytes(1, b"en-US")
    requested_target = protobuf_varint(1, 5) + protobuf_bytes(
        5, protobuf_bytes(1, target_language)
    )
    calculated_target = protobuf_varint(1, 18) + protobuf_bytes(
        18, protobuf_bytes(1, target_language)
    )
    source_field = protobuf_varint(1, 1) + protobuf_bytes(4, maximum_length)
    target_field = protobuf_varint(1, 2)
    target_field += protobuf_bytes(4, requested_target)
    target_field += protobuf_bytes(4, calculated_target)
    base_document = protobuf_bytes(1, source_field)
    base_document += protobuf_bytes(1, target_field)
    # SessionOptions.enableTranslatorQuoteConversion = 1.
    session_options = protobuf_varint(2, 1)
    request = protobuf_varint(1, 1)
    request += protobuf_bytes(2, base_document)
    request += protobuf_bytes(3, session_options)
    return request


def decode_start_session(data):
    fields = parse_protobuf_fields(data)
    session_id = parse_protobuf_fields(first(fields, 1, b""))
    participant_id = parse_protobuf_fields(first(fields, 2, b""))
    endpoint = first(fields, 5, b"")
    if not session_id or not participant_id or not endpoint:
        raise ProtocolError("incomplete start session response")
    return (
        first(session_id, 1, b"").decode("utf-8"),
        int(first(participant_id, 1, 0)),
        endpoint.decode("utf-8"),
    )


def msgpack_string(value):
    value = value.encode("utf-8")
    size = len(value)
    if size < 32:
        return bytes((0xa0 | size,)) + value
    if size < 256:
        return bytes((0xd9, size)) + value
    if size < 65536:
        return bytes((0xda,)) + struct.pack(">H", size) + value
    return bytes((0xdb,)) + struct.pack(">I", size) + value


def msgpack_array(values):
    size = len(values)
    if size < 16:
        prefix = bytes((0x90 | size,))
    elif size < 65536:
        prefix = bytes((0xdc,)) + struct.pack(">H", size)
    else:
        prefix = bytes((0xdd,)) + struct.pack(">I", size)
    return prefix + b"".join(values)


def msgpack_extension(kind, data):
    size = len(data)
    if size == 1:
        return bytes((0xd4, kind & 0xff)) + data
    if size == 2:
        return bytes((0xd5, kind & 0xff)) + data
    if size == 4:
        return bytes((0xd6, kind & 0xff)) + data
    if size == 8:
        return bytes((0xd7, kind & 0xff)) + data
    if size == 16:
        return bytes((0xd8, kind & 0xff)) + data
    if size < 256:
        return bytes((0xc7, size, kind & 0xff)) + data
    if size < 65536:
        return bytes((0xc8,)) + struct.pack(">H", size) + bytes((kind & 0xff,)) + data
    return bytes((0xc9,)) + struct.pack(">I", size) + bytes((kind & 0xff,)) + data


def signalr_frame(payload):
    return varint(len(payload)) + payload


def protobuf_text_change(field_number, text, participant_id, previous_length=0):
    # Replace the current source text.  The server's validator rejects an
    # empty length-delimited range (0a00), so end is always encoded.
    text_range = protobuf_varint(2, previous_length)
    operation = protobuf_bytes(1, text_range) + protobuf_bytes(2, text.encode("utf-8"))
    event = protobuf_varint(1, field_number)
    event += protobuf_bytes(6, protobuf_varint(1, participant_id))
    event += protobuf_bytes(2, operation)
    return event


def protobuf_target_property(target, participant_id):
    target_language = protobuf_bytes(1, target_code(target).encode("utf-8"))
    requested_target = protobuf_bytes(1, target_language)
    operation = protobuf_varint(1, 5) + protobuf_bytes(5, requested_target)
    event = protobuf_varint(1, 2)
    event += protobuf_bytes(6, protobuf_varint(1, participant_id))
    event += protobuf_bytes(5, operation)
    return event


def protobuf_formality_event(participant_id):
    operation = protobuf_varint(1, 8) + protobuf_bytes(
        8, protobuf_bytes(1, b"")
    )
    event = protobuf_varint(1, 2)
    event += protobuf_bytes(6, protobuf_varint(1, participant_id))
    event += protobuf_bytes(5, operation)
    return event


def protobuf_glossary_event(participant_id):
    operation = protobuf_varint(1, 10) + protobuf_bytes(10, b"")
    event = protobuf_varint(1, 2)
    event += protobuf_bytes(6, protobuf_varint(1, participant_id))
    event += protobuf_bytes(5, operation)
    return event


def protobuf_source_language_event(participant_id, source):
    operation = protobuf_varint(1, 3)
    if source:
        source_language = protobuf_bytes(
            1, protobuf_bytes(1, source.encode("utf-8"))
        )
        operation += protobuf_bytes(
            4, source_language
        )
    event = protobuf_varint(1, 1)
    event += protobuf_bytes(6, protobuf_varint(1, participant_id))
    event += protobuf_bytes(5, operation)
    return event


def append_request(text, target, participant_id, version, previous_length=0):
    events = [
        protobuf_formality_event(participant_id),
        protobuf_glossary_event(participant_id),
        protobuf_target_property(target, participant_id),
        protobuf_source_language_event(participant_id, source_code(text)),
        protobuf_text_change(1, text, participant_id, previous_length),
    ]
    append = b"".join(protobuf_bytes(1, event) for event in events)
    if version is not None:
        event_version = protobuf_bytes(1, protobuf_varint(1, version))
        append += protobuf_bytes(2, event_version)
    return protobuf_bytes(1, append)


def negotiate(endpoint, timeout):
    parsed = urllib.parse.urlparse(endpoint)
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    query["negotiateVersion"] = ["1"]
    path = parsed.path.rstrip("/") + "/negotiate"
    url = urllib.parse.urlunparse(
        ("https", parsed.netloc, path, "", urllib.parse.urlencode(query, doseq=True), "")
    )
    request = urllib.request.Request(
        url,
        data=b"",
        headers={
            "Origin": "https://www.deepl.com",
            "Referer": "https://www.deepl.com/translator",
            "User-Agent": "Mozilla/5.0",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        if response.status != 200:
            raise ProtocolError("DeepL SignalR negotiate failed")
        result = json.loads(response.read().decode("utf-8"))
    token = result.get("connectionToken")
    if not token:
        raise ProtocolError("DeepL SignalR negotiate returned no token")
    query.pop("negotiateVersion", None)
    query["id"] = [token]
    return urllib.parse.urlunparse(
        ("wss", parsed.netloc, parsed.path, "", urllib.parse.urlencode(query, doseq=True), "")
    )


def decode_msgpack(data, position=0):
    if position >= len(data):
        raise ProtocolError("truncated MessagePack value")
    marker = data[position]
    position += 1
    if marker <= 0x7f:
        return marker, position
    if marker >= 0xe0:
        return marker - 256, position
    if 0xa0 <= marker <= 0xbf:
        size = marker & 0x1f
        return data[position:position + size].decode("utf-8", "replace"), position + size
    if 0x90 <= marker <= 0x9f:
        return decode_array(data, position, marker & 0x0f)
    if 0x80 <= marker <= 0x8f:
        return decode_map(data, position, marker & 0x0f)
    if marker == 0xc0:
        return None, position
    if marker == 0xc2 or marker == 0xc3:
        return marker == 0xc3, position
    if marker in (0xcc, 0xcd, 0xce, 0xcf):
        size = (1, 2, 4, 8)[marker - 0xcc]
        return int.from_bytes(data[position:position + size], "big"), position + size
    if marker in (0xd0, 0xd1, 0xd2, 0xd3):
        size = (1, 2, 4, 8)[marker - 0xd0]
        return int.from_bytes(data[position:position + size], "big", signed=True), position + size
    if marker in (0xca, 0xcb):
        size = 4 if marker == 0xca else 8
        return data[position:position + size], position + size
    if marker in (0xd9, 0xda, 0xdb):
        length_size = (1, 2, 4)[marker - 0xd9]
        size = int.from_bytes(data[position:position + length_size], "big")
        position += length_size
        return data[position:position + size].decode("utf-8", "replace"), position + size
    if marker in (0xc4, 0xc5, 0xc6):
        length_size = (1, 2, 4)[marker - 0xc4]
        size = int.from_bytes(data[position:position + length_size], "big")
        position += length_size
        return data[position:position + size], position + size
    if marker in (0xdc, 0xdd):
        length_size = 2 if marker == 0xdc else 4
        size = int.from_bytes(data[position:position + length_size], "big")
        return decode_array(data, position + length_size, size)
    if marker in (0xde, 0xdf):
        length_size = 2 if marker == 0xde else 4
        size = int.from_bytes(data[position:position + length_size], "big")
        return decode_map(data, position + length_size, size)
    if marker in (0xd4, 0xd5, 0xd6, 0xd7, 0xd8):
        size = (1, 2, 4, 8, 16)[marker - 0xd4]
        kind = data[position]
        begin = position + 1
        return Extension(kind, data[begin:begin + size]), begin + size
    if marker in (0xc7, 0xc8, 0xc9):
        length_size = (1, 2, 4)[marker - 0xc7]
        size = int.from_bytes(data[position:position + length_size], "big")
        position += length_size
        kind = data[position]
        begin = position + 1
        return Extension(kind, data[begin:begin + size]), begin + size
    raise ProtocolError("unsupported MessagePack marker")


def decode_array(data, position, size):
    values = []
    for _ in range(size):
        value, position = decode_msgpack(data, position)
        values.append(value)
    return values, position


def decode_map(data, position, size):
    values = {}
    for _ in range(size):
        key, position = decode_msgpack(data, position)
        value, position = decode_msgpack(data, position)
        values[key] = value
    return values, position


def signalr_messages(payload):
    position = 0
    while position < len(payload):
        size, position = read_varint(payload, position)
        end = position + size
        if end > len(payload):
            raise ProtocolError("truncated SignalR message")
        yield payload[position:end]
        position = end


def target_text_from_response(data, current_text):
    fields = parse_protobuf_fields(data)
    published = first(fields, 3)
    if published is None:
        return current_text, None, False
    published_fields = parse_protobuf_fields(published)
    version = None
    version_message = first(published_fields, 2)
    if version_message is not None:
        event_version = first(parse_protobuf_fields(version_message), 1)
        if event_version is not None:
            version = first(parse_protobuf_fields(event_version), 1)
    target_changed = False
    for event in published_fields.get(1, []):
        event_fields = parse_protobuf_fields(event)
        if first(event_fields, 1) != 2:
            continue
        operation = first(event_fields, 2)
        if operation is None:
            continue
        operation_fields = parse_protobuf_fields(operation)
        text_range = parse_protobuf_fields(first(operation_fields, 1, b""))
        start = int(first(text_range, 1, 0))
        end = int(first(text_range, 2, start))
        text = first(operation_fields, 2, b"").decode("utf-8", "replace")
        current_text = current_text[:start] + text + current_text[end:]
        target_changed = True
    return current_text, version, target_changed


def is_initialized_response(data):
    # The first AppendResponse after Participate carries the base document in
    # field 3.  Field 2 is only used by the later confirmation response.
    return first(parse_protobuf_fields(data), 3) is not None


class DeepLSession:
    def __init__(self, endpoint, timeout, initial_target="en"):
        parsed = urllib.parse.urlparse(endpoint)
        if not parsed.scheme or not parsed.netloc:
            raise ProtocolError("invalid DeepL endpoint")
        self.endpoint = endpoint.rstrip("/")
        self.timeout = timeout
        self.websocket = None
        self.participant_id = None
        self.version = None
        self.current_source = ""
        self.current_text = ""
        self.invocation_id = 0
        self._connect(initial_target)

    def close(self):
        websocket = self.websocket
        self.websocket = None
        if websocket is not None:
            try:
                websocket.close()
            except Exception:
                pass

    def _connect(self, initial_target):
        client_id = str(uuid.uuid4())
        url = self.endpoint + "/startSession?client=" + urllib.parse.quote(client_id)
        headers = {
            "Content-Type": "application/x-protobuf",
            "Accept": "application/x-protobuf",
            "Origin": "https://www.deepl.com",
            "Referer": "https://www.deepl.com/translator",
            "User-Agent": "Mozilla/5.0",
        }
        request = urllib.request.Request(
            url, data=start_request(initial_target), headers=headers, method="POST"
        )
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            if response.status != 200:
                raise ProtocolError("DeepL start session failed")
            _, self.participant_id, signalr_endpoint = decode_start_session(response.read())

        signalr_url = urllib.parse.urljoin(self.endpoint + "/", signalr_endpoint)
        websocket_url = negotiate(signalr_url, self.timeout)
        try:
            from websockets.sync.client import connect
        except ImportError as error:
            raise ProtocolError("Python websockets module is required") from error

        self.websocket = connect(
            websocket_url,
            origin="https://www.deepl.com",
            additional_headers={"User-Agent": "Mozilla/5.0"},
            open_timeout=self.timeout,
            close_timeout=1,
            max_size=1024 * 1024,
        )
        deadline = time.monotonic() + self.timeout
        self.websocket.send('{"protocol":"messagepack","version":1}\x1e')
        while time.monotonic() < deadline:
            payload = self.websocket.recv(timeout=max(0.1, deadline - time.monotonic()))
            if isinstance(payload, str) and payload.endswith("\x1e"):
                break
            if isinstance(payload, (bytes, bytearray)) and payload.endswith(b"\x1e"):
                break
        else:
            raise ProtocolError("DeepL handshake timed out")

        self.websocket.send(signalr_frame(msgpack_array([bytes((6,))])))
        participate = msgpack_array([
            bytes((1,)), bytes((0x80,)), msgpack_string("1"),
            msgpack_string("Participate"),
            msgpack_array([msgpack_extension(3, b"")]),
        ])
        self.websocket.send(signalr_frame(participate))
        while time.monotonic() < deadline:
            initialized = False
            for data, _, _ in self._receive(deadline):
                if is_initialized_response(data):
                    initialized = True
            if initialized:
                return
        raise ProtocolError("DeepL session initialization timed out")

    def _receive(self, deadline):
        payload = self.websocket.recv(timeout=max(0.1, deadline - time.monotonic()))
        if isinstance(payload, str):
            return []
        responses = []
        for message in signalr_messages(payload):
            value, _ = decode_msgpack(message)
            if not isinstance(value, list) or not value:
                continue
            if value[0] == 6:
                self.websocket.send(signalr_frame(msgpack_array([bytes((6,))])))
                continue
            if value[0] != 1 or len(value) < 5:
                continue
            arguments = value[4]
            if isinstance(arguments, list):
                for argument in arguments:
                    if isinstance(argument, Extension) and argument.kind == 5:
                        self.current_text, version, published = target_text_from_response(
                            argument.data, self.current_text
                        )
                        if version is not None:
                            self.version = version
                        responses.append((argument.data, version, published))
            receive_id = value[2] if len(value) > 2 else "1"
            self.websocket.send(signalr_frame(msgpack_array([
                bytes((5,)), bytes((0x80,)), msgpack_string(str(receive_id))
            ])))
        return responses

    def translate(self, text, target):
        deadline = time.monotonic() + self.timeout
        previous_version = self.version
        append = append_request(
            text, target, self.participant_id, self.version, len(self.current_source)
        )
        payload = msgpack_array([
            bytes((1,)), bytes((0x80,)), msgpack_string(str(self.invocation_id)),
            msgpack_string("AppendRequest"),
            msgpack_array([msgpack_extension(4, append)]),
        ])
        self.websocket.send(signalr_frame(payload))
        self.invocation_id += 1
        self.current_source = text
        while time.monotonic() < deadline:
            for _, version, published in self._receive(deadline):
                if (published and version is not None and
                        version != previous_version and self.current_text):
                    return self.current_text.strip()
        raise ProtocolError("DeepL translation timed out")


def translate(endpoint, text, target, timeout):
    session = DeepLSession(endpoint, timeout, target)
    try:
        return session.translate(text, target)
    finally:
        session.close()


def clean_output(value):
    return value.replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def serve(endpoint, timeout):
    session = None
    try:
        for line in sys.stdin:
            fields = line.rstrip("\r\n").split("\t", 1)
            if len(fields) != 2 or not fields[0] or not fields[1]:
                sys.stdout.write("ERR\n")
                sys.stdout.flush()
                continue
            target, text = fields
            result = ""
            for _ in range(2):
                try:
                    if session is None:
                        session = DeepLSession(endpoint, timeout, target)
                    result = session.translate(text, target)
                    break
                except Exception:
                    if session is not None:
                        session.close()
                    session = None
            if result:
                sys.stdout.write("OK\t" + clean_output(result) + "\n")
            else:
                sys.stdout.write("ERR\n")
            sys.stdout.flush()
    finally:
        if session is not None:
            session.close()
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default="https://ita-free.www.deepl.com/v2")
    parser.add_argument("--text")
    parser.add_argument("--target")
    parser.add_argument("--server", action="store_true")
    parser.add_argument("--timeout", type=float, default=6.0)
    args = parser.parse_args()
    if args.server:
        return serve(args.endpoint, args.timeout)
    if not args.text or not args.target:
        parser.error("--text and --target are required outside server mode")
    try:
        result = translate(args.endpoint, args.text, args.target, args.timeout)
    except Exception:
        return 1
    if not result:
        return 1
    sys.stdout.write(clean_output(result))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
