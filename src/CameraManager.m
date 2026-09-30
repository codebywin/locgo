#import "CameraManager.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>

static void ACBLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSLog(@"[ACBFace] %@", msg);
    
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *timeStr = [df stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", timeStr, msg];
    NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
    
    NSString *tempLog = [NSTemporaryDirectory() stringByAppendingPathComponent:@"acb_face.log"];
    NSArray *paths = @[tempLog, @"/tmp/acb_debug.log", @"/private/var/tmp/acb_face.log"];
    for (NSString *logPath in paths) {
        @try {
            if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
                [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
            }
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
            if (handle) {
                [handle seekToEndOfFile];
                [handle writeData:lineData];
                [handle closeFile];
            }
        } @catch (NSException *ex) {}
    }
}

@interface CameraManager ()

@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureDevice *frontCamera;
@property (nonatomic, strong) AVCaptureDeviceInput *videoInput;
@property (nonatomic, strong) AVCaptureMetadataOutput *metadataOutput;
@property (nonatomic, strong) AVCapturePhotoOutput *photoOutput;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, copy, nullable) void(^photoCaptureCompletion)(UIImage * _Nullable image);

@property (nonatomic, assign) NSInteger frameCounter;
@property (nonatomic, assign) BOOL isCapturePending;

@end

@implementation CameraManager

- (instancetype)init {
    self = [super init];
    if (self) {
        ACBLog(@"CameraManager init started");
        _frameCounter = 0;
        _isCapturePending = NO;
        [self setupSession];
    }
    return self;
}

- (void)dealloc {
    [self stopSession];
}

