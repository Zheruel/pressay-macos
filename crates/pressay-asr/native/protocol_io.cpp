#include <cstdio>
#include <cstdlib>
#include <cerrno>
#include <climits>
#ifdef _WIN32
#include <io.h>
#include <fcntl.h>
#define DUP _dup
#define DUP2 _dup2
#define WRITE _write
#define CLOSE _close
#else
#include <unistd.h>
#define DUP dup
#define DUP2 dup2
#define WRITE write
#define CLOSE close
#endif

// Preserve a private pipe to the host before any native code can print. Native
// logging (including libraries that write directly to fd 1) goes to stderr.
extern "C" int pressay_protocol_start() {
    std::fflush(stdout);
    int saved = DUP(1);
    if (saved < 0) return -1;
    if (DUP2(2, 1) < 0) { CLOSE(saved); return -1; }
#ifdef _WIN32
    _setmode(saved, _O_BINARY);
    _setmode(0, _O_BINARY);
#endif
    return saved;
}

extern "C" int pressay_protocol_write(int fd, const unsigned char *data, unsigned int size) {
    return static_cast<int>(WRITE(fd, data, size));
}

extern "C" void pressay_protocol_close(int fd) { CLOSE(fd); }

// ggml backend globals outlive a model. Process exit is their lifetime boundary;
// do not run their C++ static destructors (same policy as the Swift worker).
extern "C" void pressay_worker_exit(int code) { std::_Exit(code); }
