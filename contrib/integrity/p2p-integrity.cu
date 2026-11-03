// SPDX-License-Identifier: MIT
// p2p-integrity: byte-exact GPU-to-GPU test of peer writes, peer reads and direct SM access to peer memory, plus
// copy bandwidth, for one pair of GPUs, both directions.
//
// Usage: p2p-integrity --list
//        p2p-integrity --selftest [--max-mib N]
//        p2p-integrity --pair BUS_A BUS_B [--max-mib N] [--repeat R] [--timeout S] [--op-timeout S]
// BUS_A, BUS_B: PCI addresses as lspci -D prints them (0000:01:00.0). --max-mib 4..65536 (default 4096): the largest
// buffer. --repeat 1..100 (default 1). --timeout: the whole run, in seconds (default 0: none); --op-timeout: each
// copy, kernel or compare (default 300). A run that hits either prints "TIMEOUT ..." and "RESULT FAIL ... timeout" and
// exits with status 4 at once, without waiting for the GPUs (a hung peer transfer cannot block it).
//
// --list: CUDA devices, PCI addresses and cudaDeviceCanAccessPeer for every ordered pair. Allocates nothing.
// --selftest: host only, needs no GPU and no driver: the host side of the patterns and the plan for --max-mib.
//
// --pair: the pair must have peer access both ways (cudaDeviceCanAccessPeer and the P2P access attribute 1, then
// cudaDeviceEnablePeerAccess); without it the driver would stage copies through host memory, which proves nothing,
// so the result is NO_P2P and nothing is copied. Each GPU first checks its own pattern kernels against the host. Then
// for each allocator (cudaMalloc; cuMemCreate + cuMemMap with cuMemSetAccess for both GPUs), each size from 4 KiB to
// --max-mib (2 MiB window edges, 2 MiB + 64 KiB, 3 MiB, 64 MiB, 256 MiB, 1, 2, 4 GiB ...), each of two ranges per size
// (the whole buffer, and [lo, hi) with lo and hi not 2 MiB aligned so that guard bands remain below lo and above hi)
// and each pattern (random, zeros, ones, 0x55/0xAA alternating, address, walking one), and in each direction X->Y
// (A->B, then B->A), with buffers freshly allocated per size, four transfers:
//   push   cudaMemcpyPeerAsync on X's stream (X's copy engine writes into Y's memory);
//   pull   cudaMemcpyPeerAsync on Y's stream (Y's copy engine reads X's memory);
//   store  a kernel on X writes the pattern straight into Y's buffer through the peer pointer;
//   load   a kernel on X reads Y's buffer through the peer pointer and compares it.
// For push, pull and store, Y's buffer is first filled with the complement of the pattern (every bit differs); after
// the transfer every 64-bit word of it is compared on Y: inside [lo, hi) the pattern, the guard bands outside still the
// complement; and the first and last 4 KiB and 4 KiB around lo and hi are compared on the host, independent of the
// kernels. A 2 MiB canary buffer on each GPU, outside the tested buffers, is checked after every size (stray writes).
// Then the copy bandwidth: 256 MiB (or less) x 20 per direction and both directions at once, on four buffers whose
// contents are compared afterwards.
//
// Output: one line per case and a last line "RESULT PASS|FAIL|NO_P2P BUS_A BUS_B ...", for PASS and FAIL with
// "max-mib N cases C transfers T copied X GiB". FAIL when anything mismatches, any CUDA call fails, no case ran, or a
// size up to 1 GiB had to be skipped for lack of free memory. Exit status: 0 PASS, 1 FAIL, 3 NO_P2P (nothing copied),
// 4 timeout, 2 usage error or no usable GPU.
//
// Pattern and compare rules adapted from an earlier private test; new here: GPU-side fill and compare (several GiB
// without host buffers), complement fill and guard bands, pull and SM load/store, more patterns, bandwidth, timeouts.
// Build: contrib/integrity/build.sh (nvcc). libcuda.so.1 is opened at run time, so --selftest runs without a driver.
#include <cuda.h>
#include <cuda_runtime.h>
#include <dlfcn.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define VERSION "2"
#define MIB (1ull << 20)
#define SPOT_WORDS 512 // host spot check windows: 4 KiB
#define CANARY_WORDS (2 * MIB / 8)

enum { P_RANDOM, P_ZEROS, P_ONES, P_ALT, P_ADDR, P_WALK, NPAT };
static const char *const PAT_NAME[NPAT] = {"random", "zeros", "ones", "alt55aa", "address", "walk1"};
enum { OP_PUSH, OP_PULL, OP_STORE, OP_LOAD, NOP };
static const char *const OP_NAME[NOP] = {"push", "pull", "store", "load"};

__host__ __device__ static inline uint64_t splitmix(uint64_t seed, uint64_t i)
{
	uint64_t z = seed + (i + 1) * 0x9E3779B97F4A7C15ull;
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
	return z ^ (z >> 31);
}

// Word i of pattern p; seed changes per case and direction.
__host__ __device__ static inline uint64_t pat(int p, uint64_t seed, uint64_t i)
{
	switch (p) {
	case P_RANDOM: return splitmix(seed, i);
	case P_ZEROS: return 0;
	case P_ONES: return ~0ull;
	case P_ALT: return (i & 1) ? 0xAAAAAAAAAAAAAAAAull : 0x5555555555555555ull;
	case P_ADDR: return (i * 8) ^ (seed & 0xFFFF000000000000ull);
	default: return 1ull << ((i + seed) & 63);
	}
}

