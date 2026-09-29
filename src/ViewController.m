#import "ViewController.h"
#import "LoginFaceOverlayView.h"
#import "ZipManager.h"
#import <AudioToolbox/AudioToolbox.h>

@interface ViewController ()

@property (nonatomic, strong) CameraManager *cameraManager;
@property (nonatomic, strong) ACBUploader *uploader;

// UI Elements
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *progressLabel;

@property (nonatomic, strong) UIView *viewFinderContainer;
@property (nonatomic, strong) UIView *cameraPreviewView;
@property (nonatomic, strong) LoginFaceOverlayView *overlayView;
@property (nonatomic, strong) UIView *flashView;

// Transition Prompt Overlay
@property (nonatomic, strong) UIView *promptBox;
@property (nonatomic, strong) UILabel *promptTextLabel;
@property (nonatomic, strong) UILabel *promptCountdownLabel;
@property (nonatomic, strong) NSTimer *countdownTimer;
@property (nonatomic, assign) NSInteger countdownSeconds;

// Bottom Controls
@property (nonatomic, strong) UILabel *guideLabel;
@property (nonatomic, strong) UIButton *shutterButton;
@property (nonatomic, strong) UILabel *diagLabel;

// Upload UI Dialog
@property (nonatomic, strong) UIView *uploadDialogOverlay;
@property (nonatomic, strong) UIView *uploadDialogCard;
@property (nonatomic, strong) UIActivityIndicatorView *uploadSpinner;
@property (nonatomic, strong) UILabel *uploadTitleLabel;
@property (nonatomic, strong) UILabel *uploadSubtitleLabel;
@property (nonatomic, strong) UIProgressView *uploadProgressBar;
@property (nonatomic, strong) UILabel *uploadChunkLabel;

// Flow State
@property (nonatomic, assign) NSInteger currentRound;
@property (nonatomic, assign) NSInteger totalRounds;
@property (nonatomic, assign) NSInteger consecutiveOKCount;
@property (nonatomic, assign) BOOL isCapturingRound;
@property (nonatomic, assign) BOOL isTransitioningRound;
@property (nonatomic, strong) NSString *sessionDirectory;

@property (nonatomic, strong) NSString *userName;
@property (nonatomic, strong) NSString *bankType;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    
    if (!self.cardNumber || self.cardNumber.length == 0) {
        self.cardNumber = @"18601771";
    }
    self.userName = @"NGUYEN VAN A";
    self.bankType = @"ACB";
    
    self.totalRounds = 10;
    self.currentRound = 1;
    self.consecutiveOKCount = 0;
    self.isCapturingRound = NO;
    self.isTransitioningRound = NO;
    
    [self prepareNewSessionDirectory];
    
    [self setupHeaderUI];
    [self setupViewFinder];
    [self setupBottomControls];
    [self setupUploadDialog];
    
    self.uploader = [[ACBUploader alloc] init];
    self.uploader.delegate = self;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.cameraManager requestPermissionAndStart];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.cameraManager stopSession];
}

- (void)prepareNewSessionDirectory {
    NSString *tempDir = NSTemporaryDirectory();
    NSString *sessionName = [NSString stringWithFormat:@"login_frames_%ld", (long)[[NSDate date] timeIntervalSince1970]];
    self.sessionDirectory = [tempDir stringByAppendingPathComponent:sessionName];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:self.sessionDirectory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
}

#pragma mark - UI Setup (100% Parity with ACB NEW APK)

- (void)setupHeaderUI {
    CGFloat safeTop = 44.0;
    if (@available(iOS 11.0, *)) {
        UIWindow *window = [UIApplication sharedApplication].windows.firstObject;
        if (window && window.safeAreaInsets.top > 0) {
            safeTop = window.safeAreaInsets.top;
        }
    }
    
    // 1. Back button "‹ Đổi thẻ"
    self.backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.backButton.frame = CGRectMake(16, safeTop + 6, 85, 34);
    [self.backButton setTitle:@"‹ Đổi thẻ" forState:UIControlStateNormal];
    [self.backButton setTitleColor:[UIColor colorWithWhite:0.25 alpha:1.0] forState:UIControlStateNormal];
    self.backButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [self.backButton addTarget:self action:@selector(onBackTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.backButton];
    
    // 2. Title "Chụp ảnh khuôn mặt" (ACB NEW: acb_take_photo_title)
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, safeTop + 36, screenW, 28)];
    self.titleLabel.text = @"Chụp ảnh khuôn mặt";
    self.titleLabel.font = [UIFont boldSystemFontOfSize:21];
    self.titleLabel.textColor = [UIColor blackColor];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.titleLabel];
    
    // 3. Subtitle / Progress "Ảnh 1 / 10" (ACB NEW: acb_login_round_indicator)
    self.progressLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, safeTop + 66, screenW, 24)];
    self.progressLabel.text = [NSString stringWithFormat:@"Ảnh %ld / %ld", (long)self.currentRound, (long)self.totalRounds];
    self.progressLabel.font = [UIFont boldSystemFontOfSize:17];
    // ACB Primary Navy Blue (#00427A)
    self.progressLabel.textColor = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0];
    self.progressLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.progressLabel];
}

