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
    if (w == 0 || h == 0) return nil;
    
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
            return img;
        }
    } @catch (NSException *ex) {
        ACBLog(@"ImageFromPixelBuffer VT exception: %@", ex);
    }
    
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
@property (nonatomic, strong) AVCapturePhotoOutput *photoOutput;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;

@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, strong) dispatch_queue_t metadataQueue;
@property (nonatomic, copy, nullable) void(^photoCaptureCompletion)(UIImage * _Nullable image);

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
        
        if ([self.captureSession canSetSessionPreset:AVCaptureSessionPresetHigh]) {
            self.captureSession.sessionPreset = AVCaptureSessionPresetHigh;
            ACBLog(@"Session preset configured to AVCaptureSessionPresetHigh");
        } else if ([self.captureSession canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
            self.captureSession.sessionPreset = AVCaptureSessionPreset1280x720;
            ACBLog(@"Session preset configured to AVCaptureSessionPreset1280x720");
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
        
        // 2. Video Data Output (Live Frame Stream on videoQueue)
        self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
        self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
        
        NSArray *supportedFormats = self.videoOutput.availableVideoCVPixelFormatTypes;
        ACBLog([NSString stringWithFormat:@"availableVideoCVPixelFormatTypes: %@", supportedFormats]);
        OSType chosenFormat = kCVPixelFormatType_32BGRA;
        if ([supportedFormats containsObject:@(kCVPixelFormatType_32BGRA)]) {
            chosenFormat = kCVPixelFormatType_32BGRA;
        } else if ([supportedFormats containsObject:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]) {
            chosenFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        } else if (supportedFormats.firstObject) {
            chosenFormat = [supportedFormats.firstObject unsignedIntValue];
        }
        self.videoOutput.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(chosenFormat) };
        [self.videoOutput setSampleBufferDelegate:self queue:self.videoQueue];
        if ([self.captureSession canAddOutput:self.videoOutput]) {
            [self.captureSession addOutput:self.videoOutput];
            ACBLog([NSString stringWithFormat:@"Successfully added videoOutput (format: %u)", (unsigned int)chosenFormat]);
        }
        
        // 3. Photo Output (Official Apple Still Image Capture API)
        self.photoOutput = [[AVCapturePhotoOutput alloc] init];
        self.photoOutput.highResolutionCaptureEnabled = NO;
        if ([self.captureSession canAddOutput:self.photoOutput]) {
            [self.captureSession addOutput:self.photoOutput];
            ACBLog(@"Successfully added photoOutput");
        }
        
        // 4. Preview Layer
        self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.captureSession];
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        
        [self.captureSession commitConfiguration];
        ACBLog(@"commitConfiguration completed");
        
        // Configure connections AFTER commitConfiguration
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
            ACBLog([NSString stringWithFormat:@"videoConn: isEnabled=%d, isActive=%d", videoConn.isEnabled, videoConn.isActive]);
        }
        
        AVCaptureConnection *photoConn = [self.photoOutput connectionWithMediaType:AVMediaTypeVideo];
        if (photoConn) {
            photoConn.enabled = YES;
            if (photoConn.isVideoOrientationSupported) {
                photoConn.videoOrientation = AVCaptureVideoOrientationPortrait;
            }
            if (photoConn.isVideoMirroringSupported) {
                photoConn.automaticallyAdjustsVideoMirroring = NO;
                photoConn.videoMirrored = YES;
            }
            ACBLog([NSString stringWithFormat:@"photoConn: isEnabled=%d, isActive=%d", photoConn.isEnabled, photoConn.isActive]);
        }
        
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
        if (self.sampleBufferCounter <= 3 || self.sampleBufferCounter % 150 == 0) {
            size_t w = CVPixelBufferGetWidth(imageBuffer);
            size_t h = CVPixelBufferGetHeight(imageBuffer);
            ACBLog([NSString stringWithFormat:@"Video buffer cached: #%ld (%zux%zu)", (long)self.sampleBufferCounter, w, h]);
        }
    }
}

- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
}

