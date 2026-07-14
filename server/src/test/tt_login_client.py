#!/usr/bin/env python3
"""Minimal TeamTalk client: login + send a single text message.

Speaks the TeamTalk wire protocol directly against msg_server:
  - 16-byte big-endian PDU header (see base/ImPduBase.cpp)
  - protobuf-lite encoded bodies (hand-encoded; see pb/*.proto)

Usage: tt_login_client.py <host> <port> <user_name> <password> [to_user_id] [text]
"""
import socket
import struct
import sys
import time

# --- protocol constants (pb/IM.BaseDefine.proto) ---
IM_PDU_VERSION = 1
SID_LOGIN = 0x0001
SID_MSG = 0x0003
CID_LOGIN_REQ_USERLOGIN = 0x0103
CID_LOGIN_RES_USERLOGIN = 0x0104
CID_MSG_DATA = 0x0301
CID_MSG_DATA_ACK = 0x0302
USER_STATUS_ONLINE = 1
CLIENT_TYPE_WINDOWS = 0x01
MSG_TYPE_SINGLE_TEXT = 0x01


# --- minimal protobuf wire encoding ---
def _varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def f_varint(field, value):
    return bytes([(field << 3) | 0]) + _varint(value)


def f_bytes(field, value):
    if isinstance(value, str):
        value = value.encode()
    return bytes([(field << 3) | 2]) + _varint(len(value)) + value


def decode_fields(buf):
    """Return dict field_num -> list of (wire_type, value)."""
    i, out = 0, {}
    while i < len(buf):
        key, i = _read_varint(buf, i)
        fnum, wtype = key >> 3, key & 0x7
        if wtype == 0:
            val, i = _read_varint(buf, i)
        elif wtype == 2:
            ln, i = _read_varint(buf, i)
            val, i = buf[i:i + ln], i + ln
        elif wtype == 5:
            val, i = buf[i:i + 4], i + 4
        elif wtype == 1:
            val, i = buf[i:i + 8], i + 8
        else:
            raise ValueError("unsupported wire type %d" % wtype)
        out.setdefault(fnum, []).append((wtype, val))
    return out


def _read_varint(buf, i):
    shift, result = 0, 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, i
        shift += 7


# --- PDU framing ---
def pack_pdu(service_id, command_id, seq_num, body):
    length = 16 + len(body)
    header = struct.pack('>IHHHHHH', length, IM_PDU_VERSION, 0,
                         service_id, command_id, seq_num, 0)
    return header + body


def recv_pdu(sock):
    header = _recv_n(sock, 16)
    length, version, flag, sid, cid, seq, _ = struct.unpack('>IHHHHHH', header)
    body = _recv_n(sock, length - 16) if length > 16 else b''
    return sid, cid, seq, body


def _recv_n(sock, n):
    data = b''
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("connection closed (got %d/%d bytes)" % (len(data), n))
        data += chunk
    return data


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else '127.0.0.1'
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8000
    user = sys.argv[3] if len(sys.argv) > 3 else 'alice'
    pwd = sys.argv[4] if len(sys.argv) > 4 else '123456'
    to_id = int(sys.argv[5]) if len(sys.argv) > 5 else 2
    text = sys.argv[6] if len(sys.argv) > 6 else 'hello from cursor cloud agent'

    sock = socket.create_connection((host, port), timeout=10)
    print("[*] connected to msg_server %s:%d" % (host, port))

    # ---- login ----
    body = (f_bytes(1, user) + f_bytes(2, pwd) +
            f_varint(3, USER_STATUS_ONLINE) + f_varint(4, CLIENT_TYPE_WINDOWS) +
            f_bytes(5, "py-test-1.0"))
    sock.sendall(pack_pdu(SID_LOGIN, CID_LOGIN_REQ_USERLOGIN, 1, body))
    print("[*] sent IMLoginReq user_name=%r" % user)

    sid, cid, seq, body = recv_pdu(sock)
    if cid != CID_LOGIN_RES_USERLOGIN:
        print("[!] unexpected response cid=0x%04x" % cid)
        sys.exit(2)
    fields = decode_fields(body)
    server_time = fields.get(1, [(0, 0)])[0][1]
    result_code = fields.get(2, [(0, 99)])[0][1]
    result_string = fields.get(3, [(2, b'')])[0][1].decode(errors='replace')
    print("[*] IMLoginRes: result_code=%d result_string=%r server_time=%d"
          % (result_code, result_string, server_time))
    if result_code != 0:
        print("[!] LOGIN FAILED")
        sys.exit(1)

    my_id = None
    if 5 in fields:  # user_info embedded message
        ui = decode_fields(fields[5][0][1])
        my_id = ui.get(1, [(0, 0)])[0][1]
        nick = ui.get(3, [(2, b'')])[0][1].decode(errors='replace')
        real = ui.get(7, [(2, b'')])[0][1].decode(errors='replace')
        print("[*] LOGIN OK -> user_id=%d nick=%r real_name=%r" % (my_id, nick, real))
    else:
        print("[*] LOGIN OK (no user_info in response)")

    if my_id is None:
        my_id = 1

    # ---- send a text message ----
    msg_body = (f_varint(1, my_id) + f_varint(2, to_id) + f_varint(3, 0) +
                f_varint(4, int(time.time())) + f_varint(5, MSG_TYPE_SINGLE_TEXT) +
                f_bytes(6, text))
    sock.sendall(pack_pdu(SID_MSG, CID_MSG_DATA, 2, msg_body))
    print("[*] sent IMMsgData from=%d to=%d text=%r" % (my_id, to_id, text))

    # msg_server replies with CID_MSG_DATA_ACK once persisted via db_proxy
    sock.settimeout(8)
    try:
        while True:
            sid, cid, seq, body = recv_pdu(sock)
            if cid == CID_MSG_DATA_ACK:
                af = decode_fields(body)
                msg_id = af.get(3, [(0, 0)])[0][1]
                print("[*] IMMsgDataAck: from_user=%d to=%d msg_id=%d (message persisted)"
                      % (af.get(1, [(0, 0)])[0][1], af.get(2, [(0, 0)])[0][1], msg_id))
                print("[+] SUCCESS: end-to-end login + message send completed")
                break
            else:
                print("[*] received cid=0x%04x (len=%d)" % (cid, len(body)))
    except socket.timeout:
        print("[!] no IMMsgDataAck received within timeout")
        sys.exit(3)
    sock.close()


if __name__ == '__main__':
    main()
