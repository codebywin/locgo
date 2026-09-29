#import "CameraManager.h"
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>

@interface CameraManager ()
@property (nonatomic, strong) AVCaptureDeviceInput *videoInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) dispatch_queue_t captureQueue;
@property (nonatomic, strong) CIContext *ciContext;

@property (nonatomic, assign) NSInteger consecutiveOKCount;
@property (nonatomic, assign) BOOL isCapturing;
@property (nonatomic, assign) NSInteger capturedCount;
@property (nonatomic, assign) NSTimeInterval lastCaptureTime;
@property (nonatomic, assign) NSTimeInterval lastVisionTime;
@property (nonatomic, strong) NSString *sessionDirectory;
@property (nonatomic, assign) CGImagePropertyOrientation preferredOrientation;
@property (nonatomic, assign) NSInteger frameCounter;
@end

static void ACBLog(NSString *msg) {
    NSLog(@"[ACBFace] %@", msg);
    
    time_t t = time(NULL);
    char tbuf[32];
    strftime(tbuf, sizeof(tbuf), "%H:%M:%S", localtime(&t));
    NSString *line = [NSString stringWithFormat:@"[%s] %@\n", tbuf, msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    
    NSArray *paths = @[
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"acb_debug.log"],
        @"/var/mobile/acb_debug.log"
    ];
    
    for (NSString *path in paths) {
        @try {
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            if (handle) {
                [handle seekToEndOfFile];
                [handle writeData:data];
                [handle closeFile];
            } else {
                [data writeToFile:path atomically:YES];
            }
        } @catch (NSException *e) {}
    }
}

@implementation CameraManager

- (instancetype)init {
    self = [super init];
    if (self) {
        ACBLog(@"CameraManager init started");
        _targetFrameCount = 10;
        _consecutiveOKCount = 0;
        _isCapturing = NO;
        _capturedCount = 0;
        _lastCaptureTime = 0;
        _lastVisionTime = 0;
        _frameCounter = 0;
        _preferredOrientation = kCGImagePropertyOrientationUpMirrored;
        _captureQueue = dispatch_queue_create("com.acbface.captureQueue", DISPATCH_QUEUE_SERIAL);
        [self setupSession];
    }
    return self;
}

- (CIContext *)ciContext {
    if (!_ciContext) {
        @try {
            _ciContext = [CIContext contextWithOptions:nil];
        } @catch (NSException *e) {
            ACBLog([NSString stringWithFormat:@"CIContext init exception: %@", e]);
        }
    }
    return _ciContext;
}

- (void)requestPermissionAndStart {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    ACBLog([NSString stringWithFormat:@"requestPermissionAndStart: authStatus=%ld", (long)status]);
    if (status == AVAuthorizationStatusAuthorized) {
        [self startSession];
    } else if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ACBLog([NSString stringWithFormat:@"requestAccess completion: granted=%d", granted]);
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
    ACBLog(@"setupSession beginning");
    self.captureSession = [[AVCaptureSession alloc] init];
    [self.captureSession beginConfiguration];
    
    if ([self.captureSession canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
        self.captureSession.sessionPreset = AVCaptureSessionPreset1280x720;
    } else {
        self.captureSession.sessionPreset = AVCaptureSessionPresetHigh;
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
    
    ACBLog([NSString stringWithFormat:@"frontCamera: %@", frontCamera ? frontCamera.localizedName : @"NONE"]);
    
    if (frontCamera) {
        NSError *error = nil;
        self.videoInput = [AVCaptureDeviceInput deviceInputWithDevice:frontCamera error:&error];
        if (error) {
            ACBLog([NSString stringWithFormat:@"deviceInput error: %@", error]);
        }
        if (self.videoInput && [self.captureSession canAddInput:self.videoInput]) {
            [self.captureSession addInput:self.videoInput];
            ACBLog(@"Successfully added videoInput");
        } else {
            ACBLog(@"FAILED to add videoInput");
        }
    }
    
    // Video Output for Frame Grab & Vision Analysis
    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.videoOutput.alwaysDiscardsLateVideoFrames = NO;
    
    if ([self.captureSession canAddOutput:self.videoOutput]) {
        [self.captureSession addOutput:self.videoOutput];
        ACBLog(@"Successfully added videoOutput");
    } else {
        ACBLog(@"FAILED to add videoOutput");
    }
    
    [self.videoOutput setSampleBufferDelegate:self queue:self.captureQueue];
    ACBLog([NSString stringWithFormat:@"availablePixelFormats: %@", self.videoOutput.availableVideoCVPixelFormatTypes]);
    
    // Preview Layer
    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.captureSession];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    
    [self.captureSession commitConfiguration];
    ACBLog(@"commitConfiguration completed");
    
    // Video Connection (must be configured AFTER commitConfiguration)
    AVCaptureConnection *videoConn = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (videoConn) {
        ACBLog([NSString stringWithFormat:@"videoConn exists, isOriSupported=%d, isEnabled=%d, isActive=%d", 
                videoConn.isVideoOrientationSupported, videoConn.isEnabled, videoConn.isActive]);
        if (videoConn.isVideoOrientationSupported) {
            videoConn.videoOrientation = AVCaptureVideoOrientationPortrait;
        }
    } else {
        ACBLog(@"videoConn is NIL after commitConfiguration!");
    }
    
    // Preview Connection
    if (self.previewLayer.connection && self.previewLayer.connection.isVideoOrientationSupported) {
        self.previewLayer.connection.videoOrientation = AVCaptureVideoOrientationPortrait;
    }
}

- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    static NSInteger dropCount = 0;
    if (++dropCount % 20 == 1) {
        CFStringRef reason = CMGetAttachment(sampleBuffer, kCMSampleBufferAttachmentKey_DroppedFrameReason, NULL);
        ACBLog([NSString stringWithFormat:@"[DROPPED FRAME] count=%ld, reason=%@", (long)dropCount, reason]);
    }
}

