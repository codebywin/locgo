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
    
    // Method 1: CIImage with Metal/GPU (Fastest, handles 420v/420f/BGRA/all YUV)
    @try {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pixelBuffer];
        if (ci) {
            // Front camera sensor is landscape. In portrait, apply orientation LeftMirrored (5)
            // so the face is upright and matches the mirrored preview exactly.
            ci = [ci imageByApplyingOrientation:kCGImagePropertyOrientationLeftMirrored];
            
            static CIContext *sharedCIContext = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                sharedCIContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @(NO)}];
            });
            
            CGImageRef cg = [sharedCIContext createCGImage:ci fromRect:ci.extent];
            if (cg) {
                UIImage *img = [UIImage imageWithCGImage:cg];
                CGImageRelease(cg);
                ACBLog([NSString stringWithFormat:@"ImageFromPixelBuffer CI SUCCESS: %.0fx%.0f (format='%.4s')",
                        img.size.width, img.size.height, (const char*)&format]);
                return img;
            }
        }
    } @catch (NSException *ex) {
        ACBLog([NSString stringWithFormat:@"ImageFromPixelBuffer CIContext exception: %@", ex]);
    }
    
    // Method 2: VideoToolbox hardware decode fallback
    @try {
        CGImageRef vtCg = NULL;
        OSStatus status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, NULL, &vtCg);
        if (status == noErr && vtCg) {
            UIImage *img = [UIImage imageWithCGImage:vtCg scale:1.0 orientation:UIImageOrientationLeftMirrored];
            CGImageRelease(vtCg);
            ACBLog(@"ImageFromPixelBuffer VT SUCCESS");
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
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;

@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, strong) dispatch_queue_t visionQueue;
@property (nonatomic, assign) BOOL isProcessingVision;

@property (nonatomic, assign) NSInteger frameCounter;
@property (nonatomic, assign) NSInteger sampleBufferCounter;

@end

@implementation CameraManager

- (instancetype)init {
    self = [super init];
    if (self) {
        ACBLog(@"CameraManager init started (Pure VideoDataOutput + Vision architecture)");
        _frameCounter = 0;
        _sampleBufferCounter = 0;
        _latestPixelBuffer = NULL;
        _isProcessingVision = NO;
        _videoQueue = dispatch_queue_create("com.acbface.videoQueue", DISPATCH_QUEUE_SERIAL);
        _visionQueue = dispatch_queue_create("com.acbface.visionQueue", DISPATCH_QUEUE_SERIAL);
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
        
        // Single Video Data Output (Native Camera Frame Stream on videoQueue)
        self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
        self.videoOutput.alwaysDiscardsLateVideoFrames = YES; // CRITICAL: Never starve ISP buffer pool!
        self.videoOutput.videoSettings = nil;                 // CRITICAL: Native format directly from hardware!
        if ([self.captureSession canAddOutput:self.videoOutput]) {
            [self.captureSession addOutput:self.videoOutput];
            [self.videoOutput setSampleBufferDelegate:self queue:self.videoQueue];
            ACBLog(@"Successfully added videoOutput (pure stream)");
        }
        
        // Preview Layer
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
        
        [self.captureSession commitConfiguration];
        ACBLog(@"commitConfiguration completed - pure video pipeline ready");
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

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate (Live Frame Capture & Vision Face Detection)

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!imageBuffer) return;
        
        // 1. Immediately cache the latest frame for instant shutter capture (<0.01ms)
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
        
        // 2. Dispatch face detection to visionQueue (drop if busy so video stream is never throttled)
        if (self.isProcessingVision) {
            return;
        }
        self.isProcessingVision = YES;
        
        CVPixelBufferRef bufferForVision = CVPixelBufferRetain(imageBuffer);
        dispatch_async(self.visionQueue, ^{
            @autoreleasepool {
                [self processVisionFaceDetectionOnPixelBuffer:bufferForVision];
                CVPixelBufferRelease(bufferForVision);
                self.isProcessingVision = NO;
            }
        });
    }
}

#pragma mark - Apple Vision.framework Face Detection

- (void)processVisionFaceDetectionOnPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    self.frameCounter++;
    
    VNDetectFaceRectanglesRequest *faceRequest = [[VNDetectFaceRectanglesRequest alloc] init];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBuffer
                                                                               orientation:kCGImagePropertyOrientationLeftMirrored
                                                                                   options:@{}];
    NSError *error = nil;
    [handler performRequests:@[faceRequest] error:&error];
    
    if (error) {
        ACBLog([NSString stringWithFormat:@"Vision face detection error: %@", error]);
        return;
    }
    
    NSArray<VNFaceObservation *> *results = faceRequest.results;
    if (!results || results.count == 0) {
        [self reportStatus:ACBFaceStatusNoFace
                   message:@"Vui lòng đảm bảo khuôn mặt nằm trong khung, nhìn thẳng vào camera và chụp ảnh"
                faceBounds:CGRectZero
                      diag:@"Vision: 0 faces (Che camera/không có mặt)"];
        return;
    }
    
    if (results.count > 1) {
        [self reportStatus:ACBFaceStatusMultipleFaces
                   message:@"Vui lòng chỉ 1 người trong khung hình"
                faceBounds:CGRectZero
                      diag:[NSString stringWithFormat:@"Vision: %lu faces (Nhiều mặt)", (unsigned long)results.count]];
        return;
    }
    
    VNFaceObservation *face = results.firstObject;
    CGRect box = face.boundingBox; // Normalized [0, 1], lower-left origin
    
    // Convert normalized Vision coords (lower-left origin) to upright portrait coordinates
    CGFloat normX = box.origin.x;
    CGFloat normY = 1.0 - (box.origin.y + box.size.height); // UIKit top-left origin
    CGFloat normW = box.size.width;
    CGFloat normH = box.size.height;
    
    // Upright buffer dimensions
    size_t bufW = CVPixelBufferGetWidth(pixelBuffer);
    size_t bufH = CVPixelBufferGetHeight(pixelBuffer);
    // Since kCGImagePropertyOrientationLeftMirrored swaps W & H:
    CGFloat videoW = (CGFloat)bufH;
    CGFloat videoH = (CGFloat)bufW;
    
    // Target view dimensions
    CGFloat viewW = self.viewFinderBounds.size.width;
    CGFloat viewH = self.viewFinderBounds.size.height;
    if (viewW <= 0 || viewH <= 0) {
        viewW = self.previewLayer.bounds.size.width;
        viewH = self.previewLayer.bounds.size.height;
    }
    if (viewW <= 0 || viewH <= 0) {
        viewW = [UIScreen mainScreen].bounds.size.width * 0.892;
        viewH = viewW * (4.0 / 3.0);
    }
    
    // AspectFill mapping
    CGFloat scale = MAX(viewW / videoW, viewH / videoH);
    CGFloat renderedW = videoW * scale;
    CGFloat renderedH = videoH * scale;
    CGFloat offsetX = (viewW - renderedW) / 2.0;
    CGFloat offsetY = (viewH - renderedH) / 2.0;
    
    CGRect screenFaceRect = CGRectMake(offsetX + normX * renderedW,
                                       offsetY + normY * renderedH,
                                       normW * renderedW,
                                       normH * renderedH);
    
    CGFloat rollDeg = face.roll ? ([face.roll doubleValue] * 180.0 / M_PI) : 0.0;
    CGFloat yawDeg = face.yaw ? ([face.yaw doubleValue] * 180.0 / M_PI) : 0.0;
    
    [self runACBClassificationWithFaceRect:screenFaceRect
                                   rollDeg:rollDeg
                                    yawDeg:yawDeg
                                    source:@"Vision"];
}

#pragma mark - Classification Math (100% Parity with ACB NEW classifyNativeFace)

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

#pragma mark - Capture Frame for Round (Instant Video Frame Buffer from RAM)

- (void)captureStillFrameWithCompletion:(void(^)(UIImage * _Nullable image))completion {
    ACBLog(@"captureStillFrameWithCompletion requested - grabbing live video buffer from RAM");
    
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
            ACBLog([NSString stringWithFormat:@"captureStillFrame SUCCESS (Instant RAM Buffer): %.0fx%.0f", finalImage.size.width, finalImage.size.height]);
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(finalImage);
                });
            }
            return;
        }
    }
    
    // If buffer not ready yet (e.g. within first 300ms of launch), wait briefly up to 1.5s
    ACBLog(@"VideoBuffer not cached yet, waiting for first incoming frame...");
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
        if (attempts >= 30) { // 1.5s timeout
            [timer invalidate];
            ACBLog(@"captureStillFrame FAILED after 1.5s poll");
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil);
                });
            }
        }
    }];
}

@end
