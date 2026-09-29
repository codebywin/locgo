#import "CameraManager.h"

@interface CameraManager ()
@property (nonatomic, strong) AVCaptureDeviceInput *videoInput;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) AVCaptureMetadataOutput *metadataOutput;
@property (nonatomic, strong) dispatch_queue_t captureQueue;
@property (nonatomic, assign) NSInteger capturedCount;
@property (nonatomic, assign) NSTimeInterval lastFrameTime;
@property (nonatomic, strong) NSString *sessionDirectory;
@property (nonatomic, assign) BOOL isCurrentFrameQualified;
@property (nonatomic, assign) BOOL isManualCapturing;
@property (nonatomic, strong) UIImage *latestRawImage;
@end

@implementation CameraManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _targetFrameCount = 10;
        _isAutoCaptureActive = NO;
        _isManualCapturing = NO;
        _capturedCount = 0;
        _lastFrameTime = 0;
        _isCurrentFrameQualified = NO;
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
    
    // Front Camera
    AVCaptureDevice *frontCamera = nil;
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
    
    // Video Output
    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    self.videoOutput.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
    [self.videoOutput setSampleBufferDelegate:self queue:self.captureQueue];
    if ([self.captureSession canAddOutput:self.videoOutput]) {
        [self.captureSession addOutput:self.videoOutput];
    }
    
    // Metadata Output (Face detection realtime)
    self.metadataOutput = [[AVCaptureMetadataOutput alloc] init];
    [self.metadataOutput setMetadataObjectsDelegate:self queue:self.captureQueue];
    if ([self.captureSession canAddOutput:self.metadataOutput]) {
        [self.captureSession addOutput:self.metadataOutput];
    }
    
    // Preview Layer
    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.captureSession];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    
    AVCaptureConnection *connection = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (connection.isVideoOrientationSupported) {
        connection.videoOrientation = AVCaptureVideoOrientationPortrait;
    }
    if (connection.isVideoMirroringSupported) {
        connection.videoMirrored = YES;
    }
    
    [self.captureSession commitConfiguration];
    
    // Configure metadata types AFTER commitConfiguration
    if ([self.metadataOutput.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
        self.metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeFace];
    }
}

- (void)startSession {
    if (![self.captureSession isRunning]) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self.captureSession startRunning];
            
            // Re-verify metadataObjectTypes after session starts running
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![self.metadataOutput.metadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
                    if ([self.metadataOutput.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
                        self.metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeFace];
                    }
                }
            });
        });
    }
}

- (void)stopSession {
    if ([self.captureSession isRunning]) {
        [self.captureSession stopRunning];
    }
}

- (void)startAutoCapture {
    [self prepareSessionDirectory];
    self.capturedCount = 0;
    self.lastFrameTime = 0;
    self.isManualCapturing = NO;
    self.isAutoCaptureActive = YES;
}

- (void)triggerManualCapture {
    [self prepareSessionDirectory];
    self.capturedCount = 0;
    self.lastFrameTime = 0;
    self.isManualCapturing = YES;
    self.isAutoCaptureActive = NO;
}

- (void)prepareSessionDirectory {
    NSString *tempDir = NSTemporaryDirectory();
    NSString *sessionName = [NSString stringWithFormat:@"login_frames_%ld", (long)[[NSDate date] timeIntervalSince1970]];
    self.sessionDirectory = [tempDir stringByAppendingPathComponent:sessionName];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:self.sessionDirectory withIntermediateDirectories:YES attributes:nil error:nil];
}

- (void)resetCapture {
    self.isAutoCaptureActive = NO;
    self.isManualCapturing = NO;
    self.capturedCount = 0;
}

