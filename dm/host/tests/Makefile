# dm/host unit tests in one command: make -C dm/host/tests run (takes seconds; build output goes to build/ and is not committed)
B = build
run: $(B)/t_touch $(B)/t_oe $(B)/t_fs $(B)/t_fs_commit_list $(B)/t_thread_leak $(B)/t_fs_case $(B)/t_audio $(B)/t_audio_spsc $(B)/t_swkbd $(B)/t_altstack $(B)/t_condvar $(B)/t_condvar_old $(B)/t_gate_stats $(B)/t_time $(B)/t_sync $(B)/t_gate_cost $(B)/t_devctl $(B)/t_vib $(B)/t_romstore $(B)/t_err $(B)/t_account $(B)/t_album
	$(B)/t_touch
	$(B)/t_vib
	$(B)/t_oe 2>/dev/null
	$(B)/t_fs 2>/dev/null
	TMPDIR="$(abspath $(B))" $(B)/t_fs_commit_list
	$(B)/t_thread_leak
	TMPDIR="$(abspath $(B))" $(B)/t_fs_case 2>/dev/null
	$(B)/t_audio
	$(B)/t_audio_spsc
	$(B)/t_swkbd
	$(B)/t_altstack
	$(B)/t_condvar
	$(B)/t_condvar_old
	$(B)/t_gate_stats
	$(B)/t_time 2>/dev/null
	$(B)/t_sync
	$(B)/t_gate_cost
	$(B)/t_devctl
	$(B)/t_err 2>/dev/null
	$(B)/t_account 2>/dev/null
	$(B)/t_album 2>/dev/null
	TMPDIR="$(abspath $(B))" $(B)/t_romstore 2>/dev/null
$(B)/t_touch: t_touch.c ../hle_touch.c ../front.h ../dm.h ../profile.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_touch.c ../hle_touch.c
$(B)/t_vib: t_vib.c ../hle_vibration.c ../hle.h ../dm_input.h ../dm.h ../profile.h | $(B)
	clang -O1 -Wall -Wno-unused-function -I.. -o $@ t_vib.c
$(B)/t_thread_leak: t_thread_leak.c ../thread.c ../dm.h ../profile.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_thread_leak.c
$(B)/t_fs: t_fs.c t_fs_stub.c ../hle_fs.c ../romstore.c ../romstore.h ../hle_bigstack.c ../hle.h ../dm.h ../profile.h $(B)/libzstd.a | $(B)
	clang -O1 -Wno-unused-function -I.. -I$(ZSTD) -o $@ t_fs.c t_fs_stub.c ../romstore.c ../hle_bigstack.c $(B)/libzstd.a
$(B)/t_fs_commit_list: t_fs_commit_list.c t_fs_stub.c ../hle_fs.c ../romstore.c ../romstore.h ../hle_bigstack.c ../hle.h ../dm.h ../profile.h $(B)/libzstd.a | $(B)
	clang -O1 -Wall -Wno-unused-function -I.. -I$(ZSTD) -o $@ t_fs_commit_list.c t_fs_stub.c ../romstore.c ../hle_bigstack.c $(B)/libzstd.a
$(B)/t_fs_case: t_fs_case.c ../hle_fs.c ../romstore.c ../romstore.h ../hle_bigstack.c ../hle.h ../dm.h ../profile.h $(B)/libzstd.a | $(B)
	clang -O1 -Wno-unused-function -I.. -I$(ZSTD) -o $@ t_fs_case.c ../romstore.c ../hle_bigstack.c $(B)/libzstd.a
$(B)/t_audio: t_audio.c ../hle_audio.c ../hle.h ../dm.h ../profile.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_audio.c -framework AudioToolbox
$(B)/t_audio_spsc: t_audio_spsc.c ../hle_audio.c ../hle.h ../dm.h ../profile.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_audio_spsc.c -framework AudioToolbox
$(B)/t_audio_spsc_tsan: t_audio_spsc.c ../hle_audio.c ../hle.h ../dm.h ../profile.h | $(B)
	clang -O1 -g -O1 -fsanitize=thread -Wno-unused-function -I.. -o $@ t_audio_spsc.c -framework AudioToolbox
