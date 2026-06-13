# Cache

## Project structure

```
project/
│
├── src/                 # RTL source files
├── tb/                  # Testbenches
├── sim/                 # Simulation scripts and config
├── build/               # Build-related outputs (e.g., synthesis)
├── docs/                # Documentation, specs
└── Makefile             # Project-level build/sim control
```

## Requirements

Design and simulate a **32 KiB 4-way set-associative cache**, with 8-word blocks and
32-bit words. Main memory size is 8 MiB, the addressable unit is the word. The cache is
**write-back**, **write-allocate**, with an **LRU** replacement policy.

## Parameters

### Cache

$32\ \text{KiB} = 2^5 \times 2^{10}\ B$. With $32\ \text{bits} = 4B = 2^2\ B$ per word, the
cache holds $\frac{2^5 \times 2^{10}}{2^2} = 2^{13}$ words. With 8 words per block
($2^3$ words/block) there are $\frac{2^{13}}{2^3} = 2^{10} = 1024$ blocks.

Because the cache is **4-way set associative**, the 1024 blocks are grouped into
$\frac{1024}{4} = 256 = 2^8$ **sets**, so the index field is **8 bits** (instead of 10
in the direct-mapped version). Each set holds 4 blocks (ways).

| Tag    | Index  | Block Offset |
|--------|--------|--------------|
| 10 bits| 8 bits | 3 bits       |

### Main Memory

Main memory is $8\ \text{MiB} = 2^3 \times 2^{20}\ B$. Since the addressable unit is the
word (4 B), there are $\frac{2^3 \times 2^{20}}{2^2} = 2^{21}$ words, i.e. a **21-bit**
word address. Therefore the tag size is $21 - 8 - 3 = 10$ bits.

The address issued from the cache controller to main memory is $10 + 8 = 18$ bits, made
of tag and index (one block per memory location).

### Offsets

| Tag (20:11) | Index (10:3) | Block Offset (2:0) |
|-------------|--------------|--------------------|
| 10 bits     | 8 bits       | 3 bits             |

## Cache controller parameters

```verilog
parameter BLOCK_SIZE    = 256;  // bits (8 words * 4 B * 8 bits)
parameter ADDRESS_WIDTH = 21;   // bits (3 + 8 + 10)
parameter INDEX_WIDTH   = 8;    // bits -> 256 sets
parameter TAG_WIDTH     = 10;   // bits
parameter OFFSET_WIDTH  = 3;    // bits
parameter WORD_SIZE     = 32;   // bits
parameter NWAYS         = 4;    // 4-way set associative
parameter NSETS         = 256;  // 2^8 sets
```

## Replacement policy (LRU)

Each set keeps a 2-bit rank per way (`lru_cnt`). A rank of `NWAYS-1 = 3` marks the
most-recently-used way, `0` marks the least-recently-used way. On every completed access
the touched way is promoted to rank 3 and the ways that were above it are decremented,
which keeps the four ranks a valid permutation of `{0,1,2,3}`. On a miss the victim is the
first invalid way, or — if the set is full — the way whose rank is `0`.

## Build & run

```
make            # compile + run the testbench
make clean      # remove build/ and sim/
# or directly:
iverilog -g2012 -Iinclude -s cache_controller_tb src/*.sv tb/cache_controller_tb.sv -o build/sim.out
vvp build/sim.out
```

The testbench (`tb/cache_controller_tb.sv`) is self-checking and covers: basic read
miss/hit, true 4-way coexistence in one set, LRU eviction order, and write-allocate with
dirty write-back to memory.
