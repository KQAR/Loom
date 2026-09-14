# A real C-core gRPC server (grpcio), health service, h2c on a random port.
import grpc, time, sys
from concurrent import futures
from grpc_health.v1 import health, health_pb2_grpc
try:
    from grpc_health.v1 import health_pb2
except Exception:
    pass
server = grpc.server(futures.ThreadPoolExecutor(max_workers=2))
health_pb2_grpc.add_HealthServicer_to_server(health.HealthServicer(), server)
port = server.add_insecure_port("127.0.0.1:0")
server.start()
print(port, flush=True)
time.sleep(120)
