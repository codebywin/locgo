#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, ACBFaceStatus) {
    ACBFaceStatusNoFace = 0,         // "Vui lòng đưa khuôn mặt vào trong khung hình"
    ACBFaceStatusMultipleFaces,      // "Vui lòng chỉ 1 người trong khung hình"
    ACBFaceStatusNotCentered,        // "Vui lòng đưa mặt vào giữa khung hình"
    ACBFaceStatusTooFar,             // "Vui lòng tiến lại gần hơn chút"
    ACBFaceStatusTooClose,           // "Vui lòng lùi ra xa hơn chút"
    ACBFaceStatusHeadTilted,         // "Vui lòng nhìn thẳng vào màn hình"
    ACBFaceStatusEyesClosed,         // "Vui lòng mở to mắt"
    ACBFaceStatusSmiling,            // "Vui lòng giữ nét mặt tự nhiên"
    ACBFaceStatusFaceOK              // "ĐÃ ĐẠT CHUẨN - GIỮ NGUYÊN KHUÔN MẶT"
};

@protocol CameraManagerDelegate <NSObject>
@optional
- (void)cameraManagerDidUpdateFaceStatus:(ACBFaceStatus)status
                                 message:(NSString *)message
                              faceBounds:(CGRect)screenRect;
- (void)cameraManagerDidStartCapturing;
- (void)cameraManagerDidCaptureFrame:(UIImage *)image index:(NSInteger)index total:(NSInteger)total;
- (void)cameraManagerDidFinishCaptureWithFolder:(NSString *)folderPath;
- (void)cameraManagerPermissionDenied;
@end

@interface CameraManager : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, weak) id<CameraManagerDelegate> delegate;
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, assign) CGRect ovalRect;
@property (nonatomic, assign) NSInteger targetFrameCount;

- (instancetype)init;
- (void)requestPermissionAndStart;
- (void)startSession;
- (void)stopSession;
- (void)startCapture;
- (void)resetCapture;

@end
