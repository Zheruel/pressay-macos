#import "include/LocalFlowObjCShim.h"

NSError *_Nullable LFCatchException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:@"dev.localflow.objc-exception"
                                   code:1
                               userInfo:@{
                                   NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                                   @"name": exception.name,
                               }];
    } @catch (id other) {
        return [NSError errorWithDomain:@"dev.localflow.objc-exception"
                                   code:2
                               userInfo:@{
                                   NSLocalizedDescriptionKey: @"Unknown Objective-C object thrown",
                               }];
    }
}
