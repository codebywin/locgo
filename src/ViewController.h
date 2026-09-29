#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "CameraManager.h"
#import "ACBUploader.h"

@interface ViewController : UIViewController <CameraManagerDelegate, ACBUploaderDelegate>

@property (nonatomic, strong) NSString *cardNumber;
@property (nonatomic, strong, nullable) NSString *serverBaseUrl;

@end