// What word w of a buffer must hold: the pattern inside [lo, hi), its complement outside (the guard bands).
__host__ __device__ static inline uint64_t want_at(int p, uint64_t seed, uint64_t w, uint64_t lo, uint64_t hi)
{
	uint64_t v = pat(p, seed, w);
	return (w >= lo && w < hi) ? v : ~v;
}

// p[i] for i in [0, n) is word base + i of the buffer: pattern inside [lo, hi), complement outside.
__global__ void k_fill(uint64_t *p, size_t n, size_t base, size_t lo, size_t hi, int pt, uint64_t seed)
{
	for (size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x; i < n; i += (size_t)gridDim.x * blockDim.x)
		p[i] = want_at(pt, seed, base + i, lo, hi);
}

// Counts the words of p[0, n) that differ from want_at; *first = lowest bad index.
__global__ void k_verify(const uint64_t *p, size_t n, size_t lo, size_t hi, int pt, uint64_t seed,
			 unsigned long long *bad, unsigned long long *first)
{
	for (size_t i = blockIdx.x * (size_t)blockDim.x + threadIdx.x; i < n; i += (size_t)gridDim.x * blockDim.x) {
		if (p[i] != want_at(pt, seed, i, lo, hi)) {
			atomicAdd(bad, 1ull);
			atomicMin(first, (unsigned long long)i);
		}
	}
}

// --- driver API entry points for cuMem (opened at run time; the runtime itself also opens libcuda.so.1) --------------
static decltype(&::cuDeviceGet) p_cuDeviceGet;
static decltype(&::cuMemGetAllocationGranularity) p_cuMemGetAllocationGranularity;
static decltype(&::cuMemCreate) p_cuMemCreate;
static decltype(&::cuMemRelease) p_cuMemRelease;
static decltype(&::cuMemAddressReserve) p_cuMemAddressReserve;
static decltype(&::cuMemAddressFree) p_cuMemAddressFree;
static decltype(&::cuMemMap) p_cuMemMap;
static decltype(&::cuMemUnmap) p_cuMemUnmap;
static decltype(&::cuMemSetAccess) p_cuMemSetAccess;

static int load_driver(void)
{
	void *lib = dlopen("libcuda.so.1", RTLD_NOW | RTLD_LOCAL);
	if (!lib) {
		printf("error: cannot open libcuda.so.1 (%s)\n", dlerror());
		return -1;
	}
#define SYM(v, name)                                                    \
	do {                                                            \
		*(void **)&v = dlsym(lib, name);                        \
		if (!v) {                                               \
			printf("error: libcuda.so.1 has no %s\n", name); \
			return -1;                                      \
		}                                                       \
	} while (0)
	SYM(p_cuDeviceGet, "cuDeviceGet");
	SYM(p_cuMemGetAllocationGranularity, "cuMemGetAllocationGranularity");
	SYM(p_cuMemCreate, "cuMemCreate");
	SYM(p_cuMemRelease, "cuMemRelease");
	SYM(p_cuMemAddressReserve, "cuMemAddressReserve");
	SYM(p_cuMemAddressFree, "cuMemAddressFree");
	SYM(p_cuMemMap, "cuMemMap");
	SYM(p_cuMemUnmap, "cuMemUnmap");
	SYM(p_cuMemSetAccess, "cuMemSetAccess");
#undef SYM
	return 0;
}

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static const char *size_str(unsigned long long b, char *s, size_t n)
{
	if (b >= (1ull << 30) && b % (1ull << 30) == 0)
		snprintf(s, n, "%llu GiB", b >> 30);
	else if (b >= MIB && b % (64 * 1024) == 0)
		snprintf(s, n, b % MIB ? "%.4g MiB" : "%.0f MiB", (double)b / MIB);
	else
		snprintf(s, n, "%llu KiB", b >> 10);
	return s;
}

struct dev {
	const char *bus;
	int ord;
	CUdevice cu;
	cudaStream_t s;
	unsigned long long *cnt;  // device: [0] mismatches, [1] first bad word
	unsigned long long *hcnt; // pinned host copy of cnt
	uint64_t *hspot;          // pinned host buffer for the spot check
	uint64_t *canary;         // CANARY_WORDS on this GPU, pattern P_RANDOM with CANARY_SEED
	size_t gran;
};
#define CANARY_SEED 0xCA9A7ull

struct buf {
	uint64_t *p;
	size_t size; // mapped size (cumem: rounded up to the granularity)
	int vmm;
	CUmemGenericAllocationHandle h;
	int have_h, have_va, mapped;
};

static int failed; // any mismatch or CUDA error
static unsigned long op_timeout = 300;
static char timeout_tail[256] = "RESULT FAIL timeout\n";

// A CUDA runtime error: printed, counted as a failure. Returns 1 when it is not cudaSuccess.
static int cerr(cudaError_t e, const char *what)
{
	if (e == cudaSuccess)
		return 0;
	printf("  CUDA error in %s: %s (%s)\n", what, cudaGetErrorName(e), cudaGetErrorString(e));
	failed = 1;
	return 1;
}

static int derr(CUresult r, const char *what)
{
	if (r == CUDA_SUCCESS)
		return 0;
	printf("  CUDA driver error %d in %s\n", (int)r, what);
	failed = 1;
	return 1;
}

