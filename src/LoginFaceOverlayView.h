#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 100% Visual and Mathematical clone of ACB NEW LoginFaceOverlayView
 * 
 * Status codes matching ACB NEW APK:
 * 0 = STATE_CORRECT (#28FA63 Green)
 * 1 = STATE_TOO_FAR (#FF5722 Orange)
 * 2 = STATE_TOO_CLOSE (#FF5722 Orange)
 * 3 = STATE_NOT_CENTERED / DEFAULT (#03A9F4 Blue)
 * 4 = STATE_MULTI_FACE (#FF5722 Orange)
 */
@interface LoginFaceOverlayView : UIView

@property (nonatomic, assign) NSInteger acbStatus;
@property (nonatomic, assign, readonly) CGRect ovalRect;

- (void)setAcbStatus:(NSInteger)status;

@end

NS_ASSUME_NONNULL_END

