#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AVAudioNode's `installTapOnBus:bufferSize:format:block:` raises an
/// `NSException` when the underlying CoreAudio device has been grabbed
/// exclusively by another app (e.g. GarageBand opening for exclusive
/// I/O). Swift can't `@catch` Obj-C exceptions, so unwinding goes straight
/// past Swift and triggers `abort()` in `__cxa_throw`. This shim wraps a
/// block in `@try/@catch` and converts any caught exception into an
/// `NSError` the caller can branch on.
@interface ObjcExceptionGuard : NSObject

+ (BOOL)catchExceptionFromBlock:(NS_NOESCAPE void (^)(void))block
                          error:(NSError * _Nullable __autoreleasing * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