// A hang: say so and leave at once; waiting for the GPUs (cudaFree, context teardown) could block forever.
static void timeout_exit(const char *what, double secs)
{
	printf("\n  TIMEOUT: %s did not finish within %.0f s (hung peer transfer?)\n%s", what, secs, timeout_tail);
	fflush(stdout);
	_exit(4);
}

static void on_alarm(int sig)
{
	static const char m[] = "\n  TIMEOUT: --timeout reached (hung peer transfer?)\n";
	(void)sig;
	if (write(1, m, sizeof m - 1) < 0 || write(1, timeout_tail, strlen(timeout_tail)) < 0)
		_exit(4);
	_exit(4);
}

// Waits for d's stream, at most op_timeout seconds. Returns 1 on a CUDA error.
static int swait(struct dev *d, const char *what)
{
	double t0 = now();
	for (;;) {
		cudaError_t e = cudaStreamQuery(d->s);
		if (e == cudaSuccess)
			return 0;
		if (e != cudaErrorNotReady)
			return cerr(e, what);
		if (now() - t0 > (double)op_timeout)
			timeout_exit(what, (double)op_timeout);
		struct timespec ts = {0, 100000};
		nanosleep(&ts, NULL);
	}
}

static int use(struct dev *d) { return cerr(cudaSetDevice(d->ord), "cudaSetDevice"); }

static void buf_free(struct dev *own, struct buf *b)
{
	use(own);
	if (!b->vmm) {
		if (b->p)
			cerr(cudaFree(b->p), "cudaFree");
	} else {
		if (b->mapped)
			derr(p_cuMemUnmap((CUdeviceptr)b->p, b->size), "cuMemUnmap");
		if (b->have_h)
			derr(p_cuMemRelease(b->h), "cuMemRelease");
		if (b->have_va)
			derr(p_cuMemAddressFree((CUdeviceptr)b->p, b->size), "cuMemAddressFree");
	}
	memset(b, 0, sizeof *b);
}

// bytes on own; cumem: read/write access for own and peer (peer access to cuMem memory comes from cuMemSetAccess).
static int buf_alloc(struct dev *own, struct dev *peer, size_t bytes, int vmm, struct buf *b)
{
	memset(b, 0, sizeof *b);
	b->vmm = vmm;
	if (use(own))
		return -1;
	if (!vmm) {
		b->size = bytes;
		if (cerr(cudaMalloc((void **)&b->p, bytes), "cudaMalloc")) {
			b->p = NULL;
			return -1;
		}
		return 0;
	}
	b->size = (bytes + own->gran - 1) / own->gran * own->gran;
	CUmemAllocationProp prop;
	memset(&prop, 0, sizeof prop);
	prop.type = CU_MEM_ALLOCATION_TYPE_PINNED;
	prop.location.type = CU_MEM_LOCATION_TYPE_DEVICE;
	prop.location.id = own->cu;
	CUmemAccessDesc acc[2];
	memset(acc, 0, sizeof acc);
	acc[0].location.type = acc[1].location.type = CU_MEM_LOCATION_TYPE_DEVICE;
	acc[0].location.id = own->cu;
	acc[1].location.id = peer->cu;
	acc[0].flags = acc[1].flags = CU_MEM_ACCESS_FLAGS_PROT_READWRITE;
	CUdeviceptr va = 0;
	int bad = derr(p_cuMemCreate(&b->h, b->size, &prop, 0), "cuMemCreate");
	b->have_h = !bad;
	if (!bad) {
		bad = derr(p_cuMemAddressReserve(&va, b->size, 0, 0, 0), "cuMemAddressReserve");
		b->have_va = !bad;
		b->p = (uint64_t *)va;
	}
	if (!bad) {
		bad = derr(p_cuMemMap(va, b->size, 0, b->h, 0), "cuMemMap");
		b->mapped = !bad;
	}
	if (!bad)
		bad = derr(p_cuMemSetAccess(va, b->size, acc, 2), "cuMemSetAccess (owner and peer)");
	if (bad) {
		buf_free(own, b);
		return -1;
	}
	return 0;
}

// Launches k_fill on d's stream (d current). Returns 1 on a launch error.
static int fill(struct dev *d, uint64_t *p, size_t n, size_t base, size_t lo, size_t hi, int pt, uint64_t seed)
{
	if (use(d))
		return 1;
	k_fill<<<1024, 256, 0, d->s>>>(p, n, base, lo, hi, pt, seed);
	return cerr(cudaGetLastError(), "fill kernel launch");
}

// Runs k_verify on d over p[0, n) (p may be a peer's memory). Returns the mismatches, ~0 on a CUDA error.
static unsigned long long verify(struct dev *d, const uint64_t *p, size_t n, size_t lo, size_t hi, int pt,
				 uint64_t seed, unsigned long long *first)
{
	d->hcnt[0] = 0;
	d->hcnt[1] = ~0ull;
	if (use(d) || cerr(cudaMemcpyAsync(d->cnt, d->hcnt, 16, cudaMemcpyHostToDevice, d->s), "reset counters"))
		return ~0ull;
	k_verify<<<1024, 256, 0, d->s>>>(p, n, lo, hi, pt, seed, d->cnt, d->cnt + 1);
	if (cerr(cudaGetLastError(), "compare kernel launch") ||
	    cerr(cudaMemcpyAsync(d->hcnt, d->cnt, 16, cudaMemcpyDeviceToHost, d->s), "read counters") ||
	    swait(d, "compare"))
		return ~0ull;
	*first = d->hcnt[1];
	return d->hcnt[0];
}

