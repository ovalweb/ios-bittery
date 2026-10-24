/*
 * gpu: drive the Adreno 640 from a shell on the phone (root).
 *
 *   gpu up [-p]                 bring-up (power, GMU, HFI, GX, SQE, CP, zap) + CP_MEM_WRITE test;
 *                               -p also paints the test band on the panel. Once per boot.
 *   gpu status                  clocks, power, GMU, SMMU faults, CP pointers, bos
 *   gpu dump [FILE]             devcoredump-style text for Mesa's crashdec (default stdout)
 *   gpu test [memwrite|paint|blit|fb|fbrestore]
 *   gpu alloc NAME SIZE         named buffer in GPU memory; prints "va pa size"
 *   gpu bos                     list buffers
 *   gpu replay FILE.rd [-t MS]  replay a Mesa capture (uncompressed .rd): every buffer at its iova
 *                               (own allocations), then each command stream; prints where the
 *                               buffers are (read them with pmem dump / flame-files read /dev/pmem)
 *   gpu clear                   clear an SMMU fault (the GPU drops writes until then)
 *   gpu read NAME [OFF LEN]     raw bytes to stdout
 *   gpu write NAME FILE [OFF]   file into a buffer
 *   gpu submit FILE [-t MS] [-r RD]
 *                               FILE = raw little-endian dwords, run as an IB (copied to bo "ib");
 *                               writes RD (default /var/local/gpu/last.rd, for cffdump) first,
 *                               and on a hang /var/local/gpu/hang-N.txt (crashdec), then clears
 *                               an SMMU fault so the next submit works
 *
 * Every step is also written to /dev/console (lines "GPU: ..."), so the live
 * log and the RAM log rescue keep them even if the SoC hangs.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "gpu.h"
#include "pmem.h"

static int need_attach(void)
{
	int a = gpu_attach();
	if (a) {
		fprintf(stderr, "gpu: not up (%d); run gpu up\n", a);
		exit(1);
	}
	return 0;
}

static uint8_t *slurp(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	if (!f) {
		perror(path);
		exit(1);
	}
	fseek(f, 0, SEEK_END);
	*len = (size_t)ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *b = malloc(*len + 4);
	if (fread(b, 1, *len, f) != *len) {
		perror(path);
		exit(1);
	}
	fclose(f);
	return b;
}

static void hang_dump(void)
{
	char path[128];
	snprintf(path, sizeof(path), GPU_DIR "/hang-%u.txt", st.submits);
	FILE *f = fopen(path, "w");
	if (f) {
		gpu_dump(f, "hang");
		fclose(f);
		fprintf(stderr, "gpu: state dumped to %s\n", path);
	}
	gpu_clear_fault();
}

/* cmd-db (Linux cmd-db.c layout): each resource's RPMh address and its ARC levels */
static void cmddb(int n, char **ids)
{
	uint64_t db = a6_rd(0x0c3f000cull);
	if (a6_rd(db + 4) != 0x0c0330db) {
		printf("cmd-db: bad magic at %llx\n", (unsigned long long)db);
		return;
	}
	uint64_t data = db + 4 + 4 + 8 * 16 + 4 + 4;
	for (int k = 0; k < n; k++) {
		int found = 0;
		for (uint32_t r = 0; r < 8 && !found; r++) {
			uint64_t rh = db + 8 + 16 * r;
			uint32_t w0 = a6_rd(rh), w1 = a6_rd(rh + 4);
			uint32_t hoff = w0 >> 16, doff = w1 & 0xffff, cnt = w1 >> 16;
			for (uint32_t e = 0; e < cnt && !found; e++) {
				uint64_t ent = data + hoff + 24 * e;
				char name[9];
				for (uint32_t i = 0; i < 8; i++)
					name[i] = (char)(a6_rd(ent + (i & ~3u)) >> (8 * (i & 3)));
				name[8] = 0;
				if (strcmp(ids[k], "all") ? strncmp(name, ids[k], 8) != 0 : (a6_rd(ent + 16) >> 16) != 3)
					continue;	/* "all": every ARC resource (slave 3) */
				found = strcmp(ids[k], "all") != 0;
				uint32_t addr = a6_rd(ent + 16), w5 = a6_rd(ent + 20), len = w5 & 0xffff;
				uint64_t aux = data + doff + (w5 >> 16);
				printf("%-8s addr %#x, %u aux bytes:", name, addr, len);
				for (uint32_t i = 0; i < len / 2 && i < 16; i++)
					printf(" %u", (a6_rd(aux + 2 * (i & ~1u)) >> (16 * (i & 1))) & 0xffff);
				printf("\n");
			}
		}
		if (!found)
			printf("%s: not in cmd-db\n", ids[k]);
	}
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: gpu up [-p] | status | dump [FILE] | test [memwrite|paint|blit|fb|fbrestore] |\n"
				"           alloc NAME SIZE | bos | clear | read NAME [OFF LEN] | write NAME FILE [OFF] |\n"
				"           submit FILE [-t MS] [-r RD] | replay FILE.rd [-t MS]\n");
		return 2;
	}
