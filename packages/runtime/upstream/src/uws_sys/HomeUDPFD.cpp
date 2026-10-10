// internal.h is already included with C linkage by HomeListenerFD.cpp.
extern "C" us_udp_socket_t* HomeUDPSocketAdoptFD(us_loop_t* loop,
    void (*data_cb)(us_udp_socket_t*, void*, int), void (*drain_cb)(us_udp_socket_t*),
    void (*close_cb)(us_udp_socket_t*), void (*error_cb)(us_udp_socket_t*, int),
    LIBUS_SOCKET_DESCRIPTOR fd, int* error, void* user)
{
    int type = 0;
#ifdef _WIN32
    int length = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, reinterpret_cast<char*>(&type), &length) != 0) { *error = WSAGetLastError(); return nullptr; }
    if (type != SOCK_DGRAM) { *error = WSAEINVAL; return nullptr; }
    u_long nonblocking = 1;
    if (ioctlsocket(fd, FIONBIO, &nonblocking) != 0) { *error = WSAGetLastError(); return nullptr; }
#else
    socklen_t length = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) != 0) { *error = errno; return nullptr; }
    if (type != SOCK_DGRAM) { *error = EINVAL; return nullptr; }
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { *error = errno; return nullptr; }
#endif
    sockaddr_storage address {};
#ifdef _WIN32
    int address_length = sizeof(address);
#else
    socklen_t address_length = sizeof(address);
#endif
    if (getsockname(fd, reinterpret_cast<sockaddr*>(&address), &address_length) != 0) { *error = errno; return nullptr; }
    if (address.ss_family != AF_INET && address.ss_family != AF_INET6) { *error = EINVAL; return nullptr; }
    auto* poll = us_create_poll(loop, 0, sizeof(us_udp_socket_t));
    us_poll_init(poll, fd, POLL_TYPE_UDP);
    auto* udp = reinterpret_cast<us_udp_socket_t*>(poll);
    udp->port = ntohs(address.ss_family == AF_INET ? reinterpret_cast<sockaddr_in*>(&address)->sin_port : reinterpret_cast<sockaddr_in6*>(&address)->sin6_port);
    udp->loop = loop;
    udp->user = user;
    udp->closed = 0;
    udp->connected = 0;
    udp->on_data = data_cb;
    udp->on_drain = drain_cb;
    udp->on_close = close_cb;
    udp->on_recv_error = error_cb;
    udp->next = nullptr;
    us_poll_start(poll, loop, LIBUS_SOCKET_READABLE | LIBUS_SOCKET_WRITABLE);
    *error = 0;
    return udp;
}

extern "C" LIBUS_SOCKET_DESCRIPTOR HomeUDPSocketFD(us_udp_socket_t* socket)
{
    return us_poll_fd(reinterpret_cast<us_poll_t*>(socket));
}