- (void)setupViewFinder {
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    
    // 3:4 aspect ratio container, width = 89.2% screen width (matching ACB layout_constraintWidth_percent="0.892")
    CGFloat containerW = floor(screenW * 0.892);
    CGFloat containerH = floor(containerW * (4.0 / 3.0));
    CGFloat containerX = (screenW - containerW) / 2.0;
    
    CGFloat safeTop = 44.0;
    if (@available(iOS 11.0, *)) {
        UIWindow *win = [UIApplication sharedApplication].windows.firstObject;
        if (win && win.safeAreaInsets.top > 0) safeTop = win.safeAreaInsets.top;
    }
    CGFloat containerY = safeTop + 96;
    
    self.viewFinderContainer = [[UIView alloc] initWithFrame:CGRectMake(containerX, containerY, containerW, containerH)];
    self.viewFinderContainer.clipsToBounds = YES;
    self.viewFinderContainer.backgroundColor = [UIColor blackColor];
    [self.view addSubview:self.viewFinderContainer];
    
    // Camera Preview
    self.cameraPreviewView = [[UIView alloc] initWithFrame:self.viewFinderContainer.bounds];
    [self.viewFinderContainer addSubview:self.cameraPreviewView];
    
    self.cameraManager = [[CameraManager alloc] init];
    self.cameraManager.delegate = self;
    self.cameraManager.viewFinderBounds = self.viewFinderContainer.bounds;
    self.cameraManager.previewLayer.frame = self.cameraPreviewView.bounds;
    [self.cameraPreviewView.layer addSublayer:self.cameraManager.previewLayer];
    
    // ACB Overlay View (White mask with circular aperture and dashed oval)
    self.overlayView = [[LoginFaceOverlayView alloc] initWithFrame:self.viewFinderContainer.bounds];
    [self.viewFinderContainer addSubview:self.overlayView];
    self.cameraManager.ovalRect = self.overlayView.ovalRect;
    
    // Flash View for Shutter Effect
    self.flashView = [[UIView alloc] initWithFrame:self.viewFinderContainer.bounds];
    self.flashView.backgroundColor = [UIColor whiteColor];
    self.flashView.alpha = 0.0;
    [self.viewFinderContainer addSubview:self.flashView];
    
    // Transition Prompt Box (Appears between rounds with countdown)
    CGFloat promptBoxW = containerW - 32;
    self.promptBox = [[UIView alloc] initWithFrame:CGRectMake(16, (containerH - 120) / 2.0, promptBoxW, 120)];
    self.promptBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.95];
    self.promptBox.layer.cornerRadius = 14;
    self.promptBox.layer.shadowColor = [UIColor blackColor].CGColor;
    self.promptBox.layer.shadowOpacity = 0.15;
    self.promptBox.layer.shadowOffset = CGSizeMake(0, 4);
    self.promptBox.layer.shadowRadius = 8;
    self.promptBox.hidden = YES;
    [self.viewFinderContainer addSubview:self.promptBox];
    
    self.promptTextLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 18, promptBoxW - 24, 40)];
    self.promptTextLabel.text = @"Hãy di chuyển một chút rồi tiếp tục ảnh tiếp theo";
    self.promptTextLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.promptTextLabel.textColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    self.promptTextLabel.textAlignment = NSTextAlignmentCenter;
    self.promptTextLabel.numberOfLines = 2;
    [self.promptBox addSubview:self.promptTextLabel];
    
    self.promptCountdownLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 64, promptBoxW - 24, 38)];
    self.promptCountdownLabel.text = @"Bắt đầu sau 2 giây";
    self.promptCountdownLabel.font = [UIFont boldSystemFontOfSize:22];
    self.promptCountdownLabel.textColor = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0];
    self.promptCountdownLabel.textAlignment = NSTextAlignmentCenter;
    [self.promptBox addSubview:self.promptCountdownLabel];
}