// Host check of SPOT_WORDS words at the start, the end, and around lo and hi, independent of the kernels. Returns the
// mismatches, ~0 on a CUDA error.
static unsigned long long spot(struct dev *d, const uint64_t *p, size_t n, size_t lo, size_t hi, int pt,
			       uint64_t seed)
{
	unsigned long long bad = 0;
	size_t m = n < SPOT_WORDS ? n : SPOT_WORDS;
	size_t at[4] = {0, n - m, lo, hi};
	for (int k = 0; k < 4; k++) {
		size_t st = at[k] > SPOT_WORDS / 2 ? at[k] - SPOT_WORDS / 2 : 0;
		if (st > n - m)
			st = n - m;
		if (use(d) || cerr(cudaMemcpyAsync(d->hspot, p + st, m * 8, cudaMemcpyDeviceToHost, d->s), "spot read") ||
		    swait(d, "host spot check read"))
			return ~0ull;
		for (size_t i = 0; i < m; i++)
			bad += d->hspot[i] != want_at(pt, seed, st + i, lo, hi);
	}
	return bad;
}

// The pattern kernels against the host, on one GPU: every pattern over 1 MiB + 8 bytes with guard bands, then one
// flipped word.
static int kernel_selfcheck(struct dev *d)
{
	const size_t n = MIB / 8 + 1, lo = 3, hi = n - 5;
	uint64_t *dp = NULL, *h = NULL;
	int ok = !use(d) && !cerr(cudaMallocHost((void **)&h, n * 8), "cudaMallocHost") &&
		 !cerr(cudaMalloc((void **)&dp, n * 8), "cudaMalloc");
	unsigned long long first = 0, bad;
	for (int pt = 0; ok && pt < NPAT; pt++) {
		uint64_t seed = splitmix(0x5E1F, pt);
		if (fill(d, dp, n, 0, lo, hi, pt, seed) ||
		    cerr(cudaMemcpyAsync(h, dp, n * 8, cudaMemcpyDeviceToHost, d->s), "self-check read") ||
		    swait(d, "self-check")) {
			ok = 0;
			break;
		}
		for (size_t i = 0; i < n; i++)
			if (h[i] != want_at(pt, seed, i, lo, hi)) {
				printf("  self-check FAILED: GPU %s pattern %s word %zu is %016" PRIx64 ", host %016" PRIx64 "\n",
				       d->bus, PAT_NAME[pt], i, h[i], want_at(pt, seed, i, lo, hi));
				ok = 0;
				break;
			}
		if (ok && (bad = verify(d, dp, n, lo, hi, pt, seed, &first)) != 0) {
			printf("  self-check FAILED: GPU %s compare kernel reports %llu bad words on a clean %s buffer\n", d->bus,
			       bad, PAT_NAME[pt]);
			ok = 0;
		}
	}
	if (ok) {
		size_t w[2] = {n / 3, lo - 1}; // inside the range, and in the lower guard band
		for (int k = 0; ok && k < 2; k++) {
			h[0] = ~want_at(P_RANDOM, 7, w[k], lo, hi);
			if (fill(d, dp, n, 0, lo, hi, P_RANDOM, 7) ||
			    cerr(cudaMemcpyAsync(dp + w[k], h, 8, cudaMemcpyHostToDevice, d->s), "self-check flip") ||
			    (bad = verify(d, dp, n, lo, hi, P_RANDOM, 7, &first)) != 1 || first != w[k]) {
				printf("  self-check FAILED: GPU %s compare kernel missed a flipped word\n", d->bus);
				ok = 0;
			}
		}
	}
	if (dp)
		cerr(cudaFree(dp), "cudaFree");
	if (h)
		cerr(cudaFreeHost(h), "cudaFreeHost");
	printf("self-check of the pattern kernels on %s: %s\n", d->bus, ok ? "ok" : "FAILED");
	return ok ? 0 : -1;
}

// One transfer of one case, data from X to Y: Y's buffer yb ends up holding the pattern in [lo, hi) and the
// complement outside. xb is X's buffer (source of push and pull). Prints " <op> ok <ms>" or what is wrong.
static void one_op(int op, struct dev *X, struct buf *xb, struct dev *Y, struct buf *yb, size_t n, size_t lo, size_t hi,
		   int pt, uint64_t seed)
{
	unsigned long long first = 0, bad, sbad = 0;
	char what[64];
	double t0;
	snprintf(what, sizeof what, "%s %s->%s", OP_NAME[op], X->bus, Y->bus);
	if (op == OP_LOAD) {
		// Y holds the expected contents; X reads them through the peer pointer
		if (fill(Y, yb->p, n, 0, lo, hi, pt, seed) || swait(Y, "fill"))
			return;
		t0 = now();
		bad = verify(X, yb->p, n, lo, hi, pt, seed, &first);
	} else {
		if ((op != OP_STORE && (fill(X, xb->p, n, 0, 0, n, pt, seed) || swait(X, "fill source"))) ||
		    fill(Y, yb->p, n, 0, 0, 0, pt, seed) || swait(Y, "fill destination"))
			return;
		t0 = now();
		if (op == OP_STORE) {
			if (fill(X, yb->p + lo, hi - lo, lo, lo, hi, pt, seed) || swait(X, what))
				return;
		} else {
			struct dev *S = op == OP_PUSH ? X : Y; // the stream (and copy engine) that runs the copy
			if (use(S) || cerr(cudaMemcpyPeerAsync(yb->p + lo, Y->ord, xb->p + lo, X->ord, (hi - lo) * 8, S->s),
					   "cudaMemcpyPeerAsync") ||
			    swait(S, what))
				return;
		}
		bad = verify(Y, yb->p, n, lo, hi, pt, seed, &first);
		if (bad != ~0ull)
			sbad = spot(Y, yb->p, n, lo, hi, pt, seed);
	}
	if (bad == ~0ull || sbad == ~0ull)
		return;
	if (bad || sbad) {
		failed = 1;
		printf(" %s MISMATCH %llu words (host spot check %llu), first at byte 0x%llx", OP_NAME[op], bad, sbad,
		       first * 8);
	} else {
		printf(" %s ok %.1f ms", OP_NAME[op], (now() - t0) * 1e3);
	}
}

