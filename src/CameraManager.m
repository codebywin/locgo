#import "CameraManager.h"
#import "ACBLogger.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>

static UIImage * _Nullable ImageFromPixelBuffer(CVPixelBufferRef pixelBuffer) {
    if (!pixelBuffer) return nil;
    
    size_t w = CVPixelBufferGetWidth(pixelBuffer);
    size_t h = CVPixelBufferGetHeight(pixelBuffer);
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    if (w == 0 || h == 0) return nil;
    
    ACBLog([NSString stringWithFormat:@"ImageFromPixelBuffer: %zux%zu, format='%.4s' (0x%08x)", 
            w, h, (const char*)&pixelFormat, pixelFormat]);
    
    UIImageOrientation orientation = (w > h) ? UIImageOrientationLeftMirrored : UIImageOrientationUp;
    
    // Path 1: CIImage -> CIContext (GPU accelerated Metal conversion, handles both BGRA & 420v/NV12)
    @try {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pixelBuffer];
        if (ci) {
            static CIContext *sharedCIContext = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                sharedCIContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @(NO)}];
            });
            CGImageRef cg = [sharedCIContext createCGImage:ci fromRect:ci.extent];
            if (cg) {
                UIImage *img = [UIImage imageWithCGImage:cg scale:1.0 orientation:orientation];
                CGImageRelease(cg);
                return img;
            }
        }
    } @catch (NSException *ex) {
        ACBLog(@"ImageFromPixelBuffer CIContext exception: %@", ex);
    }
    
    // Path 2: VideoToolbox hardware conversion
    @try {
        CGImageRef vtCg = NULL;
        OSStatus status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, NULL, &vtCg);
        if (status == noErr && vtCg) {
            UIImage *img = [UIImage imageWithCGImage:vtCg scale:1.0 orientation:orientation];
            CGImageRelease(vtCg);
            ACBLog(@"ImageFromPixelBuffer: SUCCESS via VideoToolbox");
            return img;
        } else {
            ACBLog([NSString stringWithFormat:@"ImageFromPixelBuffer VT failed: status=%d", (int)status]);
        }
    } @catch (NSException *ex) {
        ACBLog(@"ImageFromPixelBuffer VT exception: %@", ex);
    }
    
    // Path 3: Manual BGRA conversion (fallback for 32BGRA format)
    if (pixelFormat == kCVPixelFormatType_32BGRA) {
        @try {
            CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
            void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
            size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
            
            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
            CGContextRef context = CGBitmapContextCreate(baseAddress, w, h, 8, bytesPerRow,
                                                         colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
            CGColorSpaceRelease(colorSpace);
            
            if (context) {
                CGImageRef cgImage = CGBitmapContextCreateImage(context);
                CGContextRelease(context);
                CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
                
                if (cgImage) {
                    UIImage *img = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:orientation];
                    CGImageRelease(cgImage);
                    ACBLog(@"ImageFromPixelBuffer: SUCCESS via manual BGRA conversion");
                    return img;
                }
            } else {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
            }
        } @catch (NSException *ex) {
            ACBLog(@"ImageFromPixelBuffer manual BGRA exception: %@", ex);
        }
    }
    
    ACBLog(@"ImageFromPixelBuffer: ALL PATHS FAILED");
    return nil;
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

@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, strong) dispatch_queue_t metadataQueue;

@property (nonatomic, assign) NSInteger frameCounter;
@property (nonatomic, assign) NSInteger sampleBufferCounter;
@property (nonatomic, assign) BOOL isCapturePending;

@end

@implementation CameraManager

