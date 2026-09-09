#import "MLHdrMode.h"

MLHdrMode MLHdrModeForPreference(BOOL enableHdr, NSInteger hdrTransferFunction) {
    if (!enableHdr) {
        return MLHdrModeSDR;
    }
    return hdrTransferFunction == 2 ? MLHdrModeHLG : MLHdrModePQ;
}
