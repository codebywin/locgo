#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "CameraManager.h"
#import "ACBUploader.h"

typedef NS_ENUM(NSInteger, ACBCaptureMode) {
    ACBCaptureModeLogin    = 0,   // Đăng nhập: 10 ảnh liên tiếp
    ACBCaptureModeRegister = 1,   // Đăng ký:   5 ảnh với khoảng cách xa/gần
};

@interface ViewController : UIViewController <CameraManagerDelegate, ACBUploaderDelegate>

@property (nonatomic, strong) NSString *cardNumber;
@property (nonatomic, strong, nullable) NSString *serverBaseUrl;
@property (nonatomic, assign) ACBCaptureMode captureMode;

@end
