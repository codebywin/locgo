#import "CameraManager.h"
#import <CoreVideo/CoreVideo.h>

@interface CameraManager ()
@property (nonatomic, strong) AVCaptureDeviceInput *videoInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) dispatch_queue_t captureQueue;

@property (nonatomic, assign) NSInteger consecutiveOKCount;
@property (nonatomic, assign) BOOL isCapturing;
@property (nonatomic, assign) NSInteger capturedCount;
@property (nonatomic, assign) NSTimeInterval lastCaptureTime;
@property (nonatomic, assign) NSTimeInterval lastVisionTime;
@property (nonatomic, strong) NSString *sessionDirectory;
@property (nonatomic, assign) CGImagePropertyOrientation preferredOrientation;
@end

static void ACBLog(NSString *msg) {
    static NSString *path = @"/var/mobile/Documents/acb_debug.log";
    static NSFileHandle *fh = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        }
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
        [fh seekToEndOfFile];
    });
    if (fh) {
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
        [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
    }
}

@implementation CameraManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _targetFrameCount = 10;
        _consecutiveOKCount = 0;
        _isCapturing = NO;
        _capturedCount = 0;
        _lastCaptureTime = 0;
        _lastVisionTime = 0;
        _preferredOrientation = kCGImagePropertyOrientationUpMirrored;
        _captureQueue = dispatch_queue_create("com.acbface.captureQueue", DISPATCH_QUEUE_SERIAL);
        [self setupSession];
    }
    return self;
}

- (void)requestPermissionAndStart {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusAuthorized) {
        [self startSession];
    } else if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (granted) {
                    [self startSession];
                } else {
                    if ([self.delegate respondsToSelector:@selector(cameraManagerPermissionDenied)]) {
                        [self.delegate cameraManagerPermissionDenied];
                    }
                }
            });
        }];
    } else {
        if ([self.delegate respondsToSelector:@selector(cameraManagerPermissionDenied)]) {
            [self.delegate cameraManagerPermissionDenied];
        }
    }
}

- (void)setupSession {
    self.captureSession = [[AVCaptureSession alloc] init];
    [self.captureSession beginConfiguration];
    
    if ([self.captureSession canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
        self.captureSession.sessionPreset = AVCaptureSessionPreset1280x720;
    }
    
    // Front Camera Discovery
    AVCaptureDevice *frontCamera = nil;
    if (@available(iOS 10.0, *)) {
        AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
            mediaType:AVMediaTypeVideo
            position:AVCaptureDevicePositionFront];
        for (AVCaptureDevice *device in discoverySession.devices) {
            if (device.position == AVCaptureDevicePositionFront) {
                frontCamera = device;
                break;
            }
        }
    }
    if (!frontCamera) {
        frontCamera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }
    
    if (frontCamera) {
        NSError *error = nil;
        self.videoInput = [AVCaptureDeviceInput deviceInputWithDevice:frontCamera error:&error];
        if (self.videoInput && [self.captureSession canAddInput:self.videoInput]) {
            [self.captureSession addInput:self.videoInput];
        }
    }
    
    // Video Output for Frame Grab & Vision Analysis
    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.videoOutput.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
    [self.videoOutput setSampleBufferDelegate:self queue:self.captureQueue];
    if ([self.captureSession canAddOutput:self.videoOutput]) {
        [self.captureSession addOutput:self.videoOutput];
    }
    
    // Preview Layer
    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.captureSession];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    
    // Video Connection
    AVCaptureConnection *videoConn = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (videoConn.isVideoOrientationSupported) {
        videoConn.videoOrientation = AVCaptureVideoOrientationPortrait;
    }
    
    [self.captureSession commitConfiguration];
}

- (void)startSession {
    if (![self.captureSession isRunning]) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self.captureSession startRunning];
        });
    }
}

- (void)stopSession {
    if ([self.captureSession isRunning]) {
        [self.captureSession stopRunning];
    }
}

- (void)prepareSessionDirectory {
    NSString *tempDir = NSTemporaryDirectory();
    NSString *sessionName = [NSString stringWithFormat:@"login_frames_%ld", (long)[[NSDate date] timeIntervalSince1970]];
    self.sessionDirectory = [tempDir stringByAppendingPathComponent:sessionName];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:self.sessionDirectory withIntermediateDirectories:YES attributes:nil error:nil];
}

