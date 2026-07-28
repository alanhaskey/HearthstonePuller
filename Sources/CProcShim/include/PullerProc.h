#ifndef PULLER_PROC_H
#define PULLER_PROC_H

#include <netinet/in.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct {
    int32_t family;
    int32_t socket_type;
    int32_t protocol_number;
    uint8_t local_address[16];
    uint8_t remote_address[16];
    uint16_t local_port;
    uint16_t remote_port;
    int32_t tcp_state;
} puller_socket_record;

int puller_list_pids(pid_t *buffer, int capacity);
int puller_process_path(pid_t pid, char *buffer, int capacity);
int puller_process_start(pid_t pid, uint64_t *seconds, uint64_t *microseconds);
int puller_list_sockets(pid_t pid, puller_socket_record *buffer, int capacity);

#endif
