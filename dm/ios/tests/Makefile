# Tests of the iOS front end's Foundation-only parts (they run on the Mac): make -C dm/ios/tests run
t_settings: t_settings.m ../Sources/DmSettings.m ../Sources/DmSettings.h
	clang -O1 -g -Wall -fobjc-arc -I../Sources -o $@ t_settings.m ../Sources/DmSettings.m -framework Foundation
run: t_settings
	./t_settings
clean:
	rm -rf t_settings t_settings.dSYM
.PHONY: run clean