$(B)/t_time: t_time.c ../hle_time.c ../hle.h ../dm.h ../profile.h | $(B)
	clang -O1 -Wall -Wno-unused-function -I.. -o $@ t_time.c
$(B)/t_swkbd: t_swkbd.c ../hle_swkbd.c ../hle.h ../dm.h ../profile.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_swkbd.c ../hle_swkbd.c
$(B)/t_altstack: t_altstack.c t_altstack_stub.c ../crash.c ../dm.h ../profile.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_altstack.c t_altstack_stub.c ../crash.c
$(B)/t_oe: t_oe.c ../hle_oe.c ../hle.h ../dm.h ../profile.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_oe.c
$(B)/t_condvar: t_condvar.c t_condvar_stub.c ../hle_thread.c ../dm.h ../profile.h | $(B)
	clang -O1 -Wno-unused-function -DDM_TEST_HOOKS -I.. -o $@ t_condvar.c t_condvar_stub.c ../hle_thread.c
$(B)/t_condvar_old: t_condvar.c t_condvar_stub.c ../hle_thread.c ../dm.h ../profile.h | $(B)
	clang -O1 -Wno-unused-function -DDM_TEST_HOOKS -DDM_TEST_CV_OLD_ORDER -I.. -o $@ t_condvar.c t_condvar_stub.c ../hle_thread.c
$(B)/t_gate_stats: t_gate_stats.c t_condvar_stub.c ../hle_thread.c ../dm.h ../profile.h | $(B)
	clang -O1 -Wno-unused-function -I.. -o $@ t_gate_stats.c t_condvar_stub.c ../hle_thread.c
$(B)/t_sync: t_sync.c t_condvar_stub.c ../hle_thread.c ../dm.h ../profile.h | $(B)
	clang -O1 -Wall -Wno-unused-function -DDM_TEST_HOOKS -I.. -o $@ t_sync.c t_condvar_stub.c ../hle_thread.c
$(B)/t_account: t_account.c ../hle_account.c ../hle_bigstack.c ../hle.h ../dm.h ../front.h | $(B)
	clang -O1 -Wall -Wno-unused-function -Wno-incompatible-pointer-types-discards-qualifiers -DT_ACCOUNT -I.. -o $@ t_account.c ../hle_bigstack.c
$(B)/t_album: t_album.c ../hle_album.c ../hle_bigstack.c ../hle.h ../dm.h ../front.h | $(B)
	clang -O1 -Wall -Wno-unused-function -DT_ALBUM -I.. -o $@ t_album.c ../hle_album.c ../hle_bigstack.c
$(B)/t_err: t_err.c ../hle_err.c ../hle_bigstack.c ../hle.h ../dm.h ../front.h | $(B)
	clang -O1 -Wall -Wno-unused-function -Wno-incompatible-pointer-types-discards-qualifiers -I.. -o $@ t_err.c ../hle_err.c ../hle_bigstack.c
$(B)/t_devctl: t_devctl.c ../devctl.c ../devctl.h ../dm_input.h | $(B)
	clang -O1 -Wall -I.. -o $@ t_devctl.c ../devctl.c
