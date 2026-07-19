#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block, converting any thrown Objective-C exception into an NSError.
/// Returns nil on success; never lets an exception propagate to (Swift) callers.
FOUNDATION_EXPORT NSError *_Nullable LFCatchException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
