# Tests of the iOS front end's Foundation-only parts (they run on the Mac): make -C dm/ios/tests run
t_settings: t_settings.m ../Sources/DmSettings.m ../Sources/DmSettings.h ../Sources/DmPalette.h ../Sources/DmControlMap.m ../../host/keymap.c
	clang -O1 -g -Wall -fobjc-arc -I../Sources -I../../host -o $@ t_settings.m ../Sources/DmSettings.m ../Sources/DmControlMap.m ../../host/keymap.c -framework Foundation
t_library: t_library.m ../Hearth/HearthErrors.m ../Hearth/HearthErrors.h ../Hearth/HearthLibrary.m ../Hearth/HearthLibrary.h ../Hearth/HearthSaves.m ../Hearth/HearthSaves.h ../Hearth/HearthSign.m ../Hearth/HearthSign.h ../Hearth/HearthSound.m ../Hearth/HearthSound.h ../../host/boot.m ../../host/boot.h ../../host/profile.m
	clang -O1 -g -Wall -fobjc-arc -I../Hearth -I../../host -o $@ t_library.m ../Hearth/HearthErrors.m ../Hearth/HearthLibrary.m ../Hearth/HearthSaves.m ../Hearth/HearthSign.m ../Hearth/HearthSound.m ../../host/boot.m ../../host/profile.m -framework Foundation -framework Metal
t_import: t_import.m ../Hearth/HearthImport.m ../Hearth/HearthImport.h ../Hearth/HearthLibrary.m ../Hearth/HearthLibrary.h ../Hearth/HearthSign.m ../Hearth/HearthSound.m ../../host/boot.m ../../host/profile.m
	clang -O1 -g -Wall -fobjc-arc -I../Hearth -I../../host -o $@ t_import.m ../Hearth/HearthImport.m ../Hearth/HearthLibrary.m ../Hearth/HearthSign.m ../Hearth/HearthSound.m ../../host/boot.m ../../host/profile.m -framework Foundation -framework Metal -lAppleArchive
t_home_focus: t_home_focus.m ../Hearth/HearthFocus.m ../Hearth/HearthFocus.h ../Hearth/HearthTheme.h ../Sources/DmRepeat.m ../Sources/DmRepeat.h
	clang -O1 -g -Wall -fobjc-arc -I../Hearth -I../Sources -o $@ t_home_focus.m ../Hearth/HearthFocus.m ../Sources/DmRepeat.m -framework Foundation
t_users: t_users.m ../Hearth/HearthUsers.m ../Hearth/HearthUsers.h ../Hearth/HearthLibrary.h
	clang -O1 -g -Wall -fobjc-arc -I../Hearth -o $@ t_users.m ../Hearth/HearthUsers.m -framework Foundation
t_controls: t_controls.m ../Sources/DmControlMap.m ../Sources/DmControlMap.h ../Sources/DmSettings.m ../../host/keymap.c ../../host/keymap.h
	clang -O1 -g -Wall -fobjc-arc -I../Sources -I../../host -o $@ t_controls.m ../Sources/DmSettings.m ../Sources/DmControlMap.m ../../host/keymap.c -framework Foundation
t_gallery: t_gallery.m ../Hearth/HearthGallery.m ../Hearth/HearthGallery.h
	clang -O1 -g -Wall -fobjc-arc -I../Hearth -o $@ t_gallery.m ../Hearth/HearthGallery.m -framework Foundation
t_notify: t_notify.m ../Hearth/HearthNotify.m ../Hearth/HearthNotify.h
	clang -O1 -g -Wall -fobjc-arc -I../Hearth -o $@ t_notify.m ../Hearth/HearthNotify.m -framework Foundation -framework UserNotifications
PACK_ID = $(firstword $(sort $(notdir $(patsubst %/game.tsv,%,$(wildcard ../../games/*/game.tsv)))))
run: t_settings t_library t_import t_home_focus t_users t_gallery t_controls t_notify
	./t_settings
	python3 -I ../../games/game.py json $(PACK_ID) t_library.profile > /dev/null
	./t_library t_library.profile $(PACK_ID)
	./t_import t_library.profile $(PACK_ID)
	./t_home_focus
	./t_users
	./t_gallery
	./t_controls 2>/dev/null
	./t_notify
	python3 -I test_device_gpu.py   # tools/device_gpu.py chip IDs -> GPU architectures and the fallback
	python3 -I test_build_defaults.py   # tools/build_ipa.sh: chunk store by default, the offline pipeline archive in the pack
clean:
	rm -rf t_settings t_settings.dSYM t_library t_library.dSYM t_home_focus t_home_focus.dSYM t_import t_import.dSYM t_users t_users.dSYM t_gallery t_gallery.dSYM t_controls t_controls.dSYM t_notify t_notify.dSYM t_library.profile
.PHONY: run clean
