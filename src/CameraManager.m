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
@property (nonatomic, strong) UIImage *latestRawImage;
@end

@implementation CameraManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _targetFrameCount = 10;
        _isAutoCaptureActive = NO;
        _capturedCount = 0;
        _lastFrameTime = 0;
        _isCurrentFrameQualified = NO;
        _captureQueue = dispatch_queue_create("com.acbface.captureQueue", DISPATCH_QUEUE_SERIAL);
        [self setupSession];
    }
    return self;
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
        if ([self.metadataOutput.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) {
            self.metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeFace];
        }
    }
    
    // Preview Layer
    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.captureSession];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    
    AVCaptureConnection *connection = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (connection.isVideoMirroringSupported) {
        connection.videoMirrored = YES;
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

- (void)startAutoCapture {
    NSString *tempDir = NSTemporaryDirectory();
    NSString *sessionName = [NSString stringWithFormat:@"login_frames_%ld", (long)[[NSDate date] timeIntervalSince1970]];
    self.sessionDirectory = [tempDir stringByAppendingPathComponent:sessionName];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:self.sessionDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    
    self.capturedCount = 0;
    self.lastFrameTime = 0;
    self.isAutoCaptureActive = YES;
}

- (void)resetCapture {
    self.isAutoCaptureActive = NO;
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
    
    CGRect bounds = detectedFace.bounds;
    CGFloat centerX = bounds.origin.x + bounds.size.width / 2.0;
    CGFloat centerY = bounds.origin.y + bounds.size.height / 2.0;
    CGFloat faceRatio = bounds.size.height;
    
    // Kiem tra goc quay mat (LoginFaceValidator: nhin thang)
    BOOL isLookingStraight = YES;
    if (detectedFace.hasYawAngle && fabs(detectedFace.yawAngle) > 12.0) {
        isLookingStraight = NO;
    }
    if (detectedFace.hasRollAngle && fabs(detectedFace.rollAngle) > 12.0) {
        isLookingStraight = NO;
    }
    
    // Kiem tra tam mat vao giua khung oval
    BOOL isCentered = (centerX >= 0.35 && centerX <= 0.65) && (centerY >= 0.32 && centerY <= 0.68) && isLookingStraight;
    // Cu ly chuan cho Login: mat chiem 35% - 62% man hinh
    BOOL isDistanceQualified = (faceRatio >= 0.35 && faceRatio <= 0.62);
    
    self.isCurrentFrameQualified = (isCentered && isDistanceQualified);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidDetectFace:isCentered:isDistanceQualified:distanceRatio:)]) {
            [self.delegate cameraManagerDidDetectFace:bounds isCentered:isCentered isDistanceQualified:isDistanceQualified distanceRatio:faceRatio];
        }
    });
    
    if (self.isAutoCaptureActive && self.isCurrentFrameQualified) {
        [self processAutoCaptureFrame];
    }
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    self.latestRawImage = [self imageFromSampleBuffer:sampleBuffer];
}

- (void)processAutoCaptureFrame {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - self.lastFrameTime < 0.14) { // ~7 fps giong app goc
        return;
    }
    self.lastFrameTime = now;
    
    UIImage *image = self.latestRawImage;
    if (!image) return;
    
    self.capturedCount++;
    NSInteger index = self.capturedCount;
    
    // Luu truc tiep cac anh phang (1.jpg, 2.jpg...) giong PhotoSaver.writeFlat cua LoginFace
    NSString *filePath = [self.sessionDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%ld.jpg", (long)index]];
    NSData *jpegData = UIImageJPEGRepresentation(image, 0.85);
    [jpegData writeToFile:filePath atomically:YES];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(cameraManagerDidCaptureFrame:index:total:)]) {
            [self.delegate cameraManagerDidCaptureFrame:image index:index total:self.targetFrameCount];
        }
    });
    
    if (self.capturedCount >= self.targetFrameCount) {
        self.isAutoCaptureActive = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(cameraManagerDidFinishCaptureWithFolder:)]) {
                [self.delegate cameraManagerDidFinishCaptureWithFolder:self.sessionDirectory];
            }
        });
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