- (instancetype)init {
    self = [super init];
    if (self) {
        ACBLog(@"CameraManager init started");
        _frameCounter = 0;
        _sampleBufferCounter = 0;
        _isCapturePending = NO;
        _videoQueue = dispatch_queue_create("com.acbface.videoQueue", DISPATCH_QUEUE_SERIAL);
        _metadataQueue = dispatch_queue_create("com.acbface.metadataQueue", DISPATCH_QUEUE_SERIAL);
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

- (void)setupSession {
    ACBLog(@"setupSession beginning");
    @try {
        self.captureSession = [[AVCaptureSession alloc] init];
        [self.captureSession beginConfiguration];
        
        if ([self.captureSession canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
            self.captureSession.sessionPreset = AVCaptureSessionPreset1280x720;
            ACBLog(@"Session preset configured to AVCaptureSessionPreset1280x720");
        } else if ([self.captureSession canSetSessionPreset:AVCaptureSessionPreset640x480]) {
            self.captureSession.sessionPreset = AVCaptureSessionPreset640x480;
            ACBLog(@"Session preset configured to AVCaptureSessionPreset640x480");
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
        
        // 1. Hardware Metadata Output (Apple Camera ISP Face Detection on metadataQueue)
        self.metadataOutput = [[AVCaptureMetadataOutput alloc] init];
        if ([self.captureSession canAddOutput:self.metadataOutput]) {
            [self.captureSession addOutput:self.metadataOutput];
            [self.metadataOutput setMetadataObjectsDelegate:self queue:self.metadataQueue];
            ACBLog(@"Successfully added metadataOutput on metadataQueue");
        }
        
        // 2. Video Data Output (Native Stream on videoQueue)
        self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
        self.videoOutput.alwaysDiscardsLateVideoFrames = NO;
        
        // CRITICAL: Force 32BGRA pixel format for reliable ImageFromPixelBuffer conversion
        // Without this, iOS may output YUV420v/NV12 which causes white/blank images
        self.videoOutput.videoSettings = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
        };
        ACBLog(@"videoOutput configured with kCVPixelFormatType_32BGRA");
        
        if ([self.captureSession canAddOutput:self.videoOutput]) {
            [self.captureSession addOutput:self.videoOutput];
            [self.videoOutput setSampleBufferDelegate:self queue:self.videoQueue];
            ACBLog(@"Successfully added videoOutput (native stream)");
        }
        
        // 3. Preview Layer
        self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.captureSession];
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        
        // Configure connections INSIDE configuration block
        if (self.previewLayer.connection) {
            if (self.previewLayer.connection.isVideoOrientationSupported) {
                self.previewLayer.connection.videoOrientation = AVCaptureVideoOrientationPortrait;
            }
            if (self.previewLayer.connection.isVideoMirroringSupported) {
                self.previewLayer.connection.automaticallyAdjustsVideoMirroring = NO;
                self.previewLayer.connection.videoMirrored = YES;
            }
        }
        
        AVCaptureConnection *videoConn = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
        if (videoConn) {
            videoConn.enabled = YES;
            if (videoConn.isVideoOrientationSupported) {
                videoConn.videoOrientation = AVCaptureVideoOrientationPortrait;
            }
            if (videoConn.isVideoMirroringSupported) {
                videoConn.automaticallyAdjustsVideoMirroring = NO;
                videoConn.videoMirrored = YES;
            }
            ACBLog([NSString stringWithFormat:@"videoConn configured: isEnabled=%d, isActive=%d", videoConn.isEnabled, videoConn.isActive]);
        }
        
        [self.captureSession commitConfiguration];
        ACBLog(@"commitConfiguration completed");
        
        // Enable hardware face metadata AFTER commitConfiguration
        @try {
            if ([self.metadataOutput.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
                self.metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeFace];
                ACBLog(@"Successfully enabled hardware AVMetadataObjectTypeFace output");
            }
        } @catch (NSException *ex) {
            ACBLog([NSString stringWithFormat:@"Warning setting metadataObjectTypes: %@", ex]);
        }
    } @catch (NSException *e) {
        ACBLog([NSString stringWithFormat:@"CRASH in setupSession: %@, reason: %@", e.name, e.reason]);
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
                
                // Re-verify connections after session is actively running
                for (AVCaptureConnection *conn in self.captureSession.connections) {
                    ACBLog([NSString stringWithFormat:@"Active conn: output=%@, isEnabled=%d, isActive=%d", [conn.output class], conn.isEnabled, conn.isActive]);
                }
                
                AVCaptureConnection *videoConn = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
                if (videoConn) {
                    videoConn.enabled = YES;
                    if (videoConn.isVideoOrientationSupported) {
                        videoConn.videoOrientation = AVCaptureVideoOrientationPortrait;
                    }
                    if (videoConn.isVideoMirroringSupported) {
                        videoConn.automaticallyAdjustsVideoMirroring = NO;
                        videoConn.videoMirrored = YES;
                    }
                    ACBLog([NSString stringWithFormat:@"videoConn after startRunning: isEnabled=%d, isActive=%d", videoConn.isEnabled, videoConn.isActive]);
                }
                
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
        ACBLog(@"stopSession called");
    }
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate (Live Frame Capture)

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!imageBuffer) return;
        
        @synchronized (self) {
            if (_latestPixelBuffer) {
                CVPixelBufferRelease(_latestPixelBuffer);
            }
            _latestPixelBuffer = CVPixelBufferRetain(imageBuffer);
        }
        
        self.sampleBufferCounter++;
        if (self.sampleBufferCounter <= 5 || self.sampleBufferCounter % 60 == 0) {
            size_t w = CVPixelBufferGetWidth(imageBuffer);
            size_t h = CVPixelBufferGetHeight(imageBuffer);
            OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
            ACBLog([NSString stringWithFormat:@"Video buffer cached: #%ld (%zux%zu, format='%.4s')", 
                    (long)self.sampleBufferCounter, w, h, (const char*)&pixelFormat]);
        }
    }
}

