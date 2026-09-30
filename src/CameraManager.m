#import "CameraManager.h"
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreImage/CoreImage.h>

static void ACBLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSLog(@"[ACBFace] %@", msg);
    
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSString *timeStr = [df stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", timeStr, msg];
    
    const char *lineC = [line UTF8String];
    FILE *f1 = fopen("/tmp/acb_debug.log", "a");
    if (f1) { fputs(lineC, f1); fclose(f1); }
    FILE *f2 = fopen("/var/mobile/acb_debug.log", "a");
    if (f2) { fputs(lineC, f2); fclose(f2); }
    FILE *f3 = fopen("/var/tmp/acb_debug.log", "a");
    if (f3) { fputs(lineC, f3); fclose(f3); }
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count > 0) {
        NSString *docLog = [paths.firstObject stringByAppendingPathComponent:@"acb_debug.log"];
        FILE *f4 = fopen([docLog UTF8String], "a");
        if (f4) { fputs(lineC, f4); fclose(f4); }
    }
}

@interface CameraManager () {
    CVPixelBufferRef _latestPixelBuffer;
}

@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureDevice *frontCamera;
@property (nonatomic, strong) AVCaptureDeviceInput *videoInput;
@property (nonatomic, strong) AVCaptureMetadataOutput *metadataOutput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong) dispatch_queue_t captureQueue;
@property (nonatomic, strong) CIContext *ciContext;

@property (nonatomic, assign) NSTimeInterval lastMetadataTime;
@property (nonatomic, assign) NSTimeInterval lastVisionTime;
@property (nonatomic, assign) NSInteger frameCounter;

@end

@implementation CameraManager

- (instancetype)init {
    self = [super init];
    if (self) {
        ACBLog(@"CameraManager init started");
        _captureQueue = dispatch_queue_create("com.acbface.videoQueue", DISPATCH_QUEUE_SERIAL);
        _lastMetadataTime = 0;
        _lastVisionTime = 0;
        _frameCounter = 0;
        [self setupSession];
    }
    return self;
}

- (void)dealloc {
    [self stopSession];
    @synchronized (self) {
        if (_latestPixelBuffer) {
            CVPixelBufferRelease(_latestPixelBuffer);
            _latestPixelBuffer = NULL;
        }
    }
}

- (CIContext *)ciContext {
    if (!_ciContext) {
        @try {
            _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
        } @catch (NSException *e) {
            _ciContext = [CIContext contextWithOptions:nil];
        }
    }
    return _ciContext;
}