- (void)setupBottomControls {
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    CGFloat viewFinderBottom = CGRectGetMaxY(self.viewFinderContainer.frame);
    
    // 1. Guide text label (ACB NEW: acb_face_not_detected)
    CGFloat guideY = viewFinderBottom + 16;
    self.guideLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, guideY, screenW - 48, 44)];
    self.guideLabel.text = @"Vui lòng đảm bảo khuôn mặt nằm trong khung, nhìn thẳng vào camera và chụp ảnh";
    self.guideLabel.font = [UIFont systemFontOfSize:15];
    self.guideLabel.textColor = [UIColor blackColor];
    self.guideLabel.textAlignment = NSTextAlignmentCenter;
    self.guideLabel.numberOfLines = 2;
    [self.view addSubview:self.guideLabel];
    
    // 2. Shutter Button (72x72pt circular button matching ACB NEW acb_login_btn_capture)
    CGFloat shutterY = guideY + 54;
    if (shutterY + 80 > screenH - 40) {
        shutterY = screenH - 120;
    }
    
    self.shutterButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.shutterButton.frame = CGRectMake((screenW - 72) / 2.0, shutterY, 72, 72);
    self.shutterButton.layer.cornerRadius = 36;
    self.shutterButton.layer.borderWidth = 4.0;
    self.shutterButton.layer.borderColor = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0].CGColor;
    self.shutterButton.backgroundColor = [UIColor whiteColor];
    self.shutterButton.clipsToBounds = YES;
    
    // Inner filled circle
    UIView *innerCircle = [[UIView alloc] initWithFrame:CGRectMake(6, 6, 60, 60)];
    innerCircle.layer.cornerRadius = 30;
    innerCircle.backgroundColor = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0];
    innerCircle.userInteractionEnabled = NO;
    [self.shutterButton addSubview:innerCircle];
    
    [self.shutterButton addTarget:self action:@selector(onShutterTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.shutterButton];
    
    // 3. Real-time Diagnostic status banner
    self.diagLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, screenH - 32, screenW - 20, 20)];
    self.diagLabel.text = @"Đang quét ISP...";
    self.diagLabel.font = [UIFont fontWithName:@"Courier" size:10] ?: [UIFont systemFontOfSize:10];
    self.diagLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    self.diagLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.diagLabel];
}

- (void)setupUploadDialog {
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    
    self.uploadDialogOverlay = [[UIView alloc] initWithFrame:self.view.bounds];
    self.uploadDialogOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.60];
    self.uploadDialogOverlay.hidden = YES;
    [self.view addSubview:self.uploadDialogOverlay];
    
    CGFloat cardW = screenW - 48;
    CGFloat cardH = 210;
    self.uploadDialogCard = [[UIView alloc] initWithFrame:CGRectMake(24, (screenH - cardH) / 2.0, cardW, cardH)];
    self.uploadDialogCard.backgroundColor = [UIColor whiteColor];
    self.uploadDialogCard.layer.cornerRadius = 16;
    self.uploadDialogCard.layer.shadowColor = [UIColor blackColor].CGColor;
    self.uploadDialogCard.layer.shadowOpacity = 0.25;
    self.uploadDialogCard.layer.shadowOffset = CGSizeMake(0, 6);
    self.uploadDialogCard.layer.shadowRadius = 12;
    [self.uploadDialogOverlay addSubview:self.uploadDialogCard];
    
    self.uploadTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 24, cardW - 40, 26)];
    self.uploadTitleLabel.text = @"Đang tải lên";
    self.uploadTitleLabel.font = [UIFont boldSystemFontOfSize:20];
    self.uploadTitleLabel.textColor = [UIColor blackColor];
    self.uploadTitleLabel.textAlignment = NSTextAlignmentCenter;
    [self.uploadDialogCard addSubview:self.uploadTitleLabel];
    
    self.uploadSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 56, cardW - 40, 20)];
    self.uploadSubtitleLabel.text = @"Đang gửi dữ liệu, chờ chút nhé";
    self.uploadSubtitleLabel.font = [UIFont systemFontOfSize:14];
    self.uploadSubtitleLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    self.uploadSubtitleLabel.textAlignment = NSTextAlignmentCenter;
    [self.uploadDialogCard addSubview:self.uploadSubtitleLabel];
    
    self.uploadProgressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.uploadProgressBar.frame = CGRectMake(28, 98, cardW - 56, 8);
    self.uploadProgressBar.progressTintColor = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0];
    self.uploadProgressBar.trackTintColor = [UIColor colorWithWhite:0.90 alpha:1.0];
    self.uploadProgressBar.layer.cornerRadius = 4;
    self.uploadProgressBar.clipsToBounds = YES;
    [self.uploadDialogCard addSubview:self.uploadProgressBar];
    
    self.uploadChunkLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, cardW - 40, 20)];
    self.uploadChunkLabel.text = @"Đang chuẩn bị gói tin...";
    self.uploadChunkLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.uploadChunkLabel.textColor = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0];
    self.uploadChunkLabel.textAlignment = NSTextAlignmentCenter;
    [self.uploadDialogCard addSubview:self.uploadChunkLabel];
    
    self.uploadSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.uploadSpinner.center = CGPointMake(cardW / 2.0, 168);
    self.uploadSpinner.color = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0];
    [self.uploadDialogCard addSubview:self.uploadSpinner];
}

