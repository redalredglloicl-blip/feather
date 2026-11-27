//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#include "MachOUtils.h"
#include "iconPoc.h"
// Zenith container: LCUtils.h exposes +setCertificatePassword:
// (and +certificateData) to Swift so the certificate adapter
// can mirror the selected cert's password into the LC stores
// (LCUtils.h itself only imports vendored headers + UIKit).
#include "LCUtils.h"
// Zenith container: LCAppInfo.h exposes LCAppInfo
// (initWithBundlePath: + patchExecAndSignIfNeed) to Swift so
// ZenithGuestImporter can patch + sign an imported guest.
#include "LCAppInfo.h"
