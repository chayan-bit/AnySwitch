// Hearth's Controllers page (plan-hearth-p3.md 5.1), from Home's Controllers button: what is connected, pairing help (no brand names: the system's own controller names are data),
// the controller's and the keyboard's buttons (DmControlMap.h), Test input, and the touch controls' rows. Each controller is a player of its own (the Players page: all as player 1, press a button to join); the keyboard and the touch controls play as player 1.
#import "DmSettingsVC.h"

DmSettingsVC *hearth_controllers(CGSize size);   // the caller sets onClose and onRestart and shows it, as with System Settings
