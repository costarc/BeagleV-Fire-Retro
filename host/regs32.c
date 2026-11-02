/* 32 bit accesses to the FIC window of the gateware. The window is a 32 bit APB bus without byte strobes: a byte
 * store replaces the whole word with the byte repeated, which is what Python's struct.pack_into / memcpy do on this
 * board. Everything here is a volatile aligned uint32_t access (lw / sw). */
#include <stddef.h>
#include <stdint.h>

uint32_t rd32(uintptr_t addr) { return *(volatile uint32_t *)addr; }

void wr32(uintptr_t addr, uint32_t v) { *(volatile uint32_t *)addr = v; }

void rdblk(uintptr_t addr, uint32_t *dst, size_t words) {
	volatile uint32_t *p = (volatile uint32_t *)addr;
	for (size_t i = 0; i < words; i++)
		dst[i] = p[i];
}

void wrblk(uintptr_t addr, const uint32_t *src, size_t words) {
	volatile uint32_t *p = (volatile uint32_t *)addr;
	for (size_t i = 0; i < words; i++)
		p[i] = src[i];
}
