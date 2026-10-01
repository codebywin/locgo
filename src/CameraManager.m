#import "CameraManager.h"
#import "ACBLogger.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>

static UIImage * _Nullable NormalizedImage(UIImage *image) {
    if (!image) return nil;
    if (image.imageOrientation == UIImageOrientationUp) return image;
    UIGraphicsBeginImageContextWithOptions(image.size, NO, image.scale);
    [image drawInRect:(CGRect){0, 0, image.size}];
    UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return normalized ?: image;
}

static UIImage * _Nullable ImageFromPixelBuffer(CVPixelBufferRef pixelBuffer) {
    if (!pixelBuffer) return nil;
    
    size_t w = CVPixelBufferGetWidth(pixelBuffer);
    size_t h = CVPixelBufferGetHeight(pixelBuffer);
    OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
    if (w == 0 || h == 0) return nil;
    
    // Method 1: CIImage with Metal/GPU
    @try {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pixelBuffer];
        if (ci) {
            // Raw sensor orientation (Landscape 90 degrees, matching Android raw front camera sensor as in user sample)
            static CIContext *sharedCIContext = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                sharedCIContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @(NO)}];
            });
            
            CGImageRef cg = [sharedCIContext createCGImage:ci fromRect:ci.extent];
            if (cg) {
                UIImage *img = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
                CGImageRelease(cg);
                ACBLog([NSString stringWithFormat:@"ImageFromPixelBuffer CI SUCCESS (Raw Landscape): %.0fx%.0f (format='%.4s')",
                        img.size.width, img.size.height, (const char*)&format]);
                return img;
            }
        }
    } @catch (NSException *ex) {
        ACBLog([NSString stringWithFormat:@"ImageFromPixelBuffer CIContext exception: %@", ex]);
    }
    
    // Method 2: Direct CoreGraphics Bitmap for 32BGRA
    if (format == kCVPixelFormatType_32BGRA) {
        @try {
            CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
            void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
            size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
            CGContextRef context = CGBitmapContextCreate(base, w, h, 8, bytesPerRow, colorSpace,
                                                         kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
            CGImageRef cgImage = context ? CGBitmapContextCreateImage(context) : NULL;
            if (context) CGContextRelease(context);
            CGColorSpaceRelease(colorSpace);
            CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
            if (cgImage) {
                UIImage *img = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationUp];
                CGImageRelease(cgImage);
                ACBLog(@"ImageFromPixelBuffer Direct BGRA SUCCESS (Raw Landscape)");
                return NormalizedImage(img);
            }
        } @catch (NSException *ex) {
            ACBLog([NSString stringWithFormat:@"ImageFromPixelBuffer BGRA exception: %@", ex]);
        }
    }
    
    // Method 3: VideoToolbox decode fallback
    @try {
        CGImageRef vtCg = NULL;
        OSStatus status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, NULL, &vtCg);
        if (status == noErr && vtCg) {
            UIImage *img = [UIImage imageWithCGImage:vtCg scale:1.0 orientation:UIImageOrientationUp];
            CGImageRelease(vtCg);
            ACBLog(@"ImageFromPixelBuffer VT SUCCESS (Raw Landscape)");
            return NormalizedImage(img);
        }
    } @catch (NSException *ex) {
        ACBLog([NSString stringWithFormat:@"ImageFromPixelBuffer VideoToolbox exception: %@", ex]);
    }
    
    ACBLog(@"ImageFromPixelBuffer: FAILED to convert buffer");
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
@property (nonatomic, strong) AVCaptureStillImageOutput *stillImageOutput;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;

@property (nonatomic, strong) dispatch_queue_t metadataQueue;
@property (nonatomic, strong) dispatch_queue_t videoQueue;

@property (nonatomic, assign) NSInteger frameCounter;
@property (nonatomic, assign) NSInteger sampleBufferCounter;

@end

@implementation CameraManager

