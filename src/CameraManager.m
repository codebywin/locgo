#import "CameraManager.h"

@interface CameraManager ()
@property (nonatomic, strong) AVCaptureDeviceInput *videoInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) dispatch_queue_t captureQueue;

@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) CIDetector *faceDetector;

@property (nonatomic, assign) NSInteger consecutiveOKCount;
@property (nonatomic, assign) BOOL isCapturing;
@property (nonatomic, assign) NSInteger capturedCount;
@property (nonatomic, assign) NSTimeInterval lastCaptureTime;
@property (nonatomic, assign) NSTimeInterval lastDetectTime;
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
        _lastDetectTime = 0;
        _captureQueue = dispatch_queue_create("com.acbface.videoQueue", DISPATCH_QUEUE_SERIAL);
        
        _ciContext = [CIContext context];
        _faceDetector = [CIDetector detectorOfType:CIDetectorTypeFace
                                           context:_ciContext
                                           options:@{CIDetectorAccuracy: CIDetectorAccuracyLow}];
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
    
    // Front Camera
    AVCaptureDevice *frontCamera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                      mediaType:AVMediaTypeVideo
                                                                       position:AVCaptureDevicePositionFront];
    if (!frontCamera) {
        frontCamera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }
    
    if (frontCamera) {
        NSError *error = nil;
        self.videoInput = [AVCaptureDeviceInput deviceInputWithDevice:frontCamera error:&error];
        if ([self.captureSession canAddInput:self.videoInput]) {
            [self.captureSession addInput:self.videoInput];
        }
    }
    
    // Video Output (Frames flow to delegate)
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
    
    AVCaptureConnection *connection = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (connection.isVideoOrientationSupported) {
        connection.videoOrientation = AVCaptureVideoOrientationPortrait;
    }
    if (connection.isVideoMirroringSupported) {
        if ([connection respondsToSelector:@selector(setAutomaticallyAdjustsVideoMirroring:)]) {
            connection.automaticallyAdjustsVideoMirroring = NO;
        }
        connection.videoMirrored = YES;
    }
    
    if (self.previewLayer.connection.isVideoOrientationSupported) {
        self.previewLayer.connection.videoOrientation = AVCaptureVideoOrientationPortrait;
    }
    if (self.previewLayer.connection.isVideoMirroringSupported) {
        if ([self.previewLayer.connection respondsToSelector:@selector(setAutomaticallyAdjustsVideoMirroring:)]) {
            self.previewLayer.connection.automaticallyAdjustsVideoMirroring = NO;
        }
        self.previewLayer.connection.videoMirrored = YES;
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

- (void)resetCapture {
    self.isCapturing = NO;
    self.consecutiveOKCount = 0;
    self.capturedCount = 0;
}

- (void)prepareSessionDirectory {
    NSString *tempDir = NSTemporaryDirectory();
    NSString *sessionName = [NSString stringWithFormat:@"login_frames_%ld", (long)[[NSDate date] timeIntervalSince1970]];
    self.sessionDirectory = [tempDir stringByAppendingPathComponent:sessionName];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:self.sessionDirectory withIntermediateDirectories:YES attributes:nil error:nil];
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!imageBuffer) return;
        
        // 1. If currently capturing burst (10 frames):
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
                    
                    // Save flat frame 1.jpg ... 10.jpg
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
        
        // 2. Real-time Face Validation (Rate-limit analysis to ~10 fps for smooth UI)
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - self.lastDetectTime < 0.10) {
            return;
        }
        self.lastDetectTime = now;
        
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
        if (!ciImage || !self.faceDetector) return;
        
        NSDictionary *featuresOpts = @{
            CIDetectorImageOrientation: @(6), // OrientationRight
            CIDetectorEyeBlink: @YES,
            CIDetectorSmile: @YES
        };
        NSArray<CIFeature *> *features = [self.faceDetector featuresInImage:ciImage options:featuresOpts];
        CGSize imgSize = ciImage.extent.size;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self processFaceFeatures:features imageSize:imgSize];
        });
    }
}

#pragma mark - 100% Parity with ACB NEW LoginFaceValidator