#pragma mark - AVCaptureMetadataOutputObjectsDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
    
    AVMetadataFaceObject *detectedFace = nil;
    for (AVMetadataObject *obj in metadataObjects) {
        if ([obj.type isEqualToString:AVMetadataObjectTypeFace]) {
            detectedFace = (AVMetadataFaceObject *)obj;
            break;
        }
    }
    
    if (!detectedFace) {
        self.isCurrentFrameQualified = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidDetectFace:isCentered:isDistanceQualified:distanceRatio:)]) {
                [self.delegate cameraManagerDidDetectFace:CGRectZero isCentered:NO isDistanceQualified:NO distanceRatio:0.0];
            }
        });
        return;
    }
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        // Transform coordinates into screen pixels using previewLayer
        AVMetadataObject *transformed = [strongSelf.previewLayer transformedMetadataObjectForMetadataObject:detectedFace];
        CGRect screenRect = transformed ? transformed.bounds : CGRectZero;
        
        CGFloat screenW = strongSelf.previewLayer.bounds.size.width;
        CGFloat screenH = strongSelf.previewLayer.bounds.size.height;
        if (screenW <= 0) screenW = [UIScreen mainScreen].bounds.size.width;
        if (screenH <= 0) screenH = [UIScreen mainScreen].bounds.size.height;
        
        CGFloat normCenterX = (screenRect.origin.x + screenRect.size.width / 2.0) / screenW;
        CGFloat normCenterY = (screenRect.origin.y + screenRect.size.height / 2.0) / screenH;
        CGFloat faceRatio = screenRect.size.height / screenH;
        
        // Easy-to-match centering & distance for fast user experience
        BOOL isCentered = (normCenterX >= 0.20 && normCenterX <= 0.80) && (normCenterY >= 0.20 && normCenterY <= 0.80);
        BOOL isDistanceQualified = (faceRatio >= 0.18 && faceRatio <= 0.80);
        
        strongSelf.isCurrentFrameQualified = (isCentered && isDistanceQualified);
        
        if ([strongSelf.delegate respondsToSelector:@selector(cameraManagerDidDetectFace:isCentered:isDistanceQualified:distanceRatio:)]) {
            [strongSelf.delegate cameraManagerDidDetectFace:screenRect isCentered:isCentered isDistanceQualified:isDistanceQualified distanceRatio:faceRatio];
        }
        
        if (strongSelf.isAutoCaptureActive && strongSelf.isCurrentFrameQualified) {
            [strongSelf processFrameFromCurrentStream];
        }
    });
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    self.latestRawImage = [self imageFromSampleBuffer:sampleBuffer];
    
    // If manual capture mode is triggered, capture consecutive frames directly
    if (self.isManualCapturing) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self processFrameFromCurrentStream];
        });
    }
}

- (void)processFrameFromCurrentStream {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - self.lastFrameTime < 0.12) { // ~8 fps
        return;
    }
    self.lastFrameTime = now;
    
    UIImage *image = self.latestRawImage;
    if (!image) return;
    
    self.capturedCount++;
    NSInteger index = self.capturedCount;
    
    // Save flat frames 1.jpg, 2.jpg... 10.jpg
    NSString *filePath = [self.sessionDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%ld.jpg", (long)index]];
    NSData *jpegData = UIImageJPEGRepresentation(image, 0.85);
    [jpegData writeToFile:filePath atomically:YES];
    
    if ([self.delegate respondsToSelector:@selector(cameraManagerDidCaptureFrame:index:total:)]) {
        [self.delegate cameraManagerDidCaptureFrame:image index:index total:self.targetFrameCount];
    }
    
    if (self.capturedCount >= self.targetFrameCount) {
        self.isAutoCaptureActive = NO;
        self.isManualCapturing = NO;
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidFinishCaptureWithFolder:)]) {
            [self.delegate cameraManagerDidFinishCaptureWithFolder:self.sessionDirectory];
        }
    }
}

- (UIImage *)imageFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return nil;
    
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
    CIContext *context = [CIContext contextWithOptions:nil];
    CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
    
    UIImage *image = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationRight];
    CGImageRelease(cgImage);
    return image;
}

@end