- (instancetype)init {
    self = [super init];
    if (self) {
        ACBLog(@"CameraManager init started (Triple Output: Metadata + VideoData + StillImage)");
        _frameCounter = 0;
        _sampleBufferCounter = 0;
        _latestPixelBuffer = NULL;
        _metadataQueue = dispatch_queue_create("com.acbface.metadataQueue", DISPATCH_QUEUE_SERIAL);
        _videoQueue = dispatch_queue_create("com.acbface.videoQueue", DISPATCH_QUEUE_SERIAL);
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
        
        if ([self.captureSession canSetSessionPreset:AVCaptureSessionPresetPhoto]) {
            self.captureSession.sessionPreset = AVCaptureSessionPresetPhoto;
            ACBLog(@"Session preset configured to AVCaptureSessionPresetPhoto (Full Resolution)");
        } else if ([self.captureSession canSetSessionPreset:AVCaptureSessionPresetHigh]) {
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
            NSError *cfgError = nil;
            if ([self.frontCamera lockForConfiguration:&cfgError]) {
                if ([self.frontCamera isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
                    self.frontCamera.focusMode = AVCaptureFocusModeContinuousAutoFocus;
                }
                if ([self.frontCamera isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
                    self.frontCamera.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
                }
                if ([self.frontCamera isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance]) {
                    self.frontCamera.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
                }
                if ([self.frontCamera isLowLightBoostSupported]) {
                    self.frontCamera.automaticallyEnablesLowLightBoostWhenAvailable = YES;
                }
                [self.frontCamera unlockForConfiguration];
            }
            
            NSError *error = nil;
            self.videoInput = [AVCaptureDeviceInput deviceInputWithDevice:self.frontCamera error:&error];
            if (self.videoInput && [self.captureSession canAddInput:self.videoInput]) {
                [self.captureSession addInput:self.videoInput];
                ACBLog(@"Successfully added videoInput with AutoFocus & AutoExposure");
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
        
        // 2. AVCaptureStillImageOutput (Classic direct JPEG capture - 100% immune to mediaserverd IPC hangs)
        self.stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
        self.stillImageOutput.outputSettings = @{AVVideoCodecKey: AVVideoCodecJPEG};
        if ([self.captureSession canAddOutput:self.stillImageOutput]) {
            [self.captureSession addOutput:self.stillImageOutput];
            ACBLog(@"Successfully added stillImageOutput (classic direct JPEG)");
        }
        
        // 3. Video Data Output (32BGRA RAM buffer stream)
        self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
        self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
        self.videoOutput.videoSettings = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
        };
        if ([self.captureSession canAddOutput:self.videoOutput]) {
            [self.captureSession addOutput:self.videoOutput];
            [self.videoOutput setSampleBufferDelegate:self queue:self.videoQueue];
            ACBLog(@"Successfully added videoOutput (32BGRA format)");
        }
        
        // 4. Preview Layer
        self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.captureSession];
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        
        if (self.previewLayer.connection) {
            if (self.previewLayer.connection.isVideoOrientationSupported) {
                self.previewLayer.connection.videoOrientation = AVCaptureVideoOrientationPortrait;
            }
            if (self.previewLayer.connection.isVideoMirroringSupported) {
                self.previewLayer.connection.automaticallyAdjustsVideoMirroring = NO;
                self.previewLayer.connection.videoMirrored = YES;
            }
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
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        if (self.metadataOutput.metadataObjectTypes.count == 0 &&
                            [self.metadataOutput.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
                            self.metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeFace];
                            ACBLog(@"Successfully enabled AVMetadataObjectTypeFace after session running");
                        }
                    } @catch (NSException *ex) {
                        ACBLog([NSString stringWithFormat:@"Warning: %@", ex]);
                    }
                });
            } @catch (NSException *e) {
                ACBLog([NSString stringWithFormat:@"CRASH in startRunning: %@, reason: %@", e.name, e.reason]);
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
        if (self.sampleBufferCounter <= 3 || self.sampleBufferCounter % 60 == 0) {
            size_t w = CVPixelBufferGetWidth(imageBuffer);
            size_t h = CVPixelBufferGetHeight(imageBuffer);
            OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
            ACBLog([NSString stringWithFormat:@"Video buffer #%ld cached: %zux%zu, format='%.4s'",
                    (long)self.sampleBufferCounter, w, h, (const char*)&pixelFormat]);
        }
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

#pragma mark - Capture Frame for Round (Priority: Hardware Still Photo ISP -> Fallback: RAM Buffer)

- (void)captureStillFrameWithCompletion:(void(^)(UIImage * _Nullable image))completion {
    ACBLog(@"captureStillFrameWithCompletion requested");
    
    // Priority 1: Direct AVCaptureStillImageOutput (Apple ISP Hardware Photo Engine - Sharp, Denoised, Anti-Flicker)
    AVCaptureConnection *videoConn = [self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
    if (videoConn && videoConn.isActive && videoConn.isEnabled) {
        if (videoConn.isVideoOrientationSupported) {
            videoConn.videoOrientation = AVCaptureVideoOrientationLandscapeRight;
        }
        if (videoConn.isVideoMirroringSupported) {
            videoConn.automaticallyAdjustsVideoMirroring = NO;
            videoConn.videoMirrored = NO;
        }
        
        ACBLog(@"Capturing via stillImageOutput direct connection (High-Res Still Photo)...");
        [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:videoConn completionHandler:^(CMSampleBufferRef  _Nullable imageDataSampleBuffer, NSError * _Nullable error) {
            if (error) {
                ACBLog([NSString stringWithFormat:@"stillImageOutput warning: %@", error]);
            }
            if (imageDataSampleBuffer) {
                NSData *jpegData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
                if (jpegData && jpegData.length > 0) {
                    UIImage *img = [UIImage imageWithData:jpegData];
                    if (img) {
                        img = NormalizedImage(img);
                        ACBLog([NSString stringWithFormat:@"captureStillFrame SUCCESS (stillImageOutput HQ): %.0fx%.0f (%lu bytes)",
                                img.size.width, img.size.height, (unsigned long)jpegData.length]);
                        if (completion) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                completion(img);
                            });
                        }
                        return;
                    }
                }
            }
            
            // Fallback to RAM buffer if stillImageOutput returned no data
            ACBLog(@"stillImageOutput returned no data, falling back to RAM buffer");
            [self fallbackCaptureFromRAMBuffer:completion];
        }];
        return;
    }
    
    // Fallback if stillImageOutput connection not available
    [self fallbackCaptureFromRAMBuffer:completion];
}

- (void)fallbackCaptureFromRAMBuffer:(void(^)(UIImage * _Nullable image))completion {
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
            ACBLog([NSString stringWithFormat:@"captureStillFrame SUCCESS (RAM buffer fallback): %.0fx%.0f", finalImage.size.width, finalImage.size.height]);
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(finalImage);
                });
            }
            return;
        }
    }
    
    ACBLog(@"captureStillFrame FAILED: both stillImageOutput and RAM buffer failed");
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil);
        });
    }
}

@end
