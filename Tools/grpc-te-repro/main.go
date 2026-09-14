package main

// Does a real gRPC server behave differently when `te: trailers` is absent —
// i.e. is Loom's hop-by-hop stripping of `te` a real breakage for gRPC?
//
// A real grpc-go server, and a raw HTTP/2 framer client so the header set is
// exactly what we choose (net/http would add its own).

import (
	"bytes"
	"fmt"
	"net"
	"net/http"
	"os"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/hpack"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

func startServer() string {
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	s := grpc.NewServer()
	healthpb.RegisterHealthServer(s, health.NewServer())
	go s.Serve(lis)
	return lis.Addr().String()
}

func call(addr string, withTE bool) {
	label := "without te: trailers  (what Loom forwards)"
	if withTE {
		label = "with    te: trailers  (what the client sent)"
	}
	fmt.Printf("%s\n", label)

	conn, err := net.Dial("tcp", addr)
	if err != nil {
		fmt.Printf("    dial: %v\n", err)
		return
	}
	defer conn.Close()
	if _, err := conn.Write([]byte(http2.ClientPreface)); err != nil {
		fmt.Printf("    preface: %v\n", err)
		return
	}
	fr := http2.NewFramer(conn, conn)
	fr.ReadMetaHeaders = hpack.NewDecoder(4096, nil)
	fr.WriteSettings()

	var hbuf bytes.Buffer
	enc := hpack.NewEncoder(&hbuf)
	enc.WriteField(hpack.HeaderField{Name: ":method", Value: "POST"})
	enc.WriteField(hpack.HeaderField{Name: ":scheme", Value: "http"})
	enc.WriteField(hpack.HeaderField{Name: ":path", Value: "/grpc.health.v1.Health/Check"})
	enc.WriteField(hpack.HeaderField{Name: ":authority", Value: addr})
	enc.WriteField(hpack.HeaderField{Name: "content-type", Value: "application/grpc"})
	if withTE {
		enc.WriteField(hpack.HeaderField{Name: "te", Value: "trailers"})
	}
	fr.WriteHeaders(http2.HeadersFrameParam{StreamID: 1, BlockFragment: hbuf.Bytes(), EndHeaders: true})
	// One gRPC message: compressed-flag 0, length 0 (an empty HealthCheckRequest).
	fr.WriteData(1, true, []byte{0, 0, 0, 0, 0})

	status, grpcStatus, dataLen := "", "", 0
	for i := 0; i < 40; i++ {
		f, err := fr.ReadFrame()
		if err != nil {
			fmt.Printf("    read: %v\n", err)
			break
		}
		switch v := f.(type) {
		case *http2.MetaHeadersFrame:
			for _, hf := range v.Fields {
				if hf.Name == ":status" {
					status = hf.Value
				}
				if hf.Name == "grpc-status" {
					grpcStatus = hf.Value
				}
			}
			if v.StreamEnded() {
				goto done
			}
		case *http2.DataFrame:
			dataLen += len(v.Data())
		case *http2.GoAwayFrame:
			fmt.Printf("    GOAWAY code=%v debug=%q\n", v.ErrCode, v.DebugData())
			goto done
		case *http2.RSTStreamFrame:
			fmt.Printf("    RST_STREAM code=%v\n", v.ErrCode)
			goto done
		}
	}
done:
	fmt.Printf("    :status=%s grpc-status=%s responseBytes=%d\n", status, grpcStatus, dataLen)
	if status == "200" && grpcStatus == "0" {
		fmt.Printf("    => the RPC succeeded\n")
	} else {
		fmt.Printf("    => the RPC did NOT succeed\n")
	}
}

func main() {
	_ = http.StatusOK
	addr := ""
	label := ""
	if len(os.Args) > 1 {
		addr, label = os.Args[1], "grpc C-core (grpcio)"
	} else {
		addr, label = startServer(), "grpc-go v1.83.2"
	}
	fmt.Printf("%s server on %s\n\n", label, addr)
	call(addr, true)
	fmt.Println()
	call(addr, false)
	os.Exit(0)
}
