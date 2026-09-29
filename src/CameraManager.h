#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>

@protocol CameraManagerDelegate <NSObject>
@optional
- (void)cameraManagerDidDetectFace:(CGRect)screenFaceBounds isCentered:(BOOL)centered isDistanceQualified:(BOOL)qualified distanceRatio:(CGFloat)ratio;
- (void)cameraManagerDidCaptureFrame:(UIImage *)image index:(NSInteger)index total:(NSInteger)total;
- (void)cameraManagerDidFinishCaptureWithFolder:(NSString *)folderPath;
- (void)cameraManagerPermissionDenied;
@end

@interface CameraManager : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate>

@property (nonatomic, weak) id<CameraManagerDelegate> delegate;
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, assign) BOOL isAutoCaptureActive;
@property (nonatomic, assign) NSInteger targetFrameCount; // Mặc định: 10 frames

- (instancetype)init;
- (void)requestPermissionAndStart;
- (void)startSession;
- (void)stopSession;
- (void)startAutoCapture;
- (void)triggerManualCapture;
- (void)resetCapture;

@end
