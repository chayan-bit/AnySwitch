# Tests of the iOS front end's Foundation-only parts (they run on the Mac): make -C dm/ios/tests run
t_settings: t_settings.m ../Sources/DmSettings.m ../Sources/DmSettings.h ../Sources/DmPalette.h
	clang -O1 -g -Wall -fobjc-arc -I../Sources -o $@ t_settings.m ../Sources/DmSettings.m -framework Foundation
t_haptics: t_haptics.c ../Sources/DmHapticMap.h ../../host/dm_input.h
	clang -O1 -g -Wall -I../Sources -I../../host -o $@ t_haptics.c -lm
t_library: t_library.m ../Hearth/HearthLibrary.m ../Hearth/HearthLibrary.h ../Hearth/HearthSign.m ../Hearth/HearthSign.h ../Hearth/HearthSound.m ../Hearth/HearthSound.h ../../host/boot.m ../../host/boot.h ../../host/profile.m
	clang -O1 -g -Wall -fobjc-arc -I../Hearth -I../../host -o $@ t_library.m ../Hearth/HearthLibrary.m ../Hearth/HearthSign.m ../Hearth/HearthSound.m ../../host/boot.m ../../host/profile.m -framework Foundation
t_import: t_import.m ../Hearth/HearthImport.m ../Hearth/HearthImport.h ../Hearth/HearthLibrary.m ../Hearth/HearthLibrary.h ../Hearth/HearthSign.m ../Hearth/HearthSound.m ../../host/boot.m ../../host/profile.m
	clang -O1 -g -Wall -fobjc-arc -I../Hearth -I../../host -o $@ t_import.m ../Hearth/HearthImport.m ../Hearth/HearthLibrary.m ../Hearth/HearthSign.m ../Hearth/HearthSound.m ../../host/boot.m ../../host/profile.m -framework Foundation -lAppleArchive
t_home_focus: t_home_focus.m ../Hearth/HearthFocus.m ../Hearth/HearthFocus.h ../Sources/DmRepeat.m ../Sources/DmRepeat.h
	clang -O1 -g -Wall -fobjc-arc -I../Hearth -I../Sources -o $@ t_home_focus.m ../Hearth/HearthFocus.m ../Sources/DmRepeat.m -framework Foundation
PACK_ID = $(firstword $(sort $(notdir $(patsubst %/game.tsv,%,$(wildcard ../../games/*/game.tsv)))))
run: t_settings t_haptics t_library t_import t_home_focus
	./t_settings
	python3 -I ../../games/game.py json $(PACK_ID) t_library.profile > /dev/null
	./t_library t_library.profile $(PACK_ID)
	./t_import t_library.profile $(PACK_ID)
	./t_home_focus
	./t_haptics
	python3 -I test_device_gpu.py   # tools/device_gpu.py chip IDs -> GPU architectures and the fallback
	python3 -I test_build_defaults.py   # tools/build_ipa.sh: chunk store by default, flexible pipeline archive on by default
clean:
	rm -rf t_settings t_settings.dSYM t_haptics t_haptics.dSYM t_library t_library.dSYM t_home_focus t_home_focus.dSYM t_import t_import.dSYM t_library.profile
.PHONY: run clean
