import random

# Each memory line is one cache block = 8 words * 32 bits = 256 bits = 64 hex digits.
# NOTE: memory.sv loads the file with $readmemh, so the file MUST be hex
# (the original generate_data.py emitted binary, which produced the
#  "Excess hex digits" warning in the simulation log).

WORDS_PER_BLOCK = 8

def random_block_hex():
    # 8 words, each 8 hex digits (32 bits) -> 64 hex digits per line
    return "".join(format(random.getrandbits(32), "08x") for _ in range(WORDS_PER_BLOCK))

def generate_file(num_lines=2048, filename="mem_data.txt"):
    with open(filename, "w") as f:
        for _ in range(num_lines):
            f.write(random_block_hex() + "\n")

if __name__ == "__main__":
    num_lines = 2048          # enough to cover the addresses used by the testbench
    generate_file(num_lines=num_lines)
    print(f"Generated {num_lines} lines of 64-hex-digit (256-bit) blocks in mem_data.txt")