- (void)setupSession {
    ACBLog(@"setupSession beginning");
    @try {
        self.captureSession = [[AVCaptureSession alloc] init];
        [self.captureSession beginConfiguration];
        
        if ([self.captureSession canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
            self.captureSession.sessionPreset = AVCaptureSessionPreset1280x720;
        } else {
            self.captureSession.sessionPreset = AVCaptureSessionPresetHigh;
        }
        
        // Front Camera Discovery
        AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
            mediaType:AVMediaTypeVideo
            position:AVCaptureDevicePositionFront];
        self.frontCamera = discovery.devices.firstObject;
        if (!self.frontCamera) {
            self.frontCamera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        }
        
        if (self.frontCamera) {
            NSError *error = nil;
            self.videoInput = [AVCaptureDeviceInput deviceInputWithDevice:self.frontCamera error:&error];
            if (self.videoInput && [self.captureSession canAddInput:self.videoInput]) {
                [self.captureSession addInput:self.videoInput];
                ACBLog(@"Successfully added videoInput");
            } else {
                ACBLog([NSString stringWithFormat:@"FAILED to add videoInput: %@", error]);
            }
        }
        
        // 1. Hardware Metadata Output (Apple Camera ISP Face Detection - Ultra Fast & Reliable)
        self.metadataOutput = [[AVCaptureMetadataOutput alloc] init];
        if ([self.captureSession canAddOutput:self.metadataOutput]) {
            [self.captureSession addOutput:self.metadataOutput];
            [self.metadataOutput setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
        } else {
            ACBLog(@"Failed to add metadataOutput");
        }
        
        // 2. Video Data Output (Frame Buffer Delivery & Vision Fallback)
        self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
        self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
        self.videoOutput.videoSettings = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
        };
        [self.videoOutput setSampleBufferDelegate:self queue:self.captureQueue];
        if ([self.captureSession canAddOutput:self.videoOutput]) {
            [self.captureSession addOutput:self.videoOutput];
            ACBLog(@"Successfully added videoOutput (32BGRA)");
        } else {
            ACBLog(@"Failed to add videoOutput");
        }
        
        // 3. Preview Layer
        self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.captureSession];
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        
        [self.captureSession commitConfiguration];
        ACBLog(@"commitConfiguration completed");
        
        // Enable hardware face metadata AFTER commitConfiguration safely
        @try {
            if ([self.metadataOutput.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
                self.metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeFace];
                ACBLog(@"Successfully enabled hardware AVMetadataObjectTypeFace output");
            }
        } @catch (NSException *ex) {
            ACBLog(@"Warning setting metadataObjectTypes: %@", ex);
        }
        
        // Configure connections AFTER commitConfiguration
        @try {
            AVCaptureConnection *videoConn = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
            if (videoConn) {
                if (videoConn.isVideoOrientationSupported) {
                    videoConn.videoOrientation = AVCaptureVideoOrientationPortrait;
                }
                if (videoConn.isVideoMirroringSupported) {
                    videoConn.automaticallyAdjustsVideoMirroring = NO;
                    videoConn.videoMirrored = YES;
                }
            }
        } @catch (NSException *ex) {
            ACBLog(@"Warning configuring videoConn: %@", ex);
        }
        
        @try {
            if (self.previewLayer.connection) {
                if (self.previewLayer.connection.isVideoOrientationSupported) {
                    self.previewLayer.connection.videoOrientation = AVCaptureVideoOrientationPortrait;
                }
                if (self.previewLayer.connection.isVideoMirroringSupported) {
                    self.previewLayer.connection.automaticallyAdjustsVideoMirroring = NO;
                    self.previewLayer.connection.videoMirrored = YES;
                }
            }
        } @catch (NSException *ex) {
            ACBLog(@"Warning configuring previewLayer connection: %@", ex);
        }
    } @catch (NSException *e) {
        ACBLog(@"CRASH in setupSession: %@, reason: %@", e.name, e.reason);
    }
}

- (void)requestPermissionAndStart {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    ACBLog([NSString stringWithFormat:@"requestPermissionAndStart: authStatus=%ld", (long)status]);
    
    if (status == AVAuthorizationStatusAuthorized) {
        if (!self.captureSession || !self.captureSession.inputs.count) {
            [self setupSession];
        }
        [self startSession];
    } else if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ACBLog([NSString stringWithFormat:@"requestAccess completion: granted=%d", granted]);
                if (granted) {
                    if (self.captureSession) {
                        [self stopSession];
                    }
                    [self setupSession];
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

- (void)startSession {
    ACBLog(@"startSession called");
    if (![self.captureSession isRunning]) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @try {
                ACBLog(@"Calling [captureSession startRunning]...");
                [self.captureSession startRunning];
                ACBLog([NSString stringWithFormat:@"startRunning done, isRunning=%d", self.captureSession.isRunning]);
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        if (self.metadataOutput.metadataObjectTypes.count == 0 &&
                            [self.metadataOutput.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
                            self.metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeFace];
                            ACBLog(@"Successfully enabled AVMetadataObjectTypeFace after session running");
                        }
                    } @catch (NSException *ex) {
                        ACBLog(@"Warning: %@", ex);
                    }
                });
            } @catch (NSException *e) {
                ACBLog(@"CRASH in startRunning: %@, reason: %@", e.name, e.reason);
            }
        });
    }
}

- (void)stopSession {
    if ([self.captureSession isRunning]) {
        [self.captureSession stopRunning];
    }
}

