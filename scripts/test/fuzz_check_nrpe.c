/*
 * fuzz_check_nrpe.c - libFuzzer harness for the check_nrpe client's
 * response-parsing path (hostile-daemon direction).
 *
 * Feeds fuzz bytes through a real socketpair into the unmodified
 * read_packet() -> read_response() path - the exact code that runs on
 * the monitoring server consuming data from a (potentially hostile)
 * monitored host.
 *
 * CRC32 fixup: read_response() rejects packets with a wrong crc32, so
 * mutations would almost never reach the semantic stage. For inputs
 * shaped like a v4 response packet we patch buffer_length to the real
 * payload size, zero crc/alignment, recompute and reinsert the checksum
 * - equivalent to fuzzing the space *after* the integrity gate.
 *
 * check_nrpe.c is compiled with -Dmain=check_nrpe_main so its globals
 * (sd, packet_ver, use_ssl, ...) are reachable from the harness.
 */

#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <netinet/in.h>

#include "../include/common.h"

/* globals living in check_nrpe.c */
extern int    sd;
extern int    use_ssl;
extern int    socket_timeout;

/* nrpe.c owns this in the daemon build; the client links utils.c which
   also references it */
int           debug = 0;
extern int    packet_ver;
extern int    payload_size;
extern int    force_v2_packet;
extern int    force_v3_packet;

extern int    read_response(void);
extern void   generate_crc32_table(void);
extern unsigned long calculate_crc32(char *, int);

static int initialized = 0;

/* v4 wire image: [ver:2][type:2][crc:4][rc:2][align:2][buflen:4][pay]
 * Normalize version/type/length and recompute crc so every mutation
 * reaches the semantic stage of read_response() - the integrity gate
 * itself is not the interesting fuzz space here. */
static void fixup_v4(uint8_t *d, size_t n)
{
	uint32_t blen, crc;
	uint16_t v;

	if (n < 16 || n > 70000)
		return;
	v = htons(NRPE_PACKET_VERSION_4); memcpy(d, &v, 2);
	v = htons(RESPONSE_PACKET);       memcpy(d + 2, &v, 2);
	blen = htonl((uint32_t)(n - 16)); memcpy(d + 12, &blen, 4);
	memset(d + 4, 0, 4);   /* crc32_value */
	memset(d + 10, 0, 2);  /* alignment   */
	crc = calculate_crc32((char *)d, n);
	crc = htonl(crc);
	memcpy(d + 4, &crc, 4);
}

static void fixup_v2(uint8_t *d)
{
	uint32_t crc;
	uint16_t v;

	v = htons(NRPE_PACKET_VERSION_2); memcpy(d, &v, 2);
	v = htons(RESPONSE_PACKET);       memcpy(d + 2, &v, 2);
	memset(d + 4, 0, 4);
	crc = calculate_crc32((char *)d, 1034);
	crc = htonl(crc);
	memcpy(d + 4, &crc, 4);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	uint8_t *buf;
	int sv[2], devnull;

	if (!initialized) {
		use_ssl = FALSE;
		debug = FALSE;
		socket_timeout = 1;
		packet_ver = NRPE_PACKET_VERSION_4;
		payload_size = 0;
		force_v2_packet = 0;
		force_v3_packet = 0;
		generate_crc32_table();
		devnull = open("/dev/null", O_WRONLY);
		dup2(devnull, STDOUT_FILENO);
		initialized = 1;
	}
	if (size == 0 || size > 80000)
		return 0;

	buf = malloc(size);
	memcpy(buf, data, size);

	/* byte0 & 0x80 -> v2 wire (needs >=1034), & 0x40 -> raw/no fixup
	 * (gate fuzzing), otherwise normalize to a valid v4 response */
	if ((data[0] & 0x80) && size >= 1034) {
		packet_ver = NRPE_PACKET_VERSION_2;
		if (!(data[0] & 0x40))
			fixup_v2(buf);
	} else {
		packet_ver = NRPE_PACKET_VERSION_4;
		if (!(data[0] & 0x40))
			fixup_v4(buf, size);
	}

	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
		free(buf);
		return 0;
	}
	/* feed the fuzz bytes, then EOF so recvall returns promptly */
	write(sv[1], buf, size);
	shutdown(sv[1], SHUT_WR);

	/* the client reads its response from the global sd */
	sd = sv[0];

	read_response();

	close(sv[1]);
	free(buf);
	return 0;
}
