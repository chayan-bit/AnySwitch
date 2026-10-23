// album: the capture album (Monster Hunter Rise saves its own photo-mode pictures there). Initialize connects to the capture service (capsrv, an abort in sm::Initialize at the start of
// nnMain, main+0x6bc5478). A game's own picture goes to the front end (front_album_save: Hearth's Gallery on iOS), a screenshot of the current frame to front_capture; the Mac has neither and fails as before.
// GetImageWidth / GetImageHeight only compute and keep running in the SDK. Tests: dm/host/tests/t_album.c
#include "hle.h"
#include "dm.h"
#include "front.h"
#include <stdint.h>

int dm_guest_as_contains(uintptr_t a);   // hle_svc.c

#ifndef T_ALBUM
__attribute__((weak)) int front_album_save(const void *rgba, int w, int h) { (void)rgba; (void)w; (void)h; return -1; }   // no front end: no album
__attribute__((weak)) int front_capture(void) { return -1; }
#endif

// nn::album::ImageSize: 0 = 1280x720, the only size the SDK's SaveScreenshot takes for a game's own picture (RGBA8, 4 bytes a pixel).
// shortcut: other sizes are refused, accept them when a game is seen passing one
Result dm_album_save(const void *p, size_t n, int size) {
    const int w = 1280, h = 720;
    if (size != 0 || n < (size_t)w * h * 4 || !p || !dm_guest_as_contains((uintptr_t)p) || !dm_guest_as_contains((uintptr_t)p + (size_t)w * h * 4 - 1)) {
        LOG("[RED] album::SaveScreenshot refused: size %d, %zu bytes at %p", size, n, p); return RES_FAIL;
    }
    int r = front_album_save(p, w, h);
    LOG("album::SaveScreenshot %dx%d: %s", w, h, r == 0 ? "saved to the Gallery" : "no album");
    return r == 0 ? 0 : RES_FAIL;
}

HLE_FORCE("_ZN2nn5album10InitializeEv", "capture album init (capsrv); pictures go to the front end, no-op", void, h_album_Init, void) {}
HLE_FORCE("_ZN2nn5album8FinalizeEv", "capture album", void, h_album_Fini, void) {}
HLE_FORCE("_ZN2nn5album14SaveScreenshotEPKvmNS0_9ImageSizeENS0_16ImageOrientationENS0_17AlbumReportOptionE", "save a picture to the album: the front end's Gallery (front_album_save)", Result, h_album_Save,
          const void *p, size_t n, int size, int orient, int report) { (void)orient; (void)report; return dm_album_save(p, n, size); }
HLE_FORCE("_ZN2nn5album22SaveAndShareScreenshotEPKvmNS0_9ImageSizeENS0_16ImageOrientationENS0_17AlbumReportOptionERKNS_7account3UidEPKc", "save and share a picture: saved to the Gallery, nothing is shared", Result, h_album_Share,
          const void *p, size_t n, int size, int orient, int report, const void *uid, const char *text) { (void)orient; (void)report; (void)uid; (void)text; return dm_album_save(p, n, size); }
HLE_FORCE("_ZN2nn5album14ShowAlbumFilesEv", "album applet: not shown", Result, h_album_Show, void) { return RES_FAIL; }
// Pokémon Legends: Z-A (SDK 19): a screenshot of the current frame, taken by the capture service
HLE_FORCE("_ZN2nn5album21SaveCurrentScreenshotENS0_17AlbumReportOptionE", "screenshot of the current frame: the front end's capture (front_capture)", Result, h_album_SaveCur, int report) {
    (void)report; int r = front_capture();
    LOG("album::SaveCurrentScreenshot: %s", r == 0 ? "taken" : "no album");
    return r == 0 ? 0 : RES_FAIL;
}
