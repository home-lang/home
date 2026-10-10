// uSockets represents both backpressure and failed writes as zero. IPC must
// preserve the actual transport error for queued send callbacks.
#ifndef _WIN32
extern "C" int HomeIPCSocketWrite(us_socket_t* socket, const char* data, int length, int* error)
{
    errno = 0;
    int written = us_socket_write(socket, data, length);
    int savedError = errno;
    *error = 0;
    if (written == 0 && savedError != 0 && savedError != EAGAIN
        && savedError != EWOULDBLOCK && savedError != EINTR) {
        *error = savedError;
        return -1;
    }
    return written;
}
#endif