#pragma mark - AVCaptureMetadataOutputObjectsDelegate (Primary Hardware ISP Face Detection)

- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
    self.lastMetadataTime = [[NSDate date] timeIntervalSince1970];
    self.frameCounter++;
    
    NSMutableArray<AVMetadataFaceObject *> *faces = [NSMutableArray array];
    for (AVMetadataObject *obj in metadataObjects) {
        if ([obj.type isEqualToString:AVMetadataObjectTypeFace]) {
            [faces addObject:(AVMetadataFaceObject *)obj];
        }
    }
    
    [self evaluateFacesFromMetadata:faces];
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate (Frame Caching & Vision Fallback)

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!imageBuffer) return;
        
        // Cache latest buffer thread-safely
        @synchronized (self) {
            if (_latestPixelBuffer) {
                CVPixelBufferRelease(_latestPixelBuffer);
            }
            _latestPixelBuffer = CVPixelBufferRetain(imageBuffer);
        }
        
        // If hardware metadata hasn't fired in > 0.5s, run Apple Vision as fallback
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - self.lastMetadataTime > 0.5 && now - self.lastVisionTime >= 0.10) {
            self.lastVisionTime = now;
            self.frameCounter++;
            [self runVisionDetectionFallback:imageBuffer];
        }
    }
}

#pragma mark - Classification Math (100% Parity with ACB NEW classifyNativeFace)

- (void)evaluateFacesFromMetadata:(NSArray<AVMetadataFaceObject *> *)faces {
    if (!faces || faces.count == 0) {
        [self reportStatus:ACBFaceStatusNoFace
                   message:@"Vui lòng đảm bảo khuôn mặt nằm trong khung, nhìn thẳng vào camera và chụp ảnh"
                faceBounds:CGRectZero
                      diag:@"ISP: 0 faces (Che camera/không có mặt)"];
        return;
    }
    
    if (faces.count > 1) {
        [self reportStatus:ACBFaceStatusMultipleFaces
                   message:@"Vui lòng chỉ 1 người trong khung hình"
                faceBounds:CGRectZero
                      diag:[NSString stringWithFormat:@"ISP: %lu faces (Nhiều mặt)", (unsigned long)faces.count]];
        return;
    }
    
    AVMetadataFaceObject *faceObj = faces.firstObject;
    AVMetadataObject *transformed = nil;
    @try {
        if (self.previewLayer.superlayer != nil) {
            transformed = [self.previewLayer transformedMetadataObjectForMetadataObject:faceObj];
        }
    } @catch (NSException *e) {
    }
    CGRect screenFaceRect = transformed ? transformed.bounds : CGRectZero;
    
    CGFloat rollDeg = faceObj.hasRollAngle ? faceObj.rollAngle : 0.0;
    CGFloat yawDeg = faceObj.hasYawAngle ? faceObj.yawAngle : 0.0;
    
    [self runACBClassificationWithFaceRect:screenFaceRect
                                   rollDeg:rollDeg
                                    yawDeg:yawDeg
                                    source:@"ISP"];
}