#pragma mark - AVCapturePhotoCaptureDelegate (Still Photo Pipeline)

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(nullable NSError *)error {
    ACBLog([NSString stringWithFormat:@"photoOutput: didFinishProcessingPhoto (photo=%@, error=%@)", photo, error]);
    void (^comp)(UIImage *) = self.photoCaptureCompletion;
    self.photoCaptureCompletion = nil;
    self.isCapturePending = NO;
    
    if (photo) {
        NSData *data = [photo fileDataRepresentation];
        if (data && data.length > 0) {
            UIImage *img = [UIImage imageWithData:data];
            ACBLog([NSString stringWithFormat:@"photoOutput SUCCESS: %lu bytes, image: %.0fx%.0f", (unsigned long)data.length, img.size.width, img.size.height]);
            if (comp) comp(img);
            return;
        }
    }
    if (comp) comp(nil);
}

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhotoSampleBuffer:(nullable CMSampleBufferRef)photoSampleBuffer previewPhotoSampleBuffer:(nullable CMSampleBufferRef)previewPhotoSampleBuffer resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings bracketSettings:(nullable AVCaptureBracketedStillImageSettings *)bracketSettings error:(nullable NSError *)error {
    ACBLog([NSString stringWithFormat:@"photoOutput: didFinishProcessingPhotoSampleBuffer (buf=%p, error=%@)", photoSampleBuffer, error]);
    void (^comp)(UIImage *) = self.photoCaptureCompletion;
    self.photoCaptureCompletion = nil;
    self.isCapturePending = NO;
    
    if (photoSampleBuffer) {
        NSData *jpegData = [AVCapturePhotoOutput JPEGPhotoDataRepresentationForJPEGSampleBuffer:photoSampleBuffer previewPhotoSampleBuffer:previewPhotoSampleBuffer];
        if (jpegData && jpegData.length > 0) {
            UIImage *img = [UIImage imageWithData:jpegData];
            ACBLog([NSString stringWithFormat:@"photoOutput SUCCESS (SampleBuffer): %lu bytes", (unsigned long)jpegData.length]);
            if (comp) comp(img);
            return;
        }
    }
    if (comp) comp(nil);
}

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings error:(nullable NSError *)error {
    if (error && self.photoCaptureCompletion) {
        ACBLog([NSString stringWithFormat:@"photoOutput didFinishCaptureForResolvedSettings error: %@", error]);
        void (^comp)(UIImage *) = self.photoCaptureCompletion;
        self.photoCaptureCompletion = nil;
        self.isCapturePending = NO;
        if (comp) comp(nil);
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

#pragma mark - Capture Frame for Round (Ultra-Reliable Video Frame Cache + AVCapturePhotoOutput)

- (void)captureStillFrameWithCompletion:(void(^)(UIImage * _Nullable image))completion {
    ACBLog(@"captureStillFrameWithCompletion requested");
    
    // Tier 1: Check if live video buffer is already cached (Instant, <2ms)
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
            ACBLog([NSString stringWithFormat:@"captureStillFrame SUCCESS (Tier 1 VideoBuffer): %.0fx%.0f", finalImage.size.width, finalImage.size.height]);
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(finalImage);
                });
            }
            return;
        }
    }
    
    // Tier 2: AVCapturePhotoOutput native capture with 3.5s Watchdog
    self.isCapturePending = YES;
    __block BOOL finished = NO;
    
    void (^safeCompletion)(UIImage * _Nullable) = ^(UIImage * _Nullable img) {
        @synchronized (self) {
            if (finished) return;
            finished = YES;
        }
        self.photoCaptureCompletion = nil;
        self.isCapturePending = NO;
        
        UIImage *result = img;
        if (!result) {
            // Re-check latestPixelBuffer before failing
            @synchronized (self) {
                if (self->_latestPixelBuffer) {
                    CVPixelBufferRef pb = CVPixelBufferRetain(self->_latestPixelBuffer);
                    result = ImageFromPixelBuffer(pb);
                    CVPixelBufferRelease(pb);
                }
            }
        }
        
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(result);
            });
        }
    };
    
    self.photoCaptureCompletion = safeCompletion;
    
    // Watchdog timeout (3.5s) for hardware photo capture
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if (finished) return;
        }
        ACBLog(@"WATCHDOG (3.5s): Photo output timed out, checking latest pixelBuffer");
        safeCompletion(nil);
    });
    
    @try {
        AVCapturePhotoSettings *settings;
        if (@available(iOS 11.0, *)) {
            if ([self.photoOutput.availablePhotoCodecTypes containsObject:AVVideoCodecTypeJPEG]) {
                settings = [AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey: AVVideoCodecTypeJPEG}];
            } else {
                settings = [AVCapturePhotoSettings photoSettings];
            }
        } else {
            settings = [AVCapturePhotoSettings photoSettings];
        }
        settings.highResolutionPhotoEnabled = NO;
        
        [self.photoOutput capturePhotoWithSettings:settings delegate:self];
        ACBLog(@"Dispatched capturePhotoWithSettings (Tier 2, JPEG)");
    } @catch (NSException *ex) {
        ACBLog([NSString stringWithFormat:@"capturePhotoWithSettings exception: %@", ex]);
        safeCompletion(nil);
    }
}

@end
