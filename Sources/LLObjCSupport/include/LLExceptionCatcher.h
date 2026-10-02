#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and converts any Objective-C exception it raises into an NSError, so Swift
/// callers can treat AVFoundation's `NSInternalInconsistencyException` (e.g. "Failed to create
/// tap due to format mismatch") as a recoverable failure instead of a process abort.
/// Returns YES when the block completed without raising.
FOUNDATION_EXPORT BOOL LLCatchObjCException(void (NS_NOESCAPE ^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
