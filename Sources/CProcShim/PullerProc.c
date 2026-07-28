#include "PullerProc.h"

#include <errno.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/socket.h>

static int puller_errno(void) {
    return errno == 0 ? -EIO : -errno;
}

int puller_list_pids(pid_t *buffer, int capacity) {
    if (capacity < 0 || (capacity > 0 && buffer == NULL)) {
        return -EINVAL;
    }

    int bytes = proc_listpids(
        PROC_ALL_PIDS,
        0,
        buffer,
        capacity * (int)sizeof(pid_t)
    );
    if (bytes < 0) {
        return puller_errno();
    }
    return bytes / (int)sizeof(pid_t);
}

int puller_process_path(pid_t pid, char *buffer, int capacity) {
    if (buffer == NULL || capacity <= 1) {
        return -EINVAL;
    }

    int bytes = proc_pidpath(pid, buffer, (uint32_t)capacity);
    if (bytes <= 0) {
        return puller_errno();
    }
    buffer[capacity - 1] = '\0';
    return bytes;
}

int puller_process_start(pid_t pid, uint64_t *seconds, uint64_t *microseconds) {
    if (seconds == NULL || microseconds == NULL) {
        return -EINVAL;
    }

    struct proc_bsdinfo info;
    int bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (bytes != sizeof(info)) {
        return bytes < 0 ? puller_errno() : -ESRCH;
    }

    *seconds = info.pbi_start_tvsec;
    *microseconds = info.pbi_start_tvusec;
    return 0;
}

static const struct in_sockinfo *puller_inet_info(
    const struct socket_info *socket,
    int *tcp_state
) {
    if (socket->soi_kind == SOCKINFO_TCP) {
        *tcp_state = socket->soi_proto.pri_tcp.tcpsi_state;
        return &socket->soi_proto.pri_tcp.tcpsi_ini;
    }
    if (socket->soi_kind == SOCKINFO_IN) {
        *tcp_state = 0;
        return &socket->soi_proto.pri_in;
    }
    return NULL;
}

static void puller_copy_address(
    uint8_t destination[16],
    const struct in_sockinfo *source,
    int family,
    int local
) {
    if (family == AF_INET) {
        const struct in_addr *address = local
            ? &source->insi_laddr.ina_46.i46a_addr4
            : &source->insi_faddr.ina_46.i46a_addr4;
        memcpy(destination, address, sizeof(*address));
    } else {
        const struct in6_addr *address = local
            ? &source->insi_laddr.ina_6
            : &source->insi_faddr.ina_6;
        memcpy(destination, address, sizeof(*address));
    }
}

int puller_list_sockets(pid_t pid, puller_socket_record *buffer, int capacity) {
    if (capacity < 0 || (capacity > 0 && buffer == NULL)) {
        return -EINVAL;
    }

    int required_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (required_bytes < 0) {
        return puller_errno();
    }
    if (required_bytes == 0) {
        return 0;
    }

    size_t allocation_size = (size_t)required_bytes + 32 * sizeof(struct proc_fdinfo);
    struct proc_fdinfo *descriptors = malloc(allocation_size);
    if (descriptors == NULL) {
        return -ENOMEM;
    }

    int descriptor_bytes = proc_pidinfo(
        pid,
        PROC_PIDLISTFDS,
        0,
        descriptors,
        (int)allocation_size
    );
    if (descriptor_bytes < 0) {
        free(descriptors);
        return puller_errno();
    }

    int descriptor_count = descriptor_bytes / (int)sizeof(struct proc_fdinfo);
    int record_count = 0;
    for (int index = 0; index < descriptor_count; index++) {
        if (descriptors[index].proc_fdtype != PROX_FDTYPE_SOCKET) {
            continue;
        }

        struct socket_fdinfo socket_fd;
        int socket_bytes = proc_pidfdinfo(
            pid,
            descriptors[index].proc_fd,
            PROC_PIDFDSOCKETINFO,
            &socket_fd,
            sizeof(socket_fd)
        );
        if (socket_bytes != sizeof(socket_fd)) {
            continue;
        }

        const struct socket_info *socket = &socket_fd.psi;
        if (socket->soi_family != AF_INET && socket->soi_family != AF_INET6) {
            continue;
        }

        int tcp_state = 0;
        const struct in_sockinfo *inet = puller_inet_info(socket, &tcp_state);
        if (inet == NULL || inet->insi_fport == 0) {
            continue;
        }

        if (record_count < capacity) {
            puller_socket_record *record = &buffer[record_count];
            memset(record, 0, sizeof(*record));
            record->family = socket->soi_family;
            record->socket_type = socket->soi_type;
            record->protocol_number = socket->soi_protocol;
            record->local_port = ntohs((uint16_t)inet->insi_lport);
            record->remote_port = ntohs((uint16_t)inet->insi_fport);
            record->tcp_state = tcp_state;
            puller_copy_address(record->local_address, inet, socket->soi_family, 1);
            puller_copy_address(record->remote_address, inet, socket->soi_family, 0);
        }
        record_count++;
    }

    free(descriptors);
    return record_count;
}
