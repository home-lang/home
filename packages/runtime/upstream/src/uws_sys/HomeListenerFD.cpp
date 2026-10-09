extern "C" {
#include <bun-usockets/src/internal/internal.h>
#include <bun-usockets/src/libusockets.h>
}
#include <errno.h>
#ifndef _WIN32
#include <fcntl.h>
#include <sys/socket.h>
#endif

// Adopt an existing listening socket into the same poll/group lifecycle as a
// freshly bound listener. Ownership transfers only after validation succeeds.
extern "C" us_listen_socket_t* HomeSocketGroupListenFD(us_socket_group_t* group,
    unsigned char kind, ssl_ctx_st* ssl_ctx, LIBUS_SOCKET_DESCRIPTOR fd,
    int options, int socket_ext_size, int* error)
{
    int type = 0;
#ifdef _WIN32
    int length = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, reinterpret_cast<char*>(&type), &length) != 0) {
        *error = WSAGetLastError();
        return nullptr;
    }
    if (type != SOCK_STREAM) {
        *error = WSAEINVAL;
        return nullptr;
    }
    if (listen(fd, SOMAXCONN) != 0) {
        *error = WSAGetLastError();
        return nullptr;
    }
    u_long nonblocking = 1;
    if (ioctlsocket(fd, FIONBIO, &nonblocking) != 0) {
        *error = WSAGetLastError();
        return nullptr;
    }
#else
    socklen_t length = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) != 0) {
        *error = errno;
        return nullptr;
    }
    if (type != SOCK_STREAM) {
        *error = EINVAL;
        return nullptr;
    }
    // listen() accepts both bound and already-listening stream descriptors.
    // SO_ACCEPTCONN is not a portable getsockopt selector on Darwin.
    if (listen(fd, SOMAXCONN) != 0) {
        *error = errno;
        return nullptr;
    }
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        *error = errno;
        return nullptr;
    }
#endif
    auto* poll = us_create_poll(group->loop, 0, sizeof(us_listen_socket_t));
    us_poll_init(poll, fd, POLL_TYPE_SEMI_SOCKET);
    auto* listener = reinterpret_cast<us_listen_socket_t*>(poll);
    auto* socket = &listener->s;
    socket->group = group;
    socket->kind = 0;
    socket->ssl = nullptr;
    socket->timeout = 255;
    socket->long_timeout = 255;
    socket->flags = {};
    socket->flags.allow_half_open = !!(options & LIBUS_SOCKET_ALLOW_HALF_OPEN);
    socket->next = socket->prev = nullptr;
    socket->connect_state = nullptr;
    socket->connect_next = nullptr;
    listener->accept_group = group;
    listener->accept_kind = kind;
    listener->ssl_ctx = ssl_ctx;
    if (ssl_ctx) us_internal_ssl_ctx_up_ref(ssl_ctx);
    listener->sni = nullptr;
    listener->on_server_name = nullptr;
    listener->socket_ext_size = socket_ext_size;
    listener->deferred_accept = 0;
    listener->next = group->head_listen_sockets;
    group->head_listen_sockets = listener;
    if (!group->linked) {
        us_internal_loop_link_group(group->loop, group);
        group->linked = 1;
    }
    us_poll_start(poll, group->loop, LIBUS_SOCKET_READABLE);
    *error = 0;
    return listener;
}
