// Modified for Zenith from LiveContainer upstream (khanhduytran0/LiveContainer, commit b0f53e89), 2026-11-27.
// Licensed under the GNU Affero General Public License v3.0 (see LICENSE-AGPL).
// Based on: https://blog.xpnsec.com/restoring-dyld-memory-loading
// https://github.com/xpn/DyldDeNeuralyzer/blob/main/DyldDeNeuralyzer/DyldPatch/dyldpatch.m

#define ASM(...) __asm__(#__VA_ARGS__)

// Signatures to search for
static const char mmapSig[] = {0xB0, 0x18, 0x80, 0xD2, 0x01, 0x10, 0x00, 0xD4};
static const char fcntlSig[] = {0x90, 0x0B, 0x80, 0xD2, 0x01, 0x10, 0x00, 0xD4};
static const char syscallSig[] = {0x01, 0x10, 0x00, 0xD4};
// Zenith: extern here — the plain declarations below were tentative definitions,
// so every TU including this header (dyld_bypass_validation.m AND Tweaks/Dyld.m)
// defined its own copy and the link failed with duplicate symbols under
// -fno-common (the modern default). The single definitions live in
// dyld_bypass_validation.m.
extern int (*orig_dyld_fcntl)(int fildes, int cmd, void *param);
extern int (*orig_dyld_mmap)(int fildes, int cmd, void *param);

extern void* __mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset);
extern int __fcntl(int fildes, int cmd, void* param);

void searchDyldFunctions(void);
char *searchDyldFunction(char *base, char *signature, int length);
