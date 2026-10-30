#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Isolates the unsupported CoreBrightness API. All calls must be on the main thread.
@interface DDWarmthClient : NSObject
@property(nonatomic, readonly) BOOL supported;
@property(nonatomic, readonly, copy) NSString *diagnostic;
- (nullable NSDictionary<NSString *, NSNumber *> *)readState;
- (BOOL)changeEnabled:(BOOL)enabled;
- (BOOL)changeStrength:(float)strength;
@end
NS_ASSUME_NONNULL_END