- (void)startCapture {
    if (self.isCapturing) return;
    [self prepareSessionDirectory];
    self.capturedCount = 0;
    self.lastCaptureTime = 0;
    self.isCapturing = YES;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidStartCapturing)]) {
            [self.delegate cameraManagerDidStartCapturing];
        }
    });
}

- (void)resetCapture {
    self.isCapturing = NO;
    self.consecutiveOKCount = 0;
    self.capturedCount = 0;
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!imageBuffer) return;
        
        // 1. If actively capturing burst (10 flat frames 1.jpg ... 10.jpg)
        if (self.isCapturing) {
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            if (now - self.lastCaptureTime >= 0.10) { // 10 fps
                self.lastCaptureTime = now;
                self.capturedCount++;
                NSInteger index = self.capturedCount;
                
                CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
                CIContext *ctx = [CIContext contextWithOptions:nil];
                CGImageRef cgImage = [ctx createCGImage:ciImage fromRect:ciImage.extent];
                if (cgImage) {
                    UIImage *currentImage = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationRight];
                    CGImageRelease(cgImage);
                    
                    NSString *filePath = [self.sessionDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%ld.jpg", (long)index]];
                    NSData *jpegData = UIImageJPEGRepresentation(currentImage, 0.85);
                    [jpegData writeToFile:filePath atomically:YES];
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if ([self.delegate respondsToSelector:@selector(cameraManagerDidCaptureFrame:index:total:)]) {
                            [self.delegate cameraManagerDidCaptureFrame:currentImage index:index total:self.targetFrameCount];
                        }
                    });
                }
                
                if (self.capturedCount >= self.targetFrameCount) {
                    self.isCapturing = NO;
                    self.consecutiveOKCount = 0;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if ([self.delegate respondsToSelector:@selector(cameraManagerDidFinishCaptureWithFolder:)]) {
                            [self.delegate cameraManagerDidFinishCaptureWithFolder:self.sessionDirectory];
                        }
                    });
                }
            }
            return;
        }
        
        // 2. Real-time Apple Neural Engine Vision Face Detection (~12 fps)
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - self.lastVisionTime < 0.08) return;
        self.lastVisionTime = now;
        
        CGImagePropertyOrientation orientationsToTry[] = {
            self.preferredOrientation,
            kCGImagePropertyOrientationUpMirrored,
            kCGImagePropertyOrientationUp,
            kCGImagePropertyOrientationLeftMirrored,
            kCGImagePropertyOrientationRight
        };
        
        NSArray<VNFaceObservation *> *detectedFaces = nil;
        CGImagePropertyOrientation winningOrientation = self.preferredOrientation;
        
        for (int i = 0; i < 5; i++) {
            CGImagePropertyOrientation ori = orientationsToTry[i];
            if (i > 0 && ori == self.preferredOrientation) continue;
            
            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:imageBuffer
                                                                                       orientation:ori
                                                                                           options:@{}];
            __block NSArray<VNFaceObservation *> *results = nil;
            VNDetectFaceRectanglesRequest *faceRequest = [[VNDetectFaceRectanglesRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error) {
                results = (NSArray<VNFaceObservation *> *)request.results;
            }];
            [handler performRequests:@[faceRequest] error:nil];
            if (results && results.count > 0) {
                detectedFaces = results;
                winningOrientation = ori;
                self.preferredOrientation = ori;
                break;
            }
        }
        
        [self handleVisionFaceObservations:detectedFaces ?: @[] orientation:winningOrientation];
    }
}

#pragma mark - 100% Parity with ACB NEW LoginFaceValidator