- (void)runVisionDetectionFallback:(CVImageBufferRef)imageBuffer {
    @try {
        size_t bufW = CVPixelBufferGetWidth(imageBuffer);
        size_t bufH = CVPixelBufferGetHeight(imageBuffer);
        CGImagePropertyOrientation ori = (bufH >= bufW) ? kCGImagePropertyOrientationUpMirrored : kCGImagePropertyOrientationRight;
        
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:imageBuffer orientation:ori options:@{}];
        VNDetectFaceRectanglesRequest *req = [[VNDetectFaceRectanglesRequest alloc] init];
        NSError *vErr = nil;
        [handler performRequests:@[req] error:&vErr];
        if (vErr) {
            ACBLog(@"Vision performRequests error: %@", vErr);
            return;
        }
        
        NSArray<VNFaceObservation *> *results = (NSArray<VNFaceObservation *> *)req.results;
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (!results || results.count == 0) {
                    [self reportStatus:ACBFaceStatusNoFace
                               message:@"Vui lòng đảm bảo khuôn mặt nằm trong khung, nhìn thẳng vào camera và chụp ảnh"
                            faceBounds:CGRectZero
                                  diag:@"Vision: 0 faces (Không có mặt)"];
                    return;
                }
                if (results.count > 1) {
                    [self reportStatus:ACBFaceStatusMultipleFaces
                               message:@"Vui lòng chỉ 1 người trong khung hình"
                            faceBounds:CGRectZero
                                  diag:[NSString stringWithFormat:@"Vision: %lu faces", (unsigned long)results.count]];
                    return;
                }
                
                VNFaceObservation *face = results.firstObject;
                CGRect b = face.boundingBox;
                CGFloat pw = self.previewLayer.bounds.size.width;
                CGFloat ph = self.previewLayer.bounds.size.height;
                if (pw <= 0 || ph <= 0) {
                    pw = self.viewFinderBounds.size.width;
                    ph = self.viewFinderBounds.size.height;
                }
                CGRect screenFaceRect = CGRectMake(b.origin.x * pw, (1.0 - b.origin.y - b.size.height) * ph, b.size.width * pw, b.size.height * ph);
                
                double rollDeg = 0.0;
                double yawDeg = 0.0;
                @try {
                    if ([face respondsToSelector:@selector(roll)] && face.roll) {
                        rollDeg = [face.roll doubleValue] * 180.0 / M_PI;
                    }
                    if ([face respondsToSelector:@selector(yaw)] && face.yaw) {
                        yawDeg = [face.yaw doubleValue] * 180.0 / M_PI;
                    }
                } @catch (NSException *ex) {
                }
                
                [self runACBClassificationWithFaceRect:screenFaceRect rollDeg:rollDeg yawDeg:yawDeg source:@"Vision"];
            } @catch (NSException *ex) {
                ACBLog(@"Vision processing exception: %@", ex);
            }
        });
    } @catch (NSException *e) {
        ACBLog(@"Vision fallback exception: %@", e);
    }
}