// The canary of d still holds its pattern.
static int canary_ok(struct dev *d)
{
	unsigned long long first = 0, bad = verify(d, d->canary, CANARY_WORDS, 0, CANARY_WORDS, P_RANDOM, CANARY_SEED, &first);
	if (bad == 0)
		return 1;
	if (bad != ~0ull) {
		printf("  CANARY on %s: %llu words changed, first at byte 0x%llx (a stray write outside the tested buffers)\n",
		       d->bus, bad, first * 8);
		failed = 1;
	}
	return 0;
}

// Copy bandwidth over bytes x reps: A->B, B->A, then both at once, on four buffers (two sources, two destinations);
// the destinations are compared afterwards. GB/s = 1e9 bytes per second.
static void bandwidth(struct dev *a, struct dev *b, size_t bytes, int reps)
{
	struct buf xa = {}, yb = {}, zb = {}, wa = {}; // A->B: xa -> yb; B->A: zb -> wa. Zeroed: a failed or skipped
						       // allocation leaves p NULL, and only allocated buffers are freed
	double gbs[3] = {0, 0, 0};
	unsigned long long first = 0, bad1, bad2;
	size_t n = bytes / 8;
	char s[32];
	int ok = !buf_alloc(a, b, bytes, 0, &xa);
	ok = ok && !buf_alloc(b, a, bytes, 0, &yb);
	ok = ok && !buf_alloc(b, a, bytes, 0, &zb);
	ok = ok && !buf_alloc(a, b, bytes, 0, &wa);
	ok = ok && !fill(a, xa.p, n, 0, 0, n, P_RANDOM, 0xB1) && !fill(b, zb.p, n, 0, 0, n, P_RANDOM, 0xB2) &&
	     !swait(a, "fill") && !swait(b, "fill");
	for (int k = 0; ok && k < 3 && !failed; k++) {
		int ab = k != 1, ba = k != 0;
		for (int warm = 1; warm >= 0 && !failed; warm--) {
			int r = warm ? 2 : reps;
			double t0 = now();
			for (int i = 0; i < r; i++) {
				if (ab && (use(a) || cerr(cudaMemcpyPeerAsync(yb.p, b->ord, xa.p, a->ord, bytes, a->s), "bandwidth copy")))
					break;
				if (ba && (use(b) || cerr(cudaMemcpyPeerAsync(wa.p, a->ord, zb.p, b->ord, bytes, b->s), "bandwidth copy")))
					break;
			}
			if ((ab && swait(a, "bandwidth A->B")) || (ba && swait(b, "bandwidth B->A")))
				break;
			if (!warm)
				gbs[k] = (double)bytes * r * (ab + ba) / (now() - t0) / 1e9;
		}
	}
	if (ok && !failed) {
		bad1 = verify(b, yb.p, n, 0, n, P_RANDOM, 0xB1, &first);
		bad2 = verify(a, wa.p, n, 0, n, P_RANDOM, 0xB2, &first);
		if (bad1 || bad2) {
			if (bad1 != ~0ull && bad2 != ~0ull)
				printf("  bandwidth buffers MISMATCH after the timed copies: B %llu words, A %llu words\n", bad1, bad2);
			failed = 1;
		}
	}
	if (xa.p) buf_free(a, &xa);
	if (yb.p) buf_free(b, &yb);
	if (zb.p) buf_free(b, &zb);
	if (wa.p) buf_free(a, &wa);
	if (!ok)
		failed = 1;
	if (!failed)
		printf("bandwidth (cudaMemcpyPeerAsync, %s x %d, contents checked): A->B %.2f GB/s, B->A %.2f GB/s, both "
		       "ways at once %.2f GB/s\n",
		       size_str(bytes, s, sizeof s), reps, gbs[0], gbs[1], gbs[2]);
}

// Sizes in bytes up to max: below 2 MiB, at and across the 2 MiB window size, then powers of two from 64 MiB.
static int sizes(size_t max, size_t *out)
{
	static const size_t fixed[] = {4096, 65536, MIB, 2 * MIB, 2 * MIB + 65536, 3 * MIB, 64 * MIB, 256 * MIB};
	int n = 0;
	for (size_t i = 0; i < sizeof fixed / sizeof fixed[0]; i++)
		if (fixed[i] <= max)
			out[n++] = fixed[i];
	for (size_t s = 1024 * MIB; s <= max && n < 32; s *= 2)
		out[n++] = s;
	if (max > 256 * MIB && max != out[n - 1] && n < 32)
		out[n++] = max;
	return n;
}

