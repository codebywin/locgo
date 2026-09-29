#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

@protocol CameraManagerDelegate <NSObject>
@optional
- (void)cameraManagerDidDetectFace:(CGRect)normalizedFaceBounds isCentered:(BOOL)centered isDistanceQualified:(BOOL)qualified distanceRatio:(CGFloat)ratio;
- (void)cameraManagerDidCaptureFrame:(UIImage *)image index:(NSInteger)index total:(NSInteger)total;
- (void)cameraManagerDidFinishCaptureWithFolder:(NSString *)folderPath;
@end

@interface CameraManager : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate>

@property (nonatomic, weak) id<CameraManagerDelegate> delegate;
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, assign) BOOL isAutoCaptureActive;
@property (nonatomic, assign) NSInteger targetFrameCount; // Mac dinh: 10 frames

- (instancetype)init;
- (void)startSession;
- (void)stopSession;
- (void)startAutoCapture;
- (void)resetCapture;

@end
