#import "CameraManager.h"

@interface CameraManager ()
@property (nonatomic, strong) AVCaptureDeviceInput *videoInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) AVCaptureMetadataOutput *metadataOutput;
@property (nonatomic, strong) dispatch_queue_t captureQueue;

@property (nonatomic, assign) NSInteger consecutiveOKCount;
@property (nonatomic, assign) BOOL isCapturing;
@property (nonatomic, assign) NSInteger capturedCount;
@property (nonatomic, assign) NSTimeInterval lastCaptureTime;
@property (nonatomic, assign) NSTimeInterval lastMetadataTime;
@property (nonatomic, strong) NSString *sessionDirectory;
@end

@implementation CameraManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _targetFrameCount = 10;
        _consecutiveOKCount = 0;
        _isCapturing = NO;
        _capturedCount = 0;
        _lastCaptureTime = 0;
        _lastMetadataTime = 0;
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
    
    // Video Output for Frame Grab
    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.videoOutput.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
    [self.videoOutput setSampleBufferDelegate:self queue:self.captureQueue];
    if ([self.captureSession canAddOutput:self.videoOutput]) {
        [self.captureSession addOutput:self.videoOutput];
    }
    
    // Metadata Output for Real-time Hardware Face Detection
    self.metadataOutput = [[AVCaptureMetadataOutput alloc] init];
    [self.metadataOutput setMetadataObjectsDelegate:self queue:self.captureQueue];
    if ([self.captureSession canAddOutput:self.metadataOutput]) {
        [self.captureSession addOutput:self.metadataOutput];
    }
    
    // Preview Layer
    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.captureSession];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    
    // Connections Orientation
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
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self enableFaceDetectionIfAvailable];
            });
        });
    }
}

- (void)enableFaceDetectionIfAvailable {
    if ([self.metadataOutput.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
        self.metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeFace];
    } else {
        // Retry shortly after stream buffer warms up
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ([self.metadataOutput.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
                self.metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeFace];
            }
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
        
        // Only convert buffer to image when actively capturing 10 frames
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
        }
    }
}

#pragma mark - AVCaptureMetadataOutputObjectsDelegate (100% Parity with ACB NEW LoginFaceValidator)

- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
    if (self.isCapturing) return;
    
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - self.lastMetadataTime < 0.10) return; // rate limit ~10 fps
    self.lastMetadataTime = now;
    
    NSMutableArray<AVMetadataFaceObject *> *faces = [NSMutableArray array];
    for (AVMetadataObject *obj in metadataObjects) {
        if ([obj.type isEqualToString:AVMetadataObjectTypeFace]) {
            [faces addObject:(AVMetadataFaceObject *)obj];
        }
    }
    
    // Condition 1: Must detect exactly 1 face
    if (faces.count == 0) {
        self.consecutiveOKCount = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
                [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusNoFace
                                                        message:@"Vui lòng đưa khuôn mặt vào trong khung hình"
                                                     faceBounds:CGRectZero];
            }
        });
        return;
    }
    
    if (faces.count > 1) {
        self.consecutiveOKCount = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
                [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusMultipleFaces
                                                        message:@"Vui lòng chỉ 1 người trong khung hình"
                                                     faceBounds:CGRectZero];
            }
        });
        return;
    }
    
    AVMetadataFaceObject *face = faces.firstObject;
    
    // Transform coordinates to screen pixels using previewLayer
    AVMetadataObject *transformed = [self.previewLayer transformedMetadataObjectForMetadataObject:face];
    CGRect screenFaceRect = transformed ? transformed.bounds : CGRectZero;
    
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    
    CGRect oval = self.ovalRect;
    if (CGRectIsEmpty(oval)) {
        oval = CGRectMake(screenW * 0.12, screenH * 0.22, screenW * 0.76, screenW * 0.76 * 1.34);
    }
    
    CGFloat faceCenterX = CGRectGetMidX(screenFaceRect);
    CGFloat faceCenterY = CGRectGetMidY(screenFaceRect);
    CGFloat ovalCenterX = CGRectGetMidX(oval);
    CGFloat ovalCenterY = CGRectGetMidY(oval);
    
    // Condition 2: Head Tilt (Roll angle & Yaw angle) - ACB max 10 degrees
    if (face.hasRollAngle && fabs(face.rollAngle) > 10.0) {
        self.consecutiveOKCount = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
                [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusHeadTilted
                                                        message:@"Vui lòng nhìn thẳng vào màn hình"
                                                     faceBounds:screenFaceRect];
            }
        });
        return;
    }
    if (face.hasYawAngle && fabs(face.yawAngle) > 10.0) {
        self.consecutiveOKCount = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
                [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusHeadTilted
                                                        message:@"Vui lòng nhìn thẳng vào màn hình"
                                                     faceBounds:screenFaceRect];
            }
        });
        return;
    }
    
    // Condition 3: Centered inside Oval (within 25% of oval width/height)
    CGFloat dx = fabs(faceCenterX - ovalCenterX);
    CGFloat dy = fabs(faceCenterY - ovalCenterY);
    if (dx > oval.size.width * 0.25 || dy > oval.size.height * 0.25) {
        self.consecutiveOKCount = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
                [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusNotCentered
                                                        message:@"Vui lòng đưa mặt vào giữa khung hình"
                                                     faceBounds:screenFaceRect];
            }
        });
        return;
    }
    
    // Condition 4: Distance (classifyDistance: ratio faceW / ovalW from 0.44 to 0.95)
    CGFloat widthRatio = screenFaceRect.size.width / oval.size.width;
    if (widthRatio < 0.44) {
        self.consecutiveOKCount = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
                [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusTooFar
                                                        message:@"Vui lòng tiến lại gần hơn chút"
                                                     faceBounds:screenFaceRect];
            }
        });
        return;
    }
    if (widthRatio > 0.95) {
        self.consecutiveOKCount = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
                [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusTooClose
                                                        message:@"Vui lòng lùi ra xa hơn chút"
                                                     faceBounds:screenFaceRect];
            }
        });
        return;
    }
    
    // === ALL CONDITIONS PASSED (FACE_OK) ===
    self.consecutiveOKCount++;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
            [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusFaceOK
                                                    message:@"ĐÃ ĐẠT CHUẨN - GIỮ NGUYÊN KHUÔN MẶT"
                                                 faceBounds:screenFaceRect];
        }
    });
    
    // Automatic trigger: require 3 consecutive qualified frames (held steady for ~0.3s)
    if (self.consecutiveOKCount >= 3) {
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
}

@end