- (void)handleVisionFaceObservations:(NSArray<VNFaceObservation *> *)observations orientation:(CGImagePropertyOrientation)usedOri {
    if (self.isCapturing) return;
    
    static NSInteger logThrottle = 0;
    BOOL shouldLog = (++logThrottle % 15 == 0);
    
    // Condition 1: Must detect exactly 1 face (When covering camera -> "Vui lòng giữ khuôn mặt trong hình")
    if (!observations || observations.count == 0) {
        self.consecutiveOKCount = 0;
        if (shouldLog) {
            ACBLog([NSString stringWithFormat:@"[FaceStatus] NO FACE detected (checked ori=%d)", (int)usedOri]);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
                [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusNoFace
                                                        message:@"Vui lòng giữ khuôn mặt trong hình"
                                                     faceBounds:CGRectZero];
            }
        });
        return;
    }
    
    if (observations.count > 1) {
        self.consecutiveOKCount = 0;
        if (shouldLog) {
            ACBLog([NSString stringWithFormat:@"[FaceStatus] MULTIPLE FACES (%lu)", (unsigned long)observations.count]);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
                [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusMultipleFaces
                                                        message:@"Vui lòng chỉ 1 người trong khung hình"
                                                     faceBounds:CGRectZero];
            }
        });
        return;
    }
    
    VNFaceObservation *face = observations.firstObject;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isCapturing) return;
        
        CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
        CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
        
        // Convert Vision normalized bounding box (bottom-left origin) to UIKit screen coordinates
        CGRect b = face.boundingBox;
        CGFloat fw = b.size.width * screenW;
        CGFloat fh = b.size.height * screenH;
        CGFloat fx = b.origin.x * screenW;
        CGFloat fy = (1.0 - b.origin.y - b.size.height) * screenH;
        CGRect screenFaceRect = CGRectMake(fx, fy, fw, fh);
        
        CGRect oval = self.ovalRect;
        if (CGRectIsEmpty(oval)) {
            oval = CGRectMake(screenW * 0.12, screenH * 0.22, screenW * 0.76, screenW * 0.76 * 1.34);
        }
        
        CGFloat faceCenterX = CGRectGetMidX(screenFaceRect);
        CGFloat faceCenterY = CGRectGetMidY(screenFaceRect);
        CGFloat ovalCenterX = CGRectGetMidX(oval);
        CGFloat ovalCenterY = CGRectGetMidY(oval);
        
        // Condition 2: Head Tilt (Roll & Yaw angle) - ACB: "Giữ mặt thẳng, không nghiêng"
        double rollDeg = 0.0;
        if (face.roll) {
            rollDeg = [face.roll doubleValue] * 180.0 / M_PI;
        }
        double yawDeg = 0.0;
        if (face.yaw) {
            yawDeg = [face.yaw doubleValue] * 180.0 / M_PI;
        }
        
        CGFloat dx = fabs(faceCenterX - ovalCenterX);
        CGFloat dy = fabs(faceCenterY - ovalCenterY);
        CGFloat widthRatio = screenFaceRect.size.width / oval.size.width;
        
        if (shouldLog) {
            ACBLog([NSString stringWithFormat:@"[FaceStatus] OK: ori=%d, roll=%.1f, yaw=%.1f, ratio=%.2f, dx=%.1f, dy=%.1f", (int)usedOri, rollDeg, yawDeg, widthRatio, dx, dy]);
        }
        
        if (fabs(rollDeg) > 20.0 || fabs(yawDeg) > 20.0) {
            self.consecutiveOKCount = 0;
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
                [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusHeadTilted
                                                        message:@"Giữ mặt thẳng, không nghiêng"
                                                     faceBounds:screenFaceRect];
            }
            return;
        }
        
        // Condition 3: Centered inside Oval (tolerance: 40% of oval dimensions)
        if (dx > oval.size.width * 0.40 || dy > oval.size.height * 0.40) {
            self.consecutiveOKCount = 0;
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
                [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusNotCentered
                                                        message:@"Vui lòng đưa mặt vào giữa khung hình"
                                                     faceBounds:screenFaceRect];
            }
            return;
        }
        
        // Condition 4: Distance (classifyDistance: ratio faceW / ovalW from 0.35 to 1.05)
        if (widthRatio < 0.35) {
            self.consecutiveOKCount = 0;
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
                [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusTooFar
                                                        message:@"Vui lòng tiến lại gần hơn"
                                                     faceBounds:screenFaceRect];
            }
            return;
        }
        if (widthRatio > 1.05) {
            self.consecutiveOKCount = 0;
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
                [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusTooClose
                                                        message:@"Vui lòng lùi ra xa hơn"
                                                     faceBounds:screenFaceRect];
            }
            return;
        }
        
        // === ALL CONDITIONS PASSED (FACE_OK) ===
        self.consecutiveOKCount++;
        
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
            [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusFaceOK
                                                    message:@"Đang quét, vui lòng giữ yên"
                                                 faceBounds:screenFaceRect];
        }
        
        // Automatic trigger: require 2 consecutive qualified frames (~0.2s)
        if (self.consecutiveOKCount >= 2) {
            [self startCapture];
        }
    });
}

@end