static NSInteger sDroppedFrameCount = 0;
- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    sDroppedFrameCount++;
    if (sDroppedFrameCount <= 3 || sDroppedFrameCount % 90 == 0) {
        ACBLog([NSString stringWithFormat:@"didDropSampleBuffer #%ld", (long)sDroppedFrameCount]);
    }
}

#pragma mark - AVCaptureMetadataOutputObjectsDelegate (Hardware ISP Face Detection)

- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
    self.frameCounter++;
    
    NSMutableArray<AVMetadataFaceObject *> *faces = [NSMutableArray array];
    for (AVMetadataObject *obj in metadataObjects) {
        if ([obj.type isEqualToString:AVMetadataObjectTypeFace]) {
            [faces addObject:(AVMetadataFaceObject *)obj];
        }
    }
    
    [self evaluateFacesFromMetadata:faces];
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
    if (CGRectIsEmpty(screenFaceRect) || screenFaceRect.size.width <= 1.0) {
        [self reportStatus:ACBFaceStatusNoFace
                   message:@"Vui lòng đảm bảo khuôn mặt nằm trong khung"
                faceBounds:CGRectZero
                      diag:[NSString stringWithFormat:@"[%@] 0 face", source]];
        return;
    }
    
    // Exact classifyNativeFace formulas from ACB NEW APK:
    CGFloat halfW = viewW / 2.0;
    CGFloat targetW = viewW * 0.47;
    CGFloat targetH = targetW * (4.0 / 3.0);
    CGFloat margin = targetW * 0.40;
    
    CGRect oval = self.ovalRect;
    if (CGRectIsEmpty(oval)) {
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
    
    // Skip classification if viewFinderBounds or ovalRect not yet configured
    if (viewW <= 1.0 || CGRectIsEmpty(self.ovalRect)) {
        [self reportStatus:ACBFaceStatusNoFace
                   message:@"Đang khởi tạo camera..."
                faceBounds:CGRectZero
                      diag:@"SKIP: viewFinderBounds/ovalRect not ready"];
        return;
    }
    
    // 1. Centering Check (must be within center +/- margin, matching APK)
    if (dx > margin || dy > margin) {
        [self reportStatus:ACBFaceStatusNotCentered
                   message:@"Vui lòng căn khuôn mặt vào giữa khung hình"
                faceBounds:screenFaceRect
                      diag:[diag stringByAppendingString:@" (Lệch tâm)"]];
        return;
    }
    
    // 2. Distance Check (Too Far)
    CGFloat minW = targetW - margin;
    CGFloat minH = targetH - margin;
    if (screenFaceRect.size.width < minW && screenFaceRect.size.height < minH) {
        [self reportStatus:ACBFaceStatusTooFar
                   message:@"Di chuyển lại gần camera"
                faceBounds:screenFaceRect
                      diag:[diag stringByAppendingString:@" (Quá xa)"]];
        return;
    }
    
    // 3. Distance Check (Too Close)
    CGFloat maxW = targetW + margin * 1.35;
    CGFloat maxH = targetH + margin * 1.35;
    if (screenFaceRect.size.width > maxW && screenFaceRect.size.height > maxH) {
        [self reportStatus:ACBFaceStatusTooClose
                   message:@"Di chuyển ra xa camera"
                faceBounds:screenFaceRect
                      diag:[diag stringByAppendingString:@" (Quá gần)"]];
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

#pragma mark - Capture Frame for Round (Instant Video Frame Buffer Cache)

- (void)captureStillFrameWithCompletion:(void(^)(UIImage * _Nullable image))completion {
    ACBLog(@"captureStillFrameWithCompletion requested");
    
    // Fast path: Check if live video buffer is already cached (Instant, <2ms)
    CVPixelBufferRef pixelBuffer = NULL;
    @synchronized (self) {
        if (self->_latestPixelBuffer) {
            pixelBuffer = CVPixelBufferRetain(self->_latestPixelBuffer);
        }
    }
    
    if (pixelBuffer) {
        UIImage *finalImage = ImageFromPixelBuffer(pixelBuffer);
        CVPixelBufferRelease(pixelBuffer);
        if (finalImage && finalImage.size.width > 50 && finalImage.size.height > 50) {
            ACBLog([NSString stringWithFormat:@"captureStillFrame SUCCESS (Instant VideoBuffer): %.0fx%.0f", finalImage.size.width, finalImage.size.height]);
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(finalImage);
                });
            }
            return;
        }
    }
    
    // If not ready yet, poll briefly up to 1.0 second (checking every 50ms)
    ACBLog(@"VideoBuffer not cached yet, temporarily pausing metadataOutput to prioritize video frames...");
    for (AVCaptureConnection *c in self.metadataOutput.connections) {
        c.enabled = NO;
    }
    __block int attempts = 0;
    NSTimer *pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer * _Nonnull timer) {
        attempts++;
        CVPixelBufferRef pb = NULL;
        @synchronized (self) {
            if (self->_latestPixelBuffer) {
                pb = CVPixelBufferRetain(self->_latestPixelBuffer);
            }
        }
        if (pb) {
            [timer invalidate];
            for (AVCaptureConnection *c in self.metadataOutput.connections) {
                c.enabled = YES;
            }
            UIImage *img = ImageFromPixelBuffer(pb);
            CVPixelBufferRelease(pb);
            if (img && img.size.width > 50 && img.size.height > 50) {
                ACBLog([NSString stringWithFormat:@"captureStillFrame SUCCESS (Polled %d attempts): %.0fx%.0f", attempts, img.size.width, img.size.height]);
                if (completion) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(img);
                    });
                }
                return;
            }
        }
        if (attempts >= 20) { // 1.0s timeout
            [timer invalidate];
            for (AVCaptureConnection *c in self.metadataOutput.connections) {
                c.enabled = YES;
            }
            ACBLog(@"captureStillFrame FAILED after 1.0s poll");
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil);
                });
            }
        }
    }];
}

@end
