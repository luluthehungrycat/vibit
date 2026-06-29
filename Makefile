#==============================================================================
# Makefile for VIBIT — VIBIX Init and Service Manager
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
INC_FILES  = $(BUILD_DIR)/vibix_core.inc   \
             $(BUILD_DIR)/vibix_tiny.inc   \
             $(BUILD_DIR)/vibix_echo.inc   \
             $(BUILD_DIR)/vibix_cat.inc    \
             $(BUILD_DIR)/vibix_printenv.inc \
             $(BUILD_DIR)/vibix_clear.inc  \
             $(BUILD_DIR)/vibix_shell.inc
OUTPUT     = $(BUILD_DIR)/vibit.bin

.PHONY: all clean size

all: $(OUTPUT)

$(OUTPUT): $(ASM_SRC) $(INC_FILES)
	$(NASM) -f bin -Wno-error=label-redef-late -o $@ $<

clean:
	rm -f $(OUTPUT)

size: $(OUTPUT)
	@ls -l $(OUTPUT)
	@echo -n "Binary size: "
	@wc -c < $(OUTPUT)
	@echo "bytes"
