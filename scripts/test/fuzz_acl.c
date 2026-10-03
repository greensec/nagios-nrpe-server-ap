/*
 * fuzz_acl.c - libFuzzer harness for the NRPE allowed_hosts ACL parser
 *
 * Feeds fuzz bytes through parse_allowed_hosts() (the exact parser that
 * handles the `allowed_hosts` config option) and then probes
 * is_an_allowed_host() with peer addresses derived from the same input.
 *
 * acl.c keeps its list heads in file-scope statics (declared in acl.h),
 * so the implementation is included directly into this TU - that gives
 * the harness a way to reset ACL state between runs and keeps LSan
 * meaningful: any leak here is a real per-SIGHUP leak in the daemon.
 */

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <syslog.h>
#include <netdb.h>

/* ---- stubs for externs from nrpe.c / utils.c ------------------------ */
int debug = 0;

void logit(int priority, const char *format, ...)
{
	(void)priority;
	(void)format;
}

/* keep the domain-ACL matcher deterministic and offline: resolution
 * always fails, so is_an_allowed_host() exercises the IP lists and the
 * DNS-ACL traversal without doing real DNS lookups */
int getaddrinfo(const char *node, const char *service,
		const struct addrinfo *hints, struct addrinfo **res)
{
	(void)node; (void)service; (void)hints; (void)res;
	return EAI_NONAME;
}

/* ---- pull in the implementation under test -------------------------- */
#include "acl.c"

static void acl_reset(void)
{
	struct ip_acl *ip4;
	struct dns_acl *dns;

	while (ip_acl_head != NULL) {
		ip4 = ip_acl_head->next;
		free(ip_acl_head);
		ip_acl_head = ip4;
	}
	while (dns_acl_head != NULL) {
		dns = dns_acl_head->next;
		free(dns_acl_head);
		dns_acl_head = dns;
	}
	ip_acl_prev = NULL;
	dns_acl_prev = NULL;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	char *acl_str;
	size_t acl_len, addr_len;
	struct in_addr peer4;
	struct in6_addr peer6;

	if (size < 2)
		return 0;

	/* first byte picks how much of the input is the ACL string vs the
	 * peer address(es) used for matching */
	acl_len = 1 + (data[0] % (size - 1));
	addr_len = size - acl_len;

	/* parser expects a writable, NUL-terminated string */
	if ((acl_str = malloc(acl_len + 1)) == NULL)
		return 0;
	memcpy(acl_str, data + 1, acl_len - 1);
	acl_str[acl_len - 1] = '\0';
	acl_str[acl_len] = '\0';

	parse_allowed_hosts(acl_str);
	free(acl_str);

	/* probe the matcher with addresses built from the input tail */
	if (addr_len >= 4) {
		memcpy(&peer4, data + size - 4, 4);
		is_an_allowed_host(AF_INET, &peer4);
	}
	if (addr_len >= 16) {
		memcpy(&peer6, data + size - 16, 16);
		is_an_allowed_host(AF_INET6, &peer6);
	}

	acl_reset();
	return 0;
}