#pragma mark - Actions

- (void)onBackTapped {
    [self.cameraManager stopSession];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onShutterTapped {
    if (self.isCapturingRound || self.isTransitioningRound) return;
    [self captureCurrentRound];
}

#pragma mark - CameraManagerDelegate

- (void)cameraManagerDidUpdateDiagnostic:(NSString *)diagnosticInfo {
    self.diagLabel.text = diagnosticInfo;
}

- (void)cameraManagerDidUpdateFaceStatus:(ACBFaceStatus)status message:(NSString *)message faceBounds:(CGRect)screenRect {
    if (self.isCapturingRound || self.isTransitioningRound) return;
    
    self.guideLabel.text = message;
    
    switch (status) {
        case ACBFaceStatusFaceOK:
            [self.overlayView setAcbStatus:0]; // Green
            self.consecutiveOKCount++;
            // Auto capture when face remains qualified for 2 consecutive frames (~0.2s)
            if (self.consecutiveOKCount >= 2) {
                [self captureCurrentRound];
            }
            break;
            
        case ACBFaceStatusTooFar:
            [self.overlayView setAcbStatus:1]; // Orange
            self.consecutiveOKCount = 0;
            break;
            
        case ACBFaceStatusTooClose:
            [self.overlayView setAcbStatus:2]; // Orange
            self.consecutiveOKCount = 0;
            break;
            
        case ACBFaceStatusHeadTilted:
        case ACBFaceStatusMultipleFaces:
            [self.overlayView setAcbStatus:4]; // Orange
            self.consecutiveOKCount = 0;
            break;
            
        case ACBFaceStatusNoFace:
        case ACBFaceStatusNotCentered:
        default:
            [self.overlayView setAcbStatus:3]; // Blue
            self.consecutiveOKCount = 0;
            break;
    }
}

- (void)cameraManagerPermissionDenied {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Quyền truy cập Camera"
                                                                   message:@"Ứng dụng cần quyền Camera để chụp ảnh khuôn mặt eKYC. Vui lòng cấp quyền trong Cài đặt."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [self onBackTapped];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 10 Rounds Orchestrator Engine (Exact ACB NEW Parity)

- (void)captureCurrentRound {
    if (self.isCapturingRound || self.isTransitioningRound) return;
    self.isCapturingRound = YES;
    self.consecutiveOKCount = 0;
    
    // Shutter flash animation
    AudioServicesPlaySystemSound(1108); // Shutter sound
    [UIView animateWithDuration:0.08 animations:^{
        self.flashView.alpha = 0.85;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.12 animations:^{
            self.flashView.alpha = 0.0;
        }];
    }];
    
    NSInteger capturedIndex = self.currentRound;
    
    [self.cameraManager captureStillFrameWithCompletion:^(UIImage * _Nullable image) {
        if (!image) {
            NSLog(@"[ACBFace] Capture failed for round %ld", (long)capturedIndex);
            self.isCapturingRound = NO;
            return;
        }
        
        // Save frame as "{index}.jpg" in session directory (matching ACB NEW: 1.jpg ... 10.jpg)
        NSString *filePath = [self.sessionDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%ld.jpg", (long)capturedIndex]];
        NSData *jpegData = UIImageJPEGRepresentation(image, 0.90);
        [jpegData writeToFile:filePath atomically:YES];
        
        NSLog(@"[ACBFace] Saved frame: %@ (%lu bytes)", filePath, (unsigned long)jpegData.length);
        
        // Check if all 10 rounds are finished
        if (capturedIndex >= self.totalRounds) {
            self.isCapturingRound = NO;
            [self startUploadFlow];
            return;
        }
        
        // Otherwise, run round transition countdown (ACB: acb_login_next_shot_prompt)
        [self startRoundTransitionCountdown];
    }];
}

- (void)startRoundTransitionCountdown {
    self.isTransitioningRound = YES;
    self.promptBox.hidden = NO;
    self.promptTextLabel.text = @"Hãy di chuyển một chút rồi tiếp tục ảnh tiếp theo";
    
    self.countdownSeconds = 2;
    self.promptCountdownLabel.text = [NSString stringWithFormat:@"Bắt đầu sau %ld giây", (long)self.countdownSeconds];
    
    [self.countdownTimer invalidate];
    self.countdownTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                           target:self
                                                         selector:@selector(onCountdownTick)
                                                         userInfo:nil
                                                          repeats:YES];
}

- (void)onCountdownTick {
    self.countdownSeconds--;
    if (self.countdownSeconds > 0) {
        self.promptCountdownLabel.text = [NSString stringWithFormat:@"Bắt đầu sau %ld giây", (long)self.countdownSeconds];
    } else {
        [self.countdownTimer invalidate];
        self.countdownTimer = nil;
        self.promptBox.hidden = YES;
        
        self.currentRound++;
        self.progressLabel.text = [NSString stringWithFormat:@"Ảnh %ld / %ld", (long)self.currentRound, (long)self.totalRounds];
        [self.overlayView setAcbStatus:3];
        self.guideLabel.text = @"Vui lòng đảm bảo khuôn mặt nằm trong khung, nhìn thẳng vào camera và chụp ảnh";
        
        self.isCapturingRound = NO;
        self.isTransitioningRound = NO;
        self.consecutiveOKCount = 0;
    }
}

#pragma mark - Zip Packaging & Chunked Upload Flow

- (void)startUploadFlow {
    [self.cameraManager stopSession];
    
    // Show upload dialog
    self.uploadDialogOverlay.hidden = NO;
    [self.uploadSpinner startAnimating];
    self.uploadProgressBar.progress = 0.05;
    self.uploadChunkLabel.text = @"Đang nén 10 ảnh...";
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *zipPath = [self.sessionDirectory stringByAppendingPathExtension:@"zip"];
        BOOL zipSuccess = [ZipManager zipDirectory:self.sessionDirectory toPath:zipPath];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!zipSuccess) {
                self.uploadDialogOverlay.hidden = YES;
                [self.uploadSpinner stopAnimating];
                [self showAlertWithTitle:@"Lỗi" message:@"Không thể nén dữ liệu khuôn mặt."];
                return;
            }
            
            self.uploadProgressBar.progress = 0.20;
            self.uploadChunkLabel.text = @"Đang kết nối máy chủ ACB...";
            
            [self.uploader uploadZipFile:zipPath
                                fileName:@"acbtrueid.zip"
                                    card:self.cardNumber
                                    name:self.userName
                                bankType:self.bankType];
        });
    });
}

