#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ACBFaceStatus) {
    ACBFaceStatusNoFace = 0,         // "Vui lòng đảm bảo khuôn mặt nằm trong khung, nhìn thẳng vào camera và chụp ảnh"
    ACBFaceStatusMultipleFaces,      // "Vui lòng chỉ 1 người trong khung hình"
    ACBFaceStatusNotCentered,        // "Vui lòng đảm bảo khuôn mặt nằm trong khung, nhìn thẳng vào camera và chụp ảnh"
    ACBFaceStatusTooFar,             // "Di chuyển lại gần camera"
    ACBFaceStatusTooClose,           // "Di chuyển ra xa camera"
    ACBFaceStatusHeadTilted,         // "Giữ mặt thẳng, không nghiêng"
    ACBFaceStatusFaceOK              // "Đang quét, vui lòng giữ yên"
};

@protocol CameraManagerDelegate <NSObject>
@optional
- (void)cameraManagerDidUpdateFaceStatus:(ACBFaceStatus)status
                                 message:(NSString *)message
                              faceBounds:(CGRect)screenRect;
- (void)cameraManagerDidUpdateDiagnostic:(NSString *)diagnosticInfo;
- (void)cameraManagerPermissionDenied;
@end

@interface CameraManager : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, weak, nullable) id<CameraManagerDelegate> delegate;
@property (nonatomic, strong, readonly) AVCaptureSession *captureSession;
@property (nonatomic, strong, readonly) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, assign) CGRect ovalRect;
@property (nonatomic, assign) CGRect viewFinderBounds;

- (instancetype)init;
- (void)requestPermissionAndStart;
- (void)startSession;
- (void)stopSession;
- (void)captureStillFrameWithCompletion:(void(^)(UIImage * _Nullable image))completion;

@end

NS_ASSUME_NONNULL_END

