#ifndef NET_RUNNER_PROTOCOL_H
#define NET_RUNNER_PROTOCOL_H

/*
 * Shepherd <-> BEAM protocol over Unix domain socket.
 *
 * Direction: BEAM -> Shepherd
 *   CMD_KILL         [0x01] [signal_number: 1 byte]
 *   CMD_CLOSE_STDIN  [0x02] (no payload)
 *
 * Direction: Shepherd -> BEAM
 *   MSG_CHILD_STARTED [0x80] [pid: 4 bytes, big-endian]
 *   MSG_CHILD_EXITED  [0x81] [status: 4 bytes, big-endian]
 *   MSG_ERROR         [0x82] [length: 2 bytes, big-endian] [message: N bytes]
 */

/* BEAM -> Shepherd commands */
#define CMD_KILL          0x01
#define CMD_CLOSE_STDIN   0x02
#define CMD_SET_WINSIZE   0x03  /* payload: rows(2) + cols(2) big-endian */

/* Shepherd -> BEAM messages */
#define MSG_CHILD_STARTED 0x80
#define MSG_CHILD_EXITED  0x81
#define MSG_ERROR         0x82

/* Shepherd mode flags (passed as CLI arg) */
#define MODE_PIPE 0
#define MODE_PTY  1

/* Max cgroup path length */
#define CGROUP_PATH_MAX 256

/* Default kill escalation timeout: SIGTERM -> wait -> SIGKILL */
#define DEFAULT_KILL_TIMEOUT_MS 5000

#endif /* NET_RUNNER_PROTOCOL_H */
