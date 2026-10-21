#pragma once
#include <stdint.h>

/* Read a u32/u64 (cell-size agnostic) property of /chosen. Returns 0 if absent. */
int fdt_chosen_u64(uintptr_t fdt, const char *prop, uint64_t *out);

#define FDT_MAX_DEPTH	8

/* Big-endian value of 1 or 2 cells at val. */
uint64_t fdt_cells(uintptr_t val, int ncells);

/*
 * Call cb for every property: depth of its node (root = 1), the names of the
 * parent node and the node ("memory@80000000"), the property name, value
 * and length. Returns 1 if the whole tree was walked.
 */
typedef void (*fdt_prop_cb)(void *ctx, int depth, const char *parent, const char *node,
			    const char *prop, uintptr_t val, uint32_t len);
int fdt_walk(uintptr_t fdt, fdt_prop_cb cb, void *ctx);
