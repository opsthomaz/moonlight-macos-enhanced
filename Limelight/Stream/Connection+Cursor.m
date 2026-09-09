//
//  Connection+Cursor.m
//  Moonlight
//
//  Host cursor shape synchronization: asks Foundation Sunshine to stop drawing
//  the cursor into the video and delivers its shapes as NSCursor objects.
//

#import "Connection_Internal.h"

/// Builds an NSCursor from a tightly packed BGRA8888 bitmap in host pixels.
static NSCursor *MLCursorFromBGRA(NSData *bgra, uint16_t width, uint16_t height, int16_t hotspotX, int16_t hotspotY) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)bgra);
    CGImageRef image = CGImageCreate(width, height, 8, 32, (size_t)width * 4, colorSpace,
                                     kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    if (image == NULL) {
        return nil;
    }
    NSImage *nsImage = [[NSImage alloc] initWithCGImage:image size:NSMakeSize(width, height)];
    CGImageRelease(image);
    return [[NSCursor alloc] initWithImage:nsImage hotSpot:NSMakePoint(hotspotX, hotspotY)];
}

void ClCursorUpdate(const LI_CURSOR_UPDATE* update)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (conn == nil || callbacks == nil || update == NULL) {
        return;
    }
    if (![callbacks respondsToSelector:@selector(hostCursorUpdated:visible:)]) {
        return;
    }

    BOOL visible = (update->flags & LI_CURSOR_UPDATE_FLAG_VISIBLE) != 0;
    NSCursor *cursor = nil;
    BOOL hasShape = (update->flags & LI_CURSOR_UPDATE_FLAG_SHAPE) != 0 &&
                    update->pixels != NULL &&
                    update->width > 0 && update->height > 0 &&
                    update->pixelDataLength == (uint32_t)update->width * update->height * 4;
    if (hasShape) {
        // The buffer is only valid for the duration of this call.
        NSData *bgra = [NSData dataWithBytes:update->pixels length:update->pixelDataLength];
        cursor = MLCursorFromBGRA(bgra, update->width, update->height, update->hotspotX, update->hotspotY);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [callbacks hostCursorUpdated:cursor visible:visible];
    });
}

@implementation Connection (Cursor)

- (BOOL)setLocalCursorRendering:(BOOL)enabled {
    if (!_clipboardReady) {
        return NO;
    }
    if ((LiGetHostFeatureFlags() & LI_FF_CURSOR_SHAPE) == 0) {
        Log(LOG_I, @"[cursor] Host does not support local cursor rendering");
        return NO;
    }
    int rc = LiSetCursorMode(enabled ? LI_CURSOR_MODE_LOCAL : LI_CURSOR_MODE_VIDEO);
    if (rc != LI_CURSOR_MODE_OK) {
        Log(LOG_W, @"[cursor] LiSetCursorMode(%d) failed: %d", enabled ? 1 : 0, rc);
        return NO;
    }
    Log(LOG_I, @"[cursor] Local cursor rendering %@", enabled ? @"enabled" : @"disabled");
    return YES;
}

@end