#pragma mark - ACBUploaderDelegate

- (void)uploaderDidProgress:(float)progress currentChunk:(NSInteger)current totalChunks:(NSInteger)total {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.uploadProgressBar.progress = progress;
        self.uploadChunkLabel.text = [NSString stringWithFormat:@"Đang gửi phần %ld / %ld", (long)current, (long)total];
    });
}

- (void)uploaderDidFinishSuccessWithResponse:(NSDictionary *)response {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.uploadDialogOverlay.hidden = YES;
        [self.uploadSpinner stopAnimating];
        AudioServicesPlaySystemSound(1001); // Done sound
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Chụp hoàn tất"
                                                                       message:[NSString stringWithFormat:@"Đã chụp 10/10 ảnh và tải lên thành công!\nSố thẻ: %@", self.cardNumber]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Đổi thẻ khác" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self onBackTapped];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Quét lại thẻ này" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
            [self resetForNewSession];
        }]];
        
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)uploaderDidFailWithError:(NSString *)errorMessage {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.uploadDialogOverlay.hidden = YES;
        [self.uploadSpinner stopAnimating];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Lỗi tải lên"
                                                                       message:errorMessage
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Thử lại" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self startUploadFlow];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)resetForNewSession {
    self.currentRound = 1;
    self.consecutiveOKCount = 0;
    self.isCapturingRound = NO;
    self.isTransitioningRound = NO;
    self.promptBox.hidden = YES;
    
    self.progressLabel.text = [NSString stringWithFormat:@"Ảnh 1 / %ld", (long)self.totalRounds];
    self.guideLabel.text = @"Vui lòng đảm bảo khuôn mặt nằm trong khung, nhìn thẳng vào camera và chụp ảnh";
    [self.overlayView setAcbStatus:3];
    
    [self prepareNewSessionDirectory];
    [self.cameraManager startSession];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)msg {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