#if defined(SOC_SDM845)
	a6_soc_select(630);		/* the Pixel 3's Adreno 630 (sweet_a6xx.h) */
#endif
	const char *c = argv[1];
	if (!strcmp(c, "cmddb")) {
		pm_init();
		cmddb(argc - 2, argv + 2);
		return 0;
	}
	pm_init();
	if (!strcmp(c, "up"))
		return gpu_up(argc > 2 && !strcmp(argv[2], "-p")) ? 1 : 0;
	if (!strcmp(c, "status")) {
		gpu_status();
		return 0;
	}
	if (!strcmp(c, "dump")) {
		FILE *f = argc > 2 ? fopen(argv[2], "w") : stdout;
		if (!f) {
			perror(argv[2]);
			return 1;
		}
		gpu_dump(f, "gpu dump");
		return 0;
	}
	need_attach();
	if (!strcmp(c, "test"))
		return gpu_test(argc > 2 ? argv[2] : "memwrite") ? 1 : 0;
	if (!strcmp(c, "alloc") && argc >= 4) {
		struct gpu_bo *b = bo_new(argv[2], strtoull(argv[3], NULL, 0));
		if (!b)
			return 1;
		printf("0x%llx 0x%llx %llu\n", (unsigned long long)bo_va(b), (unsigned long long)bo_pa(b),
		       (unsigned long long)b->size);
		return 0;
	}
	if (!strcmp(c, "replay") && argc >= 3) {
		unsigned t = argc > 4 && !strcmp(argv[3], "-t") ? (unsigned)strtoul(argv[4], NULL, 0) : 2000;
		int rc = gpu_replay(argv[2], t);
		if (rc)
			hang_dump();
		return rc ? 1 : 0;
	}
	if (!strcmp(c, "vatest"))
		return gpu_vatest(argc - 2, argv + 2);
	if (!strcmp(c, "clear")) {
		printf(gpu_clear_fault() ? "fault cleared\n" : "no fault\n");
		return 0;
	}
	if (!strcmp(c, "bos")) {
		for (uint32_t i = 0; i < st.nbo; i++)
			printf("%-16s 0x%llx 0x%llx %llu\n", st.bo[i].name, (unsigned long long)bo_va(&st.bo[i]),
			       (unsigned long long)bo_pa(&st.bo[i]), (unsigned long long)st.bo[i].size);
		return 0;
	}
	if (!strcmp(c, "read") && argc >= 3) {
		struct gpu_bo *b = bo_get(argv[2]);
		if (!b) {
			fprintf(stderr, "no bo %s\n", argv[2]);
			return 1;
		}
		uint64_t off = argc > 3 ? strtoull(argv[3], NULL, 0) : 0;
		uint64_t len = argc > 4 ? strtoull(argv[4], NULL, 0) : b->size - off;
		if (off + len > b->size)
			return 1;
		uint8_t *buf = malloc(len);
		if (pm_rd(bo_pa(b) + off, buf, len))
			return 1;
		fwrite(buf, 1, len, stdout);
		return 0;
	}
	if (!strcmp(c, "write") && argc >= 4) {
		struct gpu_bo *b = bo_get(argv[2]);
		size_t len;
		uint8_t *data = slurp(argv[3], &len);
		uint64_t off = argc > 4 ? strtoull(argv[4], NULL, 0) : 0;
		if (!b || off + len > b->size) {
			fprintf(stderr, "no bo %s or too small\n", argv[2]);
			return 1;
		}
		return pm_wr(bo_pa(b) + off, data, len) ? 1 : 0;
	}
	if (!strcmp(c, "submit") && argc >= 3) {
		unsigned t = 1000;
		const char *rd = GPU_DIR "/last.rd";
		for (int i = 3; i + 1 < argc; i += 2) {
			if (!strcmp(argv[i], "-t"))
				t = (unsigned)strtoul(argv[i + 1], NULL, 0);
			else if (!strcmp(argv[i], "-r"))
				rd = argv[i + 1];
		}
		size_t len;
		uint32_t *dw = (uint32_t *)slurp(argv[2], &len);
		int rc = gpu_submit_dwords(dw, (uint32_t)(len / 4), t, rd);
		printf("submit %u (%zu dwords): %s\n", st.submits, len / 4, rc ? "HANG/FAULT" : "ok");
		if (rc)
			hang_dump();
		return rc ? 1 : 0;
	}
	fprintf(stderr, "gpu: bad command %s\n", c);
	return 2;
}