// The guarded range of a size, in bytes: [lo, bytes - tail). From 64 MiB on, lo and tail reach across a 2 MiB
// window; from 3 MiB on they lie inside the first and last window; below, only the end is guarded.
static void edges(size_t bytes, size_t *lo, size_t *tail)
{
	if (bytes >= 64 * MIB)
		*lo = *tail = 2 * MIB + 4096 + 8;
	else if (bytes >= 3 * MIB)
		*lo = *tail = 4096 + 8;
	else
		*lo = 0, *tail = bytes > 8192 ? 4096 + 8 : 8;
}

static int find_dev(const char *bus, struct dev *d)
{
	memset(d, 0, sizeof *d);
	d->bus = bus;
	if (cudaDeviceGetByPCIBusId(&d->ord, bus) != cudaSuccess) {
		printf("error: no CUDA device at %s (see p2p-integrity --list)\n", bus);
		return -1;
	}
	return 0;
}

static int list(void)
{
	int n = 0, drv = 0, rt = 0;
	cudaError_t e = cudaGetDeviceCount(&n);
	cudaDriverGetVersion(&drv);
	cudaRuntimeGetVersion(&rt);
	printf("CUDA driver %d, runtime %d\n", drv, rt);
	if (e != cudaSuccess) {
		printf("error: cudaGetDeviceCount: %s\n", cudaGetErrorString(e));
		return 2;
	}
	for (int i = 0; i < n; i++) {
		struct cudaDeviceProp p;
		char bus[32] = "";
		if (cudaGetDeviceProperties(&p, i) != cudaSuccess || cudaDeviceGetPCIBusId(bus, sizeof bus, i) != cudaSuccess)
			return 2;
		printf("device %d %s %s cc %d.%d %llu MiB\n", i, bus, p.name, p.major, p.minor,
		       (unsigned long long)(p.totalGlobalMem / MIB));
	}
	for (int i = 0; i < n; i++)
		for (int j = 0; j < n; j++) {
			int c = 0;
			if (i == j)
				continue;
			cudaDeviceCanAccessPeer(&c, i, j);
			printf("can access peer %d -> %d: %d\n", i, j, c);
		}
	return 0;
}

// Cases of the plan: allocators x sizes x 2 ranges x patterns x repeats.
static unsigned long long plan_cases(size_t max, unsigned long repeat)
{
	size_t sz[32];
	return 2ull * sizes(max, sz) * 2 * NPAT * repeat;
}

static int selftest(size_t max)
{
	size_t sz[32], lo, tail;
	int n = sizes(max, sz), bad = 0;
	char s[32];
	// splitmix64 reference value: the first output for state 0
	if (pat(P_RANDOM, 0, 0) != 0xE220A8397B1DCDAFull)
		bad++;
	if (pat(P_RANDOM, 1, 0) == pat(P_RANDOM, 2, 0) || pat(P_RANDOM, 1, 0) == pat(P_RANDOM, 1, 1))
		bad++;
	if (pat(P_ALT, 0, 0) != 0x5555555555555555ull || pat(P_ALT, 0, 1) != 0xAAAAAAAAAAAAAAAAull ||
	    pat(P_WALK, 0, 65) != 2 || pat(P_ADDR, 0, 3) != 24)
		bad++;
	if (want_at(P_ZEROS, 0, 4, 5, 9) != ~0ull || want_at(P_ZEROS, 0, 5, 5, 9) != 0 || want_at(P_ZEROS, 0, 9, 5, 9) != ~0ull)
		bad++;
	printf("plan for --max-mib %llu: %d sizes, each also with guard bands [lo, size - tail):", (unsigned long long)(max / MIB), n);
	for (int i = 0; i < n; i++) {
		edges(sz[i], &lo, &tail);
		if (lo % 8 || tail % 8 || lo + tail >= sz[i] || (sz[i] >= 3 * MIB && (lo % (2 * MIB) == 0 || tail % (2 * MIB) == 0)))
			bad++;
		printf(" %s[%llu, -%llu]", size_str(sz[i], s, sizeof s), (unsigned long long)lo, (unsigned long long)tail);
	}
	printf("\npatterns:");
	for (int p = 0; p < NPAT; p++)
		printf(" %s", PAT_NAME[p]);
	printf("\ntransfers per case and direction:");
	for (int o = 0; o < NOP; o++)
		printf(" %s", OP_NAME[o]);
	printf("\ncases %llu\nselftest %s\n", plan_cases(max, 1), bad ? "FAILED" : "ok");
	return bad ? 1 : 0;
}

static int parse_num(const char *s, unsigned long lo, unsigned long hi, unsigned long *out)
{
	char *end;
	if (!s || !*s || *s == '-' || *s == '+')
		return -1;
	unsigned long v = strtoul(s, &end, 10);
	if (*end || v < lo || v > hi)
		return -1;
	*out = v;
	return 0;
}

static int usage(void)
{
	fprintf(stderr, "usage: p2p-integrity --list | --selftest [--max-mib N] | --pair BUS_A BUS_B [--max-mib N] "
			"[--repeat R] [--timeout S] [--op-timeout S]\n");
	return 2;
}

