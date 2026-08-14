import socket, ssl, struct, sys

PROXY=("127.0.0.1",9090); HOST="example.com"
NFIELDS=int(sys.argv[1]) if len(sys.argv)>1 else 200
VALLEN=int(sys.argv[2]) if len(sys.argv)>2 else 60

def hpack_literal(name, value):          # 0x00 = literal, never indexed, no huffman
    out=b"\x00"
    out+=bytes([len(name)])+name
    out+=bytes([len(value)])+value
    return out

def frame(t, flags, sid, payload):
    return struct.pack(">I", len(payload))[1:]+bytes([t,flags])+struct.pack(">I", sid)+payload

s=socket.create_connection(PROXY,8)
s.sendall(f"CONNECT {HOST}:443 HTTP/1.1\r\nHost: {HOST}:443\r\n\r\n".encode())
s.recv(200)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
ctx.set_alpn_protocols(["h2"])
t=ctx.wrap_socket(s, server_hostname=HOST)
print("ALPN:", t.selected_alpn_protocol())

hdrs =hpack_literal(b":method", b"GET")
hdrs+=hpack_literal(b":scheme", b"https")
hdrs+=hpack_literal(b":authority", HOST.encode())
hdrs+=hpack_literal(b":path", b"/")
# Each field costs name+value+32 in the DECODED list size (RFC 7541 §4.1).
for i in range(NFIELDS):
    hdrs+=hpack_literal(f"x-pad-{i:04d}".encode(), b"a"*VALLEN)
listsize=sum(len(f"x-pad-{i:04d}")+VALLEN+32 for i in range(NFIELDS))+200
print(f"decoded list size ~{listsize}  (decoder default limit 16384), HEADERS frame {len(hdrs)} bytes")

# Preface + SETTINGS + HEADERS in one write: no wait for the server's SETTINGS ACK,
# which RFC 9113 §3.4 explicitly permits.
t.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + frame(0x4,0,0,b"") + frame(0x1,0x5,1,hdrs))
t.settimeout(6)
buf=b""
try:
    while True:
        d=t.recv(65536)
        if not d: break
        buf+=d
        if len(buf)>40: break
except Exception as e: print("recv:",type(e).__name__)
i=0
names={0x1:"HEADERS",0x4:"SETTINGS",0x7:"GOAWAY",0x3:"RST_STREAM"}
while i+9<=len(buf):
    ln=int.from_bytes(buf[i:i+3],'big'); ty=buf[i+3]; body=buf[i+9:i+9+ln]
    line=f"  <- {names.get(ty,hex(ty))} len={ln}"
    if ty==0x7 and ln>=8:
        line+=f"  errorCode=0x{int.from_bytes(body[4:8],'big'):x}"
    print(line)
    i+=9+ln
t.close()
