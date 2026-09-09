//
//  Connection+Clipboard.m
//  Moonlight
//
//  Clipboard frame transport over the Foundation Sunshine control stream.
//

#import "Connection_Internal.h"

@implementation Connection (Clipboard)

void ClClipboardData(const char* data, int length)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (conn == nil || callbacks == nil || data == NULL || length <= 0) {
        return;
    }

    // The buffer is only valid for the duration of this call.
    MLClipboardFrame *frame = [MLClipboardFrame frameFromData:[NSData dataWithBytes:data length:(NSUInteger)length]];
    if (frame == nil) {
        Log(LOG_W, @"[clipboard] Dropping malformed clipboard frame (%d bytes)", length);
        return;
    }
    Log(LOG_I, @"[clipboard] Frame received: kind=%u token=%u length=%lu",
        frame.kind, frame.token, (unsigned long)frame.payload.length);

    if ([callbacks respondsToSelector:@selector(clipboardFrameReceived:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [callbacks clipboardFrameReceived:frame];
        });
    }
}

- (BOOL)sendClipboardFrame:(MLClipboardFrame *)frame {
    if (frame == nil || !_clipboardReady) {
        return NO;
    }
    NSData *bytes = frame.encodedData;
    int rc = LiSendClipboardData(bytes.bytes, (int)bytes.length);
    if (rc != 0) {
        Log(LOG_D, @"[clipboard] LiSendClipboardData(%lu bytes) -> %d", (unsigned long)bytes.length, rc);
        return NO;
    }
    return YES;
}

@end
