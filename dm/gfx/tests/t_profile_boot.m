// The graphics tests and tools run with the game profile GAME names, as the host has it after boot: the Makefile writes it to build/game.json (dm/games/game.py json)
// and this constructor loads it before main. DM_PROFILE_DIR names another folder holding a game.json
#include "../../host/dm.h"
__attribute__((constructor)) static void t_profile_boot(void) { dm_profile_load(getenv("DM_PROFILE_DIR") ?: T_PROFILE_DIR); }