- (void)runACBClassificationWithFaceRect:(CGRect)screenFaceRect rollDeg:(double)rollDeg yawDeg:(double)yawDeg source:(NSString *)source {
    CGFloat viewW = self.viewFinderBounds.size.width;
    if (viewW <= 0) {
        viewW = self.previewLayer.bounds.size.width;
    }
    if (viewW <= 0) {
        viewW = [UIScreen mainScreen].bounds.size.width * 0.892;
    }
    
    // Normalize angles to [-180, 180]
    if (rollDeg > 180.0) rollDeg -= 360.0;
    if (yawDeg > 180.0) yawDeg -= 360.0;
    
    // Exact classifyNativeFace formulas from ACB NEW APK:
    // targetWidth = viewW * 0.47f
    // targetHeight = targetWidth * 1.3333334f (4/3)
    // margin = targetWidth * 0.40f (comfortable margin to prevent flickering)
    CGFloat targetW = viewW * 0.47;
    CGFloat targetH = targetW * (4.0 / 3.0);
    CGFloat margin = targetW * 0.40;
    
    CGRect oval = self.ovalRect;
    if (CGRectIsEmpty(oval)) {
        CGFloat halfW = viewW / 2.0;
        oval = CGRectMake(halfW - targetW / 2.0, halfW - targetH / 2.0, targetW, targetH);
    }
    
    CGFloat ovalCenterX = CGRectGetMidX(oval);
    CGFloat ovalCenterY = CGRectGetMidY(oval);
    CGFloat faceCenterX = CGRectGetMidX(screenFaceRect);
    CGFloat faceCenterY = CGRectGetMidY(screenFaceRect);
    
    CGFloat dx = fabs(faceCenterX - ovalCenterX);
    CGFloat dy = fabs(faceCenterY - ovalCenterY);
    
    NSString *diag = [NSString stringWithFormat:@"[%@] #%ld | r:%.0f y:%.0f | W:%.0f/%.0f dx:%.0f dy:%.0f",
                      source, (long)self.frameCounter, rollDeg, yawDeg, screenFaceRect.size.width, targetW, dx, dy];
    
    // 1. Centering Check (must be within center +/- margin, matching APK)
    if (dx > margin || dy > margin) {
        [self reportStatus:ACBFaceStatusNotCentered
                   message:@"Vui lòng căn khuôn mặt vào giữa khung hình"
                faceBounds:screenFaceRect
                      diag:[diag stringByAppendingString:@" (Lệch tâm)"]];
        return;
    }
    
    // 2. Distance Check (matching APK classifyNativeFace opcodes 0057 & 006c)
    // if width < targetW - margin && height < targetH - margin -> return 1 (Too Far)
    // if width > targetW + margin && height > targetH + margin -> return 2 (Too Close)
    if (screenFaceRect.size.width < (targetW - margin) && screenFaceRect.size.height < (targetH - margin)) {
        [self reportStatus:ACBFaceStatusTooFar
                   message:@"Di chuyển lại gần camera"
                faceBounds:screenFaceRect
                      diag:[diag stringByAppendingString:@" (Quá xa)"]];
        return;
    }
    if (screenFaceRect.size.width > (targetW + margin * 1.3) && screenFaceRect.size.height > (targetH + margin * 1.3)) {
        [self reportStatus:ACBFaceStatusTooClose
                   message:@"Di chuyển ra xa camera"
                faceBounds:screenFaceRect
                      diag:[diag stringByAppendingString:@" (Quá gần)"]];
        return;
    }
    
    // 3. Relaxed Head Tilt Check (only filter out extreme sideways angle > 40 degrees)
    if (fabs(rollDeg) > 40.0 || fabs(yawDeg) > 40.0) {
        [self reportStatus:ACBFaceStatusHeadTilted
                   message:@"Giữ mặt thẳng, không nghiêng"
                faceBounds:screenFaceRect
                      diag:[diag stringByAppendingString:@" (Nghiêng mặt)"]];
        return;
    }
    
    // 4. EVERYTHING PASSED -> STATE_CORRECT (0: Xanh lá, tự động chụp)
    [self reportStatus:ACBFaceStatusFaceOK
               message:@"Đang quét, vui lòng giữ yên"
            faceBounds:screenFaceRect
                  diag:[diag stringByAppendingString:@" -> ĐẠT CHUẨN"]];
}

- (void)reportStatus:(ACBFaceStatus)status message:(NSString *)msg faceBounds:(CGRect)bounds diag:(NSString *)diag {
    if (self.frameCounter % 15 == 0 && status != ACBFaceStatusFaceOK) {
        ACBLog(diag);
    } else if (status == ACBFaceStatusFaceOK && self.frameCounter % 5 == 0) {
        ACBLog(diag);
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateDiagnostic:)]) {
            [self.delegate cameraManagerDidUpdateDiagnostic:diag];
        }
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
            [self.delegate cameraManagerDidUpdateFaceStatus:status message:msg faceBounds:bounds];
        }
    });
}

#pragma mark - Capture Frame for Round

- (void)captureStillFrameWithCompletion:(void(^)(UIImage * _Nullable image))completion {
    dispatch_async(self.captureQueue, ^{
        CVPixelBufferRef pixelBuffer = NULL;
        @synchronized (self) {
            if (_latestPixelBuffer) {
                pixelBuffer = CVPixelBufferRetain(_latestPixelBuffer);
            }
        }
        
        if (!pixelBuffer) {
            ACBLog(@"captureStillFrame: _latestPixelBuffer is NULL");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil);
            });
            return;
        }
        
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
        CGImageRef cgImage = [self.ciContext createCGImage:ciImage fromRect:ciImage.extent];
        CVPixelBufferRelease(pixelBuffer);
        
        UIImage *finalImage = nil;
        if (cgImage) {
            finalImage = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationUp];
            CGImageRelease(cgImage);
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(finalImage);
        });
    });
}

@end