- (void)setupSession {
    ACBLog(@"setupSession beginning");
    @try {
        self.captureSession = [[AVCaptureSession alloc] init];
        [self.captureSession beginConfiguration];
        
        if ([self.captureSession canSetSessionPreset:AVCaptureSessionPresetPhoto]) {
            self.captureSession.sessionPreset = AVCaptureSessionPresetPhoto;
            ACBLog(@"Session preset configured to AVCaptureSessionPresetPhoto");
        } else if ([self.captureSession canSetSessionPreset:AVCaptureSessionPresetHigh]) {
            self.captureSession.sessionPreset = AVCaptureSessionPresetHigh;
            ACBLog(@"Session preset configured to AVCaptureSessionPresetHigh");
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
        
        // 1. Hardware Metadata Output (Apple Camera ISP Face Detection)
        self.metadataOutput = [[AVCaptureMetadataOutput alloc] init];
        if ([self.captureSession canAddOutput:self.metadataOutput]) {
            [self.captureSession addOutput:self.metadataOutput];
            [self.metadataOutput setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
            ACBLog(@"Successfully added metadataOutput");
        } else {
            ACBLog(@"Failed to add metadataOutput");
        }
        
        // 2. Photo Output (Official Apple Still Image Capture API)
        self.photoOutput = [[AVCapturePhotoOutput alloc] init];
        if ([self.captureSession canAddOutput:self.photoOutput]) {
            [self.captureSession addOutput:self.photoOutput];
            ACBLog(@"Successfully added photoOutput");
        } else {
            ACBLog(@"Failed to add photoOutput");
        }
        
        // 3. Preview Layer
        self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.captureSession];
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        
        [self.captureSession commitConfiguration];
        ACBLog(@"commitConfiguration completed");
        
        // Enable hardware face metadata AFTER commitConfiguration
        @try {
            if ([self.metadataOutput.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
                self.metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeFace];
                ACBLog(@"Successfully enabled hardware AVMetadataObjectTypeFace output");
            }
        } @catch (NSException *ex) {
            ACBLog(@"Warning setting metadataObjectTypes: %@", ex);
        }
        
        // Configure photo connection AFTER commitConfiguration
        @try {
            AVCaptureConnection *photoConn = [self.photoOutput connectionWithMediaType:AVMediaTypeVideo];
            if (photoConn) {
                if (photoConn.isVideoOrientationSupported) {
                    photoConn.videoOrientation = AVCaptureVideoOrientationPortrait;
                }
                if (photoConn.isVideoMirroringSupported) {
                    photoConn.automaticallyAdjustsVideoMirroring = NO;
                    photoConn.videoMirrored = YES;
                }
                ACBLog([NSString stringWithFormat:@"photoConn: active=%d, enabled=%d", photoConn.isActive, photoConn.isEnabled]);
            }
        } @catch (NSException *ex) {
            ACBLog(@"Warning configuring photoConn: %@", ex);
        }
        
        // Configure previewLayer connection
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
        
        ACBLog([NSString stringWithFormat:@"photoOutput availablePhotoCodecTypes: %@", self.photoOutput.availablePhotoCodecTypes]);
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
    if (self.isCapturePending) {
        return; // Don't process metadata while photo capture is active
    }
    
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
    
    // 1. Centering Check
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

#pragma mark - Fallback Image Generation (Guaranteed Snapshot)

- (UIImage *)captureFallbackImage {
    ACBLog(@"captureFallbackImage executing...");
    @try {
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        if (!window) {
            window = [UIApplication sharedApplication].windows.firstObject;
        }
        if (window) {
            UIGraphicsBeginImageContextWithOptions(window.bounds.size, NO, 0.0);
            [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
            UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            if (image && image.size.width > 20 && image.size.height > 20) {
                ACBLog([NSString stringWithFormat:@"captureFallbackImage: window snapshot succeeded (%.0fx%.0f)", image.size.width, image.size.height]);
                return image;
            }
        }
    } @catch (NSException *ex) {
        ACBLog(@"captureFallbackImage window snapshot error: %@", ex);
    }
    
    // Solid clean image fallback if all else fails
    CGSize size = self.viewFinderBounds.size;
    if (size.width <= 0 || size.height <= 0) size = CGSizeMake(480, 640);
    UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
    [[UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0] setFill];
    UIRectFill(CGRectMake(0, 0, size.width, size.height));
    UIImage *solid = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    ACBLog(@"captureFallbackImage: generated solid frame fallback");
    return solid;
}

#pragma mark - AVCapturePhotoCaptureDelegate

- (void)captureOutput:(AVCapturePhotoOutput *)output willBeginCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings {
    ACBLog(@"photoOutput: willBeginCaptureForResolvedSettings");
}

- (void)captureOutput:(AVCapturePhotoOutput *)output willCapturePhotoForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings {
    ACBLog(@"photoOutput: willCapturePhotoForResolvedSettings");
}

- (void)captureOutput:(AVCapturePhotoOutput *)output didCapturePhotoForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings {
    ACBLog(@"photoOutput: didCapturePhotoForResolvedSettings");
}

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(nullable NSError *)error {
    ACBLog([NSString stringWithFormat:@"photoOutput: didFinishProcessingPhoto (error=%@, photo=%@)", error, photo]);
    
    void (^comp)(UIImage *) = self.photoCaptureCompletion;
    self.photoCaptureCompletion = nil;
    self.isCapturePending = NO;
    
    // Re-enable metadata face tracking
    @try {
        if ([self.metadataOutput.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
            self.metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeFace];
        }
    } @catch (NSException *e) {}
    
    if (error || !photo) {
        ACBLog([NSString stringWithFormat:@"photoOutput failed with error: %@, using fallback", error]);
        if (comp) comp([self captureFallbackImage]);
        return;
    }
    
    NSData *data = [photo fileDataRepresentation];
    if (data && data.length > 0) {
        UIImage *img = [UIImage imageWithData:data];
        ACBLog([NSString stringWithFormat:@"photoOutput SUCCESS: %lu bytes, image: %.0fx%.0f", (unsigned long)data.length, img.size.width, img.size.height]);
        if (comp) comp(img ?: [self captureFallbackImage]);
    } else {
        ACBLog(@"photoOutput: fileDataRepresentation returned nil, using fallback");
        if (comp) comp([self captureFallbackImage]);
    }
}

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings error:(nullable NSError *)error {
    ACBLog([NSString stringWithFormat:@"photoOutput: didFinishCaptureForResolvedSettings (error=%@)", error]);
    if (error && self.photoCaptureCompletion) {
        void (^comp)(UIImage *) = self.photoCaptureCompletion;
        self.photoCaptureCompletion = nil;
        self.isCapturePending = NO;
        
        @try {
            if ([self.metadataOutput.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
                self.metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeFace];
            }
        } @catch (NSException *e) {}
        
        if (comp) comp([self captureFallbackImage]);
    }
}

#pragma mark - Capture Frame for Round

- (void)captureStillFrameWithCompletion:(void(^)(UIImage * _Nullable image))completion {
    ACBLog(@"captureStillFrameWithCompletion requested");
    
    if (!self.photoOutput || !self.captureSession.isRunning) {
        ACBLog(@"photoOutput not available or session not running -> using fallback image");
        if (completion) completion([self captureFallbackImage]);
        return;
    }
    
    self.isCapturePending = YES;
    
    __block BOOL finished = NO;
    void (^safeCompletion)(UIImage * _Nullable) = ^(UIImage * _Nullable img) {
        @synchronized (self) {
            if (finished) return;
            finished = YES;
        }
        self.photoCaptureCompletion = nil;
        self.isCapturePending = NO;
        
        // Ensure metadata face detection is restored
        @try {
            if (self.metadataOutput.metadataObjectTypes.count == 0 &&
                [self.metadataOutput.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
                self.metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeFace];
            }
        } @catch (NSException *e) {}
        
        UIImage *result = img ?: [self captureFallbackImage];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(result);
            });
        }
    };
    
    self.photoCaptureCompletion = safeCompletion;
    
    // Watchdog timeout: if photoOutput does not complete within 3.5s, force fallback snapshot
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if (finished) return;
        }
        ACBLog(@"TIMEOUT (3.5s): photoOutput did not call delegate! Invoking fallback snapshot.");
        safeCompletion([self captureFallbackImage]);
    });
    
    // Temporarily pause metadata so ISP pipeline has full bandwidth for still photo capture
    @try {
        self.metadataOutput.metadataObjectTypes = @[];
    } @catch (NSException *e) {
        ACBLog(@"Failed to pause metadata: %@", e);
    }
    
    @try {
        AVCapturePhotoSettings *settings = nil;
        if ([self.photoOutput.availablePhotoCodecTypes containsObject:AVVideoCodecTypeJPEG]) {
            settings = [AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey: AVVideoCodecTypeJPEG}];
            ACBLog(@"Dispatched capturePhotoWithSettings with AVVideoCodecTypeJPEG");
        } else {
            settings = [AVCapturePhotoSettings photoSettings];
            ACBLog(@"Dispatched capturePhotoWithSettings with default format");
        }
        
        [self.photoOutput capturePhotoWithSettings:settings delegate:self];
    } @catch (NSException *ex) {
        ACBLog(@"capturePhotoWithSettings exception: %@, falling back", ex);
        safeCompletion([self captureFallbackImage]);
    }
}

@end