- (void)startSession {
    ACBLog(@"startSession called");
    if (![self.captureSession isRunning]) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            ACBLog(@"Calling [captureSession startRunning]...");
            [self.captureSession startRunning];
            ACBLog([NSString stringWithFormat:@"startRunning done, isRunning=%d", self.captureSession.isRunning]);
        });
    } else {
        ACBLog(@"captureSession already running");
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
        static NSInteger totalFrameCounter = 0;
        if (++totalFrameCounter % 30 == 1) {
            ACBLog([NSString stringWithFormat:@"[FRAME DELIVERED] #%ld (isCapturing=%d)", (long)totalFrameCounter, self.isCapturing]);
        }
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
                CGImageRef cgImage = [self.ciContext createCGImage:ciImage fromRect:ciImage.extent];
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
        self.frameCounter++;
        
        size_t bufW = CVPixelBufferGetWidth(imageBuffer);
        size_t bufH = CVPixelBufferGetHeight(imageBuffer);
        
        static BOOL loggedFirst = NO;
        if (!loggedFirst) {
            loggedFirst = YES;
            ACBLog([NSString stringWithFormat:@"CaptureOutput active! Frame: %zux%zu, connOri=%ld", bufW, bufH, (long)connection.videoOrientation]);
        }
        
        CGImagePropertyOrientation orientationsToTry[3];
        int oriCount = 0;
        
        if (self.preferredOrientation > 0) {
            orientationsToTry[oriCount++] = self.preferredOrientation;
        }
        
        if (bufH >= bufW) { // Portrait buffer
            if (self.preferredOrientation != kCGImagePropertyOrientationUpMirrored) {
                orientationsToTry[oriCount++] = kCGImagePropertyOrientationUpMirrored;
            }
            if (self.preferredOrientation != kCGImagePropertyOrientationUp) {
                orientationsToTry[oriCount++] = kCGImagePropertyOrientationUp;
            }
        } else { // Landscape buffer
            if (self.preferredOrientation != kCGImagePropertyOrientationLeftMirrored) {
                orientationsToTry[oriCount++] = kCGImagePropertyOrientationLeftMirrored;
            }
            if (self.preferredOrientation != kCGImagePropertyOrientationRight) {
                orientationsToTry[oriCount++] = kCGImagePropertyOrientationRight;
            }
        }
        
        NSArray<VNFaceObservation *> *detectedFaces = nil;
        CGImagePropertyOrientation winningOrientation = self.preferredOrientation ?: kCGImagePropertyOrientationUpMirrored;
        
        for (int i = 0; i < oriCount; i++) {
            CGImagePropertyOrientation ori = orientationsToTry[i];
            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:imageBuffer
                                                                                       orientation:ori
                                                                                           options:@{}];
            VNDetectFaceRectanglesRequest *faceRequest = [[VNDetectFaceRectanglesRequest alloc] init];
            [handler performRequests:@[faceRequest] error:nil];
            NSArray<VNFaceObservation *> *results = (NSArray<VNFaceObservation *> *)faceRequest.results;
            if (results && results.count > 0) {
                detectedFaces = results;
                winningOrientation = ori;
                self.preferredOrientation = ori;
                break;
            }
        }
        
        [self handleVisionFaceObservations:detectedFaces ?: @[] orientation:winningOrientation bufW:bufW bufH:bufH];
    }
}

#pragma mark - 100% Parity with ACB NEW LoginFaceValidator

- (void)handleVisionFaceObservations:(NSArray<VNFaceObservation *> *)observations orientation:(CGImagePropertyOrientation)usedOri bufW:(size_t)bufW bufH:(size_t)bufH {
    if (self.isCapturing) return;
    
    // Condition 1: Must detect exactly 1 face (When covering camera -> "Vui lòng giữ khuôn mặt trong hình")
    if (!observations || observations.count == 0) {
        self.consecutiveOKCount = 0;
        NSString *diag = [NSString stringWithFormat:@"Frames: %ld | KHÔNG CÓ KHUÔN MẶT (ĐANG CHE)", (long)self.frameCounter];
        if (self.frameCounter % 15 == 0) {
            ACBLog(diag);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateDiagnostic:)]) {
                [self.delegate cameraManagerDidUpdateDiagnostic:diag];
            }
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
        NSString *diag = [NSString stringWithFormat:@"Frames: %ld | PHÁT HIỆN NHIỀU MẶT (%lu)", (long)self.frameCounter, (unsigned long)observations.count];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateDiagnostic:)]) {
                [self.delegate cameraManagerDidUpdateDiagnostic:diag];
            }
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
        
        NSString *diag = [NSString stringWithFormat:@"Frames: %ld | roll:%.0f° yaw:%.0f° | ratio:%.2f dx:%.0f dy:%.0f", 
                          (long)self.frameCounter, rollDeg, yawDeg, widthRatio, dx, dy];
        if (self.frameCounter % 15 == 0) {
            ACBLog(diag);
        }
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateDiagnostic:)]) {
            [self.delegate cameraManagerDidUpdateDiagnostic:diag];
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
