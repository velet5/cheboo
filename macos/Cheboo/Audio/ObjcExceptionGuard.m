#import "ObjcExceptionGuard.h"

@implementation ObjcExceptionGuard

+ (BOOL)catchExceptionFromBlock:(NS_NOESCAPE void (^)(void))block
                          error:(NSError * _Nullable __autoreleasing * _Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: @"Unknown audio error";
            info[@"name"] = exception.name ?: @"NSException";
            if (exception.userInfo) {
                info[@"userInfo"] = exception.userInfo;
            }
            *error = [NSError errorWithDomain:@"ObjcException" code:-1 userInfo:info];
        }
        return NO;
    }
}

@end
