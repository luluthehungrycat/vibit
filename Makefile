#==============================================================================
# Makefile for VIBIT — VIBIX Init
#
# Builds vibit.bin as a flat binary loaded at 0x2000000.
# Intended to replace userspace/vibix_blob.bin in the VIBIX kernel build.
#
# Targets:
#   all       — build vibit.bin
#   clean     — remove build artifacts
#   size      — show binary size
#==============================================================================

NASM       = nasm
BUILD_DIR  = .

ASM_SRC    = $(BUILD_DIR)/vibit.asm
OUTPUT     = $(BUILD_DIR)/vibit.bin

.PHONY: all clean size

all: $(OUTPUT)

$(OUTPUT): $(ASM_SRC)
	$(NASM) -f bin -o $@ $<

clean:
	rm -f $(OUTPUT)

size: $(OUTPUT)
	@ls -l $(OUTPUT)
	@echo -n "Binary size: "
	@wc -c < $(OUTPUT)
	@echo "bytes"
