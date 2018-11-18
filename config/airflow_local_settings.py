import socket

def hostname_callable():
  return socket.gethostbyname(socket.gethostname())
