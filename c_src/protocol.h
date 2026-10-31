#ifndef NET_RUNNER_PROTOCOL_H
#define NET_RUNNER_PROTOCOL_H

/*
 * Shepherd <-> BEAM protocol over Unix domain socket.
 *
 * Handshake: when spawned with --token-fd, the shepherd reads the
 * TOKEN_HEX_LEN-byte hex token from fd 3 (the BEAM port's :nouse_stdio
 * channel — never argv, which is world/same-uid readable) and writes it
 * verbatim as the very first frame after connect. The BEAM verifies it
 * before accepting any FDs.
 *
 * Direction: BEAM -> Shepherd
 *   CMD_KILL         [0x01] [signal_number: 1 byte]
 *   CMD_CLOSE_STDIN  [0x02] (no payload)
 *   CMD_SET_WINSIZE  [0x03] [rows: 2 bytes] [cols: 2 bytes] (big-endian)
 *
 * Direction: Shepherd -> BEAM
 *   MSG_CHILD_STARTED [0x80] [pid: 4 bytes, big-endian]
 *   MSG_CHILD_EXITED  [0x81] [status: 4 bytes, big-endian]
 *   MSG_ERROR         [0x82] [length: 2 bytes, big-endian] [message: N bytes]
 *
 * Hand-off order: SCM_RIGHTS fds, then MSG_CHILD_STARTED; the child execs
 * only after both were sent. The SCM_RIGHTS message carries
 * [stdin_w, stdout_r, stderr_r] (pipe mode) or [master] (PTY mode),
 * followed on Linux by a pidfd for the child when pidfd_open succeeded.
 * An unknown command opcode makes the shepherd ignore all further command
 * bytes (sticky); BEAM death is still detected.
 *
 * MSG_CHILD_EXITED status is the exit code (0..255), 128 + signal for a
 * signal death, or EXIT_STATUS_UNKNOWN for any other wait status. It is
 * sent after the child's process group was swept and its cgroup removed.
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

/* Handshake token: 16 random bytes, hex-encoded to 32 ASCII chars */
#define TOKEN_HEX_LEN 32

/* Default kill escalation timeout: SIGTERM -> wait -> SIGKILL */
#define DEFAULT_KILL_TIMEOUT_MS 5000

/* MSG_CHILD_EXITED status for a wait status that is neither an exit nor a
 * signal death (never -1 / 0xFFFFFFFF on the wire) */
#define EXIT_STATUS_UNKNOWN 255

#endif /* NET_RUNNER_PROTOCOL_H */
