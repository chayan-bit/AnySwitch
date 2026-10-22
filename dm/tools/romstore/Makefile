# romstore_tool, the scan and verify helper of romstore.py: make -C dm/tools/romstore (build output goes to build/ and is not committed)
B = build
ZSTD = ../../third_party/zstd/lib
ZSTD_SRC = $(sort $(wildcard $(ZSTD)/common/*.c $(ZSTD)/decompress/*.c))
$(B)/romstore_tool: romstore_tool.c ../../host/romstore.c ../../host/romstore.h $(ZSTD_SRC) | $(B)
	clang -O2 -Wall -DZSTD_DISABLE_ASM -I../../host -I$(ZSTD) -o $@ romstore_tool.c ../../host/romstore.c $(ZSTD_SRC)
$(B):
	mkdir -p $@
