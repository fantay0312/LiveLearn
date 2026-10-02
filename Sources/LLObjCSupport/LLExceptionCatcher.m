#import "LLExceptionCatcher.h"

NSString * const LLObjCExceptionErrorDomain = @"LiveLearn.ObjCException";

BOOL LLCatchObjCException(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name ?: @"Objective-C exception";
            info[@"name"] = exception.name ?: @"";
            *error = [NSError errorWithDomain:LLObjCExceptionErrorDomain code:1 userInfo:info];
        }
        return NO;
    }
}