- (void)processFaceFeatures:(NSArray<CIFeature *> *)features imageSize:(CGSize)imgSize {
    if (self.isCapturing) return;
    
    // Condition 1: Must detect exactly 1 face
    if (features.count == 0) {
        self.consecutiveOKCount = 0;
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
            [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusNoFace
                                                    message:@"Vui lòng đưa khuôn mặt vào trong khung hình"
                                                 faceBounds:CGRectZero];
        }
        return;
    }
    
    if (features.count > 1) {
        self.consecutiveOKCount = 0;
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
            [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusMultipleFaces
                                                    message:@"Vui lòng chỉ 1 người trong khung hình"
                                                 faceBounds:CGRectZero];
        }
        return;
    }
    
    CIFaceFeature *face = (CIFaceFeature *)features.firstObject;
    CGRect faceBounds = face.bounds;
    
    // Map CoreImage face bounds to Screen coordinates
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    
    // For portrait preview (rotated 90deg, mirrored front camera)
    CGFloat scaleX = screenW / imgSize.height;
    CGFloat scaleY = screenH / imgSize.width;
    CGFloat scale = MAX(scaleX, scaleY);
    
    CGFloat faceW = faceBounds.size.height * scale;
    CGFloat faceH = faceBounds.size.width * scale;
    CGFloat faceCenterX = screenW - (faceBounds.origin.y + faceBounds.size.height / 2.0) * scale;
    CGFloat faceCenterY = (faceBounds.origin.x + faceBounds.size.width / 2.0) * scale;
    CGRect screenFaceRect = CGRectMake(faceCenterX - faceW / 2.0, faceCenterY - faceH / 2.0, faceW, faceH);
    
    CGRect oval = self.ovalRect;
    if (CGRectIsEmpty(oval)) {
        oval = CGRectMake(screenW * 0.12, screenH * 0.22, screenW * 0.76, screenW * 0.76 * 1.34);
    }
    
    CGFloat ovalCenterX = CGRectGetMidX(oval);
    CGFloat ovalCenterY = CGRectGetMidY(oval);
    
    // Condition 2: Head Tilt (yaw / roll)
    if (face.hasFaceAngle && fabs(face.faceAngle) > 10.0) {
        self.consecutiveOKCount = 0;
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
            [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusHeadTilted
                                                    message:@"Vui lòng nhìn thẳng vào màn hình"
                                                 faceBounds:screenFaceRect];
        }
        return;
    }
    
    // Condition 3: Centered inside Oval
    CGFloat dx = fabs(faceCenterX - ovalCenterX);
    CGFloat dy = fabs(faceCenterY - ovalCenterY);
    if (dx > oval.size.width * 0.25 || dy > oval.size.height * 0.25) {
        self.consecutiveOKCount = 0;
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
            [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusNotCentered
                                                    message:@"Vui lòng đưa mặt vào giữa khung hình"
                                                 faceBounds:screenFaceRect];
        }
        return;
    }
    
    // Condition 4: Distance (Too Far / Too Close relative to oval width)
    CGFloat widthRatio = faceW / oval.size.width;
    if (widthRatio < 0.44) {
        self.consecutiveOKCount = 0;
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
            [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusTooFar
                                                    message:@"Vui lòng tiến lại gần hơn chút"
                                                 faceBounds:screenFaceRect];
        }
        return;
    }
    if (widthRatio > 0.95) {
        self.consecutiveOKCount = 0;
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
            [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusTooClose
                                                    message:@"Vui lòng lùi ra xa hơn chút"
                                                 faceBounds:screenFaceRect];
        }
        return;
    }
    
    // Condition 5: Eyes Open (No blink)
    if (face.leftEyeClosed && face.rightEyeClosed) {
        self.consecutiveOKCount = 0;
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
            [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusEyesClosed
                                                    message:@"Vui lòng mở to mắt"
                                                 faceBounds:screenFaceRect];
        }
        return;
    }
    
    // Condition 6: Neutral Expression (No smile)
    if (face.hasSmile) {
        self.consecutiveOKCount = 0;
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
            [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusSmiling
                                                    message:@"Vui lòng giữ nét mặt tự nhiên"
                                                 faceBounds:screenFaceRect];
        }
        return;
    }
    
    // === ALL CONDITIONS PASSED (FACE_OK) ===
    self.consecutiveOKCount++;
    
    if ([self.delegate respondsToSelector:@selector(cameraManagerDidUpdateFaceStatus:message:faceBounds:)]) {
        [self.delegate cameraManagerDidUpdateFaceStatus:ACBFaceStatusFaceOK
                                                message:@"ĐÃ ĐẠT CHUẨN - GIỮ NGUYÊN KHUÔN MẶT"
                                             faceBounds:screenFaceRect];
    }
    
    // Automatic trigger: require 3 consecutive qualified frames (held steady for ~0.3s)
    if (self.consecutiveOKCount >= 3) {
        [self prepareSessionDirectory];
        self.capturedCount = 0;
        self.lastCaptureTime = 0;
        self.isCapturing = YES;
        
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidStartCapturing)]) {
            [self.delegate cameraManagerDidStartCapturing];
        }
    }
}

@end
