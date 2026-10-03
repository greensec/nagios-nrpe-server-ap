/*
 * libFuzzer harness for the NRPE daemon packet-parse path.
 *
 * Feeds fuzz bytes through a real socketpair into the unmodified
 * read_packet() -> recvall() path, then validate_request() and
 * process_macros() - the exact code a remote client reaches.
 *
 * CRC32 fixup: validate_request() rejects packets whose crc32 doesn't
 * match; mutations would almost never pass that gate. For inputs large
 * enough to be a packet we zero the crc/alignment fields, recompute and
 * reinsert the checksum - equivalent to fuzzing the semantic space
 * *after* the integrity gate (which is what validate_request sees).
 *
 * my_system()/handle_connection() are deliberately NOT called - the
 * popen() path would execute fuzzer-derived commands.
 */
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <netinet/in.h>

#include "../include/common.h"

/* globals the parse path expects (defined in nrpe.c/utils.c) */
extern int    use_ssl;
extern int    debug;
extern int    socket_timeout;
extern int    allow_arguments;
extern int    allow_bash_cmd_subst;
extern char  *nasty_metachars;
extern char  *command_name;
extern char  *macro_argv[];
extern char   remote_host[];
extern int    packet_ver;
extern int    commands_running;

extern int read_packet(int, void *, v2_packet *, v3_packet **);
extern int validate_request(v2_packet *, v3_packet *);
extern int process_macros(char *, char *, int);
extern int contains_nasty_metachars(char *);
extern unsigned long calculate_crc32(char *, int);

static int initialized = 0;

/* fix up crc32 for v3/v4 wire image: [v:2][t:2][crc:4][rc:2][al:2][bl:4][pay] */
static void fixup_crc34(uint8_t *d, size_t n)
{
	if (n < 16)
		return;
	uint16_t ver;
	memcpy(&ver, d, 2);
	ver = ntohs(ver);
	if (ver != 3 && ver != 4)
		return;
	uint8_t *img = malloc(n);
	memcpy(img, d, n);
	memset(img + 4, 0, 4);          /* crc32_value */
	memset(img + 10, 0, 2);         /* alignment   */
	uint32_t c = calculate_crc32((char *)img, (int)n);
	c = htonl(c);
	memcpy(d + 4, &c, 4);
	free(img);
}

/* fix up crc32 for v2 wire image: [v:2][t:2][crc:4][rc:2][buf:1024] */
static void fixup_crc2(uint8_t *d, size_t n)
{
	if (n < 1034)
		return;
	uint16_t ver;
	memcpy(&ver, d, 2);
	ver = ntohs(ver);
	if (ver != 2)
		return;
	uint8_t img[1034];
	memcpy(img, d, 1034);
	memset(img + 4, 0, 4);
	uint32_t c = calculate_crc32((char *)img, 1034);
	c = htonl(c);
	memcpy(d + 4, &c, 4);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	if (!initialized) {
		use_ssl = FALSE;
		debug = FALSE;
		socket_timeout = 1;
		allow_arguments = TRUE;
		allow_bash_cmd_subst = FALSE;
		nasty_metachars = strdup("|`&><'\\[]{};\r\n$\"#~");
		strcpy(remote_host, "127.0.0.1");
		initialized = 1;
	}
	if (size == 0 || size > 200000)
		return 0;

	uint8_t *buf = malloc(size);
	memcpy(buf, data, size);
	fixup_crc34(buf, size);
	fixup_crc2(buf, size);

	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
		free(buf);
		return 0;
	}
	/* feed the fuzz bytes, then EOF so recvall can't wait forever */
	write(sv[1], buf, size);
	shutdown(sv[1], SHUT_WR);

	v2_packet  v2pkt;
	v3_packet *v3pkt = NULL;
	int rc = read_packet(sv[0], NULL, &v2pkt, &v3pkt);

	if (rc > 0 && validate_request(&v2pkt, v3pkt) == OK) {
		/* exercise macro expansion with a synthetic command template
		   covering the $ARGn$ space incl. out-of-range indices */
		char tmpl[] = "x $ARG1$ $ARG2$ $ARG3$ $ARG8$ $ARG15$ $ARG16$ $ARG17$ $ARG0$ $ARGx$ $$ $foo$ $ARG";
		char out[4096];
		process_macros(tmpl, out, sizeof(out));
	}

	/* replicate handle_connection's cleanup */
	free(command_name);
	command_name = NULL;
	for (int i = 0; i < MAX_COMMAND_ARGUMENTS; i++) {
		free(macro_argv[i]);
		macro_argv[i] = NULL;
	}
	free(v3pkt);
	close(sv[0]);
	close(sv[1]);
	free(buf);
	return 0;
}