# zstd for t_romstore: the reader's decompressor plus the compressor that writes the test's synthetic store
ZSTD = ../../third_party/zstd/lib
ZSTD_SRC = $(sort $(wildcard $(ZSTD)/common/*.c $(ZSTD)/decompress/*.c $(ZSTD)/compress/*.c))
ZSTD_OBJ = $(patsubst $(ZSTD)/%.c,$(B)/zstd/%.o,$(ZSTD_SRC))
$(B)/zstd/%.o: $(ZSTD)/%.c
	@mkdir -p $(dir $@)
	clang -O2 -DZSTD_DISABLE_ASM -I$(ZSTD) -c $< -o $@
$(B)/libzstd.a: $(ZSTD_OBJ)
	rm -f $@; ar rcs $@ $^
$(B)/t_romstore: t_romstore.c t_fs_stub.c ../hle_fs.c ../romstore.c ../romstore.h ../hle_bigstack.c ../hle.h ../dm.h ../profile.h $(B)/libzstd.a | $(B)
	clang -O1 -Wall -Wno-unused-function -I.. -I$(ZSTD) -o $@ t_romstore.c t_fs_stub.c ../hle_bigstack.c $(B)/libzstd.a
$(B):
	mkdir -p $@
$(B)/t_gate_cost: t_gate_cost.c t_gate_cost.S t_condvar_stub.c ../entry.S ../hle.c ../hle_thread.c ../dm.h ../profile.h | $(B)
	clang -O1 -Wall -Wno-unused-function -I.. -o $@ t_gate_cost.c t_gate_cost.S t_condvar_stub.c ../entry.S ../hle.c ../hle_thread.c
$(B)/t_sync_tsan: t_sync.c t_condvar_stub.c ../hle_thread.c ../dm.h ../profile.h | $(B)
	clang -O1 -g -fsanitize=thread -Wno-unused-function -DDM_TEST_HOOKS -I.. -o $@ t_sync.c t_condvar_stub.c ../hle_thread.c
# Every profile in dm/games: game.py json writes its game.json, t_profile.m checks profile.m accepts it (id, chain version) and refuses each kind of bad game.json
PROFILES = $(sort $(notdir $(patsubst %/game.tsv,%,$(wildcard ../../games/*/game.tsv))))
profile-schema: $(B)/t_profile ../../games/game.py
	@set -e; for id in $(PROFILES); do d=$(B)/profile/$$id; python3 ../../games/game.py json $$id $$d; \
	  $(B)/t_profile $$d $$id "$$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' ../../games/$$id/dmsh_chain.h)"; done; echo "profile schema: $(words $(PROFILES)) profiles ok"
$(B)/t_profile: t_profile.m ../profile.m ../profile.h ../dm_abi.h | $(B)
	clang -O0 -Wall -Wno-unused-function -fobjc-arc -I.. -o $@ t_profile.m ../profile.m -framework Foundation
# The pack version contract (boot.m dm_pack_check): scratch packs built from one profile's game.json
PACK_ID = $(firstword $(PROFILES))
pack-check: $(B)/t_pack $(B)/t_pack_embedded ../../games/game.py
	@python3 ../../games/game.py json $(PACK_ID) $(B)/pack_profile
	TMPDIR="$(abspath $(B))" $(B)/t_pack $(B)/pack_profile $(PACK_ID) 2>/dev/null
	TMPDIR="$(abspath $(B))" $(B)/t_pack_embedded $(B)/pack_profile $(PACK_ID) 2>/dev/null
$(B)/t_pack: t_pack.m ../boot.m ../boot.h ../profile.m ../profile.h ../dm_abi.h ../dm.h | $(B)
	clang -O0 -Wall -Wno-unused-function -fobjc-arc -I.. -o $@ t_pack.m ../boot.m ../profile.m -framework Foundation
$(B)/t_pack_embedded: t_pack.m ../boot.m ../boot.h ../profile.m ../profile.h ../dm_abi.h ../dm.h | $(B)
	clang -O0 -Wall -Wno-unused-function -fobjc-arc -I.. -DEMBED_TITLE='"$(PACK_ID)"' -o $@ t_pack.m ../boot.m ../profile.m -framework Foundation
.PHONY: run tsan profile-schema pack-check
tsan: $(B)/t_audio_spsc_tsan $(B)/t_sync_tsan
	$(B)/t_audio_spsc_tsan
	T_SYNC_SECS=10 $(B)/t_sync_tsan
