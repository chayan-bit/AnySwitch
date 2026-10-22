# Tests of the iOS front end's Foundation-only parts (they run on the Mac): make -C dm/ios/tests run
t_settings: t_settings.m ../Sources/DmSettings.m ../Sources/DmSettings.h ../Sources/DmPalette.h
	clang -O1 -g -Wall -fobjc-arc -I../Sources -o $@ t_settings.m ../Sources/DmSettings.m -framework Foundation
t_haptics: t_haptics.c ../Sources/DmHapticMap.h ../../host/dm_input.h
	clang -O1 -g -Wall -I../Sources -I../../host -o $@ t_haptics.c -lm
run: t_settings t_haptics
	./t_settings
	./t_haptics
	python3 -I test_device_gpu.py   # tools/device_gpu.py chip IDs -> GPU architectures and the fallback
	python3 -I test_build_defaults.py   # tools/build_ipa.sh: chunk store by default, flexible pipeline archive on by default
clean:
	rm -rf t_settings t_settings.dSYM t_haptics t_haptics.dSYM
.PHONY: run clean
