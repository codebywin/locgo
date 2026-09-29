#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, ACBFaceStatus) {
    ACBFaceStatusNoFace = 0,         // "Vui lòng giữ khuôn mặt trong hình"
    ACBFaceStatusMultipleFaces,      // "Vui lòng chỉ 1 người trong khung hình"
    ACBFaceStatusNotCentered,        // "Vui lòng đưa mặt vào giữa khung hình"
    ACBFaceStatusTooFar,             // "Vui lòng tiến lại gần hơn"
    ACBFaceStatusTooClose,           // "Vui lòng lùi ra xa hơn"
    ACBFaceStatusHeadTilted,         // "Giữ mặt thẳng, không nghiêng"
    ACBFaceStatusEyesClosed,         // "Vui lòng mở to mắt"
    ACBFaceStatusSmiling,            // "Vui lòng giữ nét mặt tự nhiên"
    ACBFaceStatusFaceOK              // "Đang quét, vui lòng giữ yên"
};

@protocol CameraManagerDelegate <NSObject>
@optional
- (void)cameraManagerDidUpdateFaceStatus:(ACBFaceStatus)status
                                 message:(NSString *)message
                              faceBounds:(CGRect)screenRect;
- (void)cameraManagerDidUpdateDiagnostic:(NSString *)diagnosticInfo;
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