int main(int argc, char **argv)
{
	const char *bus_a = NULL, *bus_b = NULL;
	unsigned long max_mib = 4096, repeat = 1, total_timeout = 0;
	int mode = 0; // 1 list, 2 selftest, 3 pair
	setvbuf(stdout, NULL, _IOLBF, 0);
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--list"))
			mode = 1;
		else if (!strcmp(argv[i], "--selftest"))
			mode = 2;
		else if (!strcmp(argv[i], "--pair") && i + 2 < argc) {
			mode = 3;
			bus_a = argv[++i];
			bus_b = argv[++i];
		} else if (!strcmp(argv[i], "--max-mib") && i + 1 < argc) {
			if (parse_num(argv[++i], 4, 65536, &max_mib))
				return usage();
		} else if (!strcmp(argv[i], "--repeat") && i + 1 < argc) {
			if (parse_num(argv[++i], 1, 100, &repeat))
				return usage();
		} else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) {
			if (parse_num(argv[++i], 0, 86400, &total_timeout))
				return usage();
		} else if (!strcmp(argv[i], "--op-timeout") && i + 1 < argc) {
			if (parse_num(argv[++i], 1, 86400, &op_timeout))
				return usage();
		} else
			return usage();
	}
	printf("p2p-integrity %s\n", VERSION);
	if (mode == 2)
		return selftest(max_mib * MIB);
	if (mode == 1)
		return list();
	if (mode != 3 || !strcmp(bus_a, bus_b))
		return usage();

	snprintf(timeout_tail, sizeof timeout_tail, "RESULT FAIL %s %s timeout\n", bus_a, bus_b);
	if (total_timeout) {
		signal(SIGALRM, on_alarm);
		alarm((unsigned)total_timeout);
	}
	struct dev A, B;
	int drv = 0, rt = 0, can_ab = 0, can_ba = 0, att_ab = 0, att_ba = 0;
	if (find_dev(bus_a, &A) || find_dev(bus_b, &B) || load_driver())
		return 2;
	cudaDriverGetVersion(&drv);
	cudaRuntimeGetVersion(&rt);
	printf("CUDA driver %d, runtime %d\n", drv, rt);
	struct dev *d2[2] = {&A, &B};
	for (int k = 0; k < 2; k++) {
		struct dev *d = d2[k];
		struct cudaDeviceProp p;
		size_t fr = 0, tot = 0;
		CUmemAllocationProp prop;
		if (use(d) || cerr(cudaFree(0), "context") ||
		    cerr(cudaGetDeviceProperties(&p, d->ord), "cudaGetDeviceProperties") ||
		    cerr(cudaStreamCreateWithFlags(&d->s, cudaStreamNonBlocking), "cudaStreamCreate") ||
		    cerr(cudaMalloc((void **)&d->cnt, 16), "cudaMalloc") ||
		    cerr(cudaMallocHost((void **)&d->hcnt, 16), "cudaMallocHost") ||
		    cerr(cudaMallocHost((void **)&d->hspot, SPOT_WORDS * 8), "cudaMallocHost") ||
		    derr(p_cuDeviceGet(&d->cu, d->ord), "cuDeviceGet") || cerr(cudaMemGetInfo(&fr, &tot), "cudaMemGetInfo"))
			return 2;
		memset(&prop, 0, sizeof prop);
		prop.type = CU_MEM_ALLOCATION_TYPE_PINNED;
		prop.location.type = CU_MEM_LOCATION_TYPE_DEVICE;
		prop.location.id = d->cu;
		if (derr(p_cuMemGetAllocationGranularity(&d->gran, &prop, CU_MEM_ALLOC_GRANULARITY_MINIMUM),
			 "cuMemGetAllocationGranularity") || !d->gran)
			return 2;
		printf("GPU %c %s: %s, cc %d.%d, %llu MiB, %llu MiB free, cuMem granularity %llu KiB\n", "AB"[k], d->bus,
		       p.name, p.major, p.minor, (unsigned long long)(tot / MIB), (unsigned long long)(fr / MIB),
		       (unsigned long long)(d->gran >> 10));
	}
	if (cerr(cudaDeviceCanAccessPeer(&can_ab, A.ord, B.ord), "cudaDeviceCanAccessPeer") ||
	    cerr(cudaDeviceCanAccessPeer(&can_ba, B.ord, A.ord), "cudaDeviceCanAccessPeer") ||
	    cerr(cudaDeviceGetP2PAttribute(&att_ab, cudaDevP2PAttrAccessSupported, A.ord, B.ord), "cudaDeviceGetP2PAttribute") ||
	    cerr(cudaDeviceGetP2PAttribute(&att_ba, cudaDevP2PAttrAccessSupported, B.ord, A.ord), "cudaDeviceGetP2PAttribute"))
		goto out;
	printf("cudaDeviceCanAccessPeer: A->B %d, B->A %d; P2P access attribute: A->B %d, B->A %d\n", can_ab, can_ba,
	       att_ab, att_ba);
	if (!can_ab || !can_ba || !att_ab || !att_ba) {
		printf("no peer access between %s and %s: the driver does not offer P2P for this pair, so copies would be "
		       "staged through host memory. Nothing was copied.\n",
		       bus_a, bus_b);
		printf("RESULT NO_P2P %s %s\n", bus_a, bus_b);
		return 3;
	}
	{
		cudaError_t e;
		if (use(&A))
			goto out;
		e = cudaDeviceEnablePeerAccess(B.ord, 0);
		if (e != cudaErrorPeerAccessAlreadyEnabled && cerr(e, "cudaDeviceEnablePeerAccess A->B"))
			goto out;
		if (use(&B))
			goto out;
		e = cudaDeviceEnablePeerAccess(A.ord, 0);
		if (e != cudaErrorPeerAccessAlreadyEnabled && cerr(e, "cudaDeviceEnablePeerAccess B->A"))
			goto out;
		cudaGetLastError();
	}
	printf("peer access enabled both ways; the store and load transfers use it directly from kernels\n");
	if (kernel_selfcheck(&A) || kernel_selfcheck(&B))
		goto out;
	for (int k = 0; k < 2; k++) {
		struct dev *d = d2[k];
		if (use(d) || cerr(cudaMalloc((void **)&d->canary, CANARY_WORDS * 8), "cudaMalloc canary") ||
		    fill(d, d->canary, CANARY_WORDS, 0, 0, CANARY_WORDS, P_RANDOM, CANARY_SEED) || swait(d, "canary fill"))
			goto out;
	}

	{
		size_t sz[32], fa = 0, fb = 0, tot, margin = 256 * MIB;
		unsigned long long cases = 0, transfers = 0, copied = 0, small_skips = 0;
		int n = sizes(max_mib * MIB, sz);
		char s[32];
		if (use(&A) || cerr(cudaMemGetInfo(&fa, &tot), "cudaMemGetInfo") || use(&B) ||
		    cerr(cudaMemGetInfo(&fb, &tot), "cudaMemGetInfo"))
			goto out;
		for (unsigned long r = 0; r < repeat && !failed; r++)
			for (int vmm = 0; vmm < 2 && !failed; vmm++)
				for (int i = 0; i < n && !failed; i++) {
					size_t bytes = sz[i], words = bytes / 8, lo, tail;
					size_t need = vmm ? (bytes + A.gran - 1) / A.gran * A.gran : bytes;
					if (need + margin > fa || need + margin > fb) {
						if (r == 0)
							printf("skip %s %s: %llu MiB free on A, %llu MiB on B%s\n", vmm ? "cumem " : "malloc",
							       size_str(bytes, s, sizeof s), (unsigned long long)(fa / MIB),
							       (unsigned long long)(fb / MIB), bytes <= 1024 * MIB ? " (FAIL: sizes up to 1 GiB must run)" : "");
						if (bytes <= 1024 * MIB)
							small_skips++;
						continue;
					}
					struct buf x, y;
					if (buf_alloc(&A, &B, bytes, vmm, &x))
						break;
					if (buf_alloc(&B, &A, bytes, vmm, &y)) {
						buf_free(&A, &x);
						break;
					}
					edges(bytes, &lo, &tail);
					size_t rlo[2] = {0, lo / 8}, rhi[2] = {words, (bytes - tail) / 8};
					for (int o = 0; o < 2 && !failed; o++)
						for (int pt = 0; pt < NPAT && !failed; pt++) {
							uint64_t seed = splitmix(0xC0FFEE + r, cases * 2);
							printf("case %llu %s %s words [%llu, %llu) of %llu %s:", ++cases, vmm ? "cumem " : "malloc",
							       size_str(bytes, s, sizeof s), (unsigned long long)rlo[o],
							       (unsigned long long)rhi[o], (unsigned long long)words, PAT_NAME[pt]);
							for (int dir = 0; dir < 2 && !failed; dir++) {
								printf(dir ? " | B->A" : " A->B");
								for (int op = 0; op < NOP && !failed; op++) {
									if (dir == 0)
										one_op(op, &A, &x, &B, &y, words, rlo[o], rhi[o], pt, seed);
									else
										one_op(op, &B, &y, &A, &x, words, rlo[o], rhi[o], pt, ~seed);
									if (!failed) {
										transfers++;
										copied += (rhi[o] - rlo[o]) * 8;
									}
								}
							}
							printf("\n");
						}
					buf_free(&A, &x);
					buf_free(&B, &y);
					if (!failed && (!canary_ok(&A) || !canary_ok(&B)))
						failed = 1;
				}
		if (small_skips) {
			printf("FAIL: %llu size(s) up to 1 GiB skipped for lack of free memory; stop other GPU programs\n", small_skips);
			failed = 1;
		}
		if (!failed && cases == 0) {
			printf("FAIL: no case ran\n");
			failed = 1;
		}
		if (!failed)
			bandwidth(&A, &B, max_mib * MIB < 256 * MIB ? max_mib * MIB : 256 * MIB, 20);
		if (swait(&A, "final wait A") || swait(&B, "final wait B") || use(&A) ||
		    cerr(cudaGetLastError(), "sticky error A") || use(&B) || cerr(cudaGetLastError(), "sticky error B"))
			failed = 1;
		printf("RESULT %s %s %s max-mib %lu cases %llu transfers %llu copied %.1f GiB\n", failed ? "FAIL" : "PASS",
		       bus_a, bus_b, max_mib, cases, transfers, copied / (double)(1ull << 30));
		return failed ? 1 : 0;
	}
out:
	printf("RESULT FAIL %s %s max-mib %lu cases 0\n", bus_a, bus_b, max_mib);
	return 1;
}
