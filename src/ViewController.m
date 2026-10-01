#import "ViewController.h"
#import "LoginFaceOverlayView.h"
#import "ZipManager.h"
#import <AudioToolbox/AudioToolbox.h>

#import "ACBLogger.h"

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

// Progress Indicator Dots
@property (nonatomic, strong) UIView *dotsContainerView;
@property (nonatomic, strong) NSMutableArray<UIView *> *dotViews;
@property (nonatomic, strong) NSMutableArray<UILabel *> *dotLabels;

// Register Mode Phase State
// Phases 0-4 for 5 shots: [gần, gần, thẳng, xa, xa]
// Expected status per phase: [TooClose, TooClose, FaceOK, TooFar, TooFar]
@property (nonatomic, assign) NSInteger registerPhase;         // 0..4
@property (nonatomic, assign) NSInteger phaseDistanceOKCount;  // consecutive frames matching expected distance

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    
    @try {
        if (!self.cardNumber || self.cardNumber.length == 0) {
            self.cardNumber = @"18601771";
        }
        self.userName = @"NGUYEN VAN A";
        self.bankType = @"ACB";
        
        // Mode-dependent round count
        if (self.captureMode == ACBCaptureModeRegister) {
            self.totalRounds = 2;   // Chuyển khoản (CK): 2 giai đoạn (1. Ảnh xa -> Đưa mặt lại gần -> 2. Ảnh gần)
        } else {
            self.totalRounds = 10;  // Đăng nhập: 10 ảnh liên tiếp
        }
        self.currentRound = 1;
        self.consecutiveOKCount = 0;
        self.isCapturingRound = NO;
        self.isTransitioningRound = NO;
        self.registerPhase = 0;
        self.phaseDistanceOKCount = 0;
        
        [self prepareNewSessionDirectory];
        
        [self setupHeaderUI];
        [self setupViewFinder];
        [self setupBottomControls];
        [self setupUploadDialog];
        
        self.uploader = [[ACBUploader alloc] init];
        self.uploader.delegate = self;
        self.uploader.serverBaseUrl = self.serverBaseUrl;
    } @catch (NSException *e) {
        NSLog(@"[ACBFace] CRASH in viewDidLoad: %@ - %@", e.name, e.reason);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    @try {
        [self.cameraManager requestPermissionAndStart];
    } @catch (NSException *e) {
        NSLog(@"[ACBFace] CRASH in viewDidAppear: %@ - %@", e.name, e.reason);
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    @try {
        [self.cameraManager stopSession];
    } @catch (NSException *e) {
        NSLog(@"[ACBFace] CRASH in viewWillDisappear: %@ - %@", e.name, e.reason);
    }
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
    CGFloat safeTop = 20.0;
    if (@available(iOS 11.0, *)) {
        UIWindow *window = [UIApplication sharedApplication].windows.firstObject;
        if (window && window.safeAreaInsets.top > 0) {
            safeTop = window.safeAreaInsets.top;
        }
    }
    
    // 1. Back button "‹ Quay lại"
    self.backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.backButton.frame = CGRectMake(12, safeTop + 2, 85, 30);
    [self.backButton setTitle:@"‹ Quay lại" forState:UIControlStateNormal];
    [self.backButton setTitleColor:[UIColor colorWithWhite:0.25 alpha:1.0] forState:UIControlStateNormal];
    self.backButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [self.backButton addTarget:self action:@selector(onBackTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.backButton];
    
    // 2. Title
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, safeTop + 4, screenW, 26)];
    self.titleLabel.text = (self.captureMode == ACBCaptureModeRegister)
        ? @"Khuôn mặt Chuyển khoản (CK)"
        : @"Khuôn mặt Đăng nhập";
    self.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    self.titleLabel.textColor = [UIColor blackColor];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.titleLabel];
    
    // 3. Subtitle / Progress
    self.progressLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, safeTop + 28, screenW, 18)];
    if (self.captureMode == ACBCaptureModeRegister) {
        self.progressLabel.text = [NSString stringWithFormat:@"Bước %ld / %ld: %@", (long)self.currentRound, (long)self.totalRounds, (self.currentRound == 1 ? @"Ảnh xa" : @"Ảnh gần")];
    } else {
        self.progressLabel.text = [NSString stringWithFormat:@"Ảnh %ld / %ld", (long)self.currentRound, (long)self.totalRounds];
    }
    self.progressLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.progressLabel.textColor = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0];
    self.progressLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.progressLabel];

    // 4. Color Dots Indicator Row
    [self setupDotsIndicatorWithSafeTop:safeTop];
}

- (void)setupDotsIndicatorWithSafeTop:(CGFloat)safeTop {
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    self.dotsContainerView = [[UIView alloc] initWithFrame:CGRectMake(0, safeTop + 48, screenW, 32)];
    self.dotsContainerView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.dotsContainerView];

    self.dotViews = [NSMutableArray array];
    self.dotLabels = [NSMutableArray array];

    NSInteger count = self.totalRounds;
    if (self.captureMode == ACBCaptureModeRegister) {
        // 2 stages: Ảnh xa, Ảnh gần (chuẩn ACB New: Stage.FAR -> Prompt "Đưa mặt lại gần" -> Stage.CLOSE)
        NSArray *labels = @[@"Ảnh xa", @"Ảnh gần"];
        CGFloat dotSize = 14.0;
        CGFloat itemW = 88.0;
        CGFloat totalW = count * itemW;
        CGFloat startX = (screenW - totalW) / 2.0;

        for (NSInteger i = 0; i < count; i++) {
            UIView *itemBox = [[UIView alloc] initWithFrame:CGRectMake(startX + i * itemW, 0, itemW, 32)];
            
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake((itemW - dotSize) / 2.0, 0, dotSize, dotSize)];
            dot.layer.cornerRadius = dotSize / 2.0;
            dot.clipsToBounds = YES;
            [itemBox addSubview:dot];
            [self.dotViews addObject:dot];

            UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, dotSize + 2, itemW, 14)];
            lbl.text = labels[i];
            lbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
            lbl.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
            lbl.textAlignment = NSTextAlignmentCenter;
            [itemBox addSubview:lbl];
            [self.dotLabels addObject:lbl];

            [self.dotsContainerView addSubview:itemBox];
        }
    } else {
        // 10 dots compact row
        CGFloat dotSize = 10.0;
        CGFloat spacing = 8.0;
        CGFloat totalW = count * dotSize + (count - 1) * spacing;
        CGFloat startX = (screenW - totalW) / 2.0;

        for (NSInteger i = 0; i < count; i++) {
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(startX + i * (dotSize + spacing), 10, dotSize, dotSize)];
            dot.layer.cornerRadius = dotSize / 2.0;
            dot.clipsToBounds = YES;
            [self.dotsContainerView addSubview:dot];
            [self.dotViews addObject:dot];
        }
    }

    [self updateDotsIndicator];
}

- (void)updateDotsIndicator {
    for (NSInteger i = 0; i < self.dotViews.count; i++) {
        UIView *dot = self.dotViews[i];
        if (i < self.currentRound - 1) {
            // Đã chụp xong: Xanh lá
            dot.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
            dot.layer.borderWidth = 0;
            dot.transform = CGAffineTransformIdentity;
        } else if (i == self.currentRound - 1) {
            // Đang chụp hiện tại: Xanh ACB đậm, viền nổi bật
            dot.backgroundColor = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0];
            dot.layer.borderColor = [UIColor colorWithRed:0.0 green:0.45 blue:0.85 alpha:1.0].CGColor;
            dot.layer.borderWidth = 2.0;
            dot.transform = CGAffineTransformMakeScale(1.2, 1.2);
        } else {
            // Chưa chụp: Xám nhạt
            dot.backgroundColor = [UIColor colorWithRed:0.85 green:0.88 blue:0.91 alpha:1.0];
            dot.layer.borderWidth = 0;
            dot.transform = CGAffineTransformIdentity;
        }
    }

    // Cập nhật text màu nhãn ở mode CK
    if (self.captureMode == ACBCaptureModeRegister) {
        for (NSInteger i = 0; i < self.dotLabels.count; i++) {
            UILabel *lbl = self.dotLabels[i];
            if (i == self.currentRound - 1) {
                lbl.textColor = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0];
                lbl.font = [UIFont boldSystemFontOfSize:11];
            } else if (i < self.currentRound - 1) {
                lbl.textColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
                lbl.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
            } else {
                lbl.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
                lbl.font = [UIFont systemFontOfSize:10];
            }
        }
    }
}

- (void)setupViewFinder {
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    
    // 3:4 aspect ratio container, width = 89.2% screen width
    CGFloat containerW = floor(screenW * 0.892);
    CGFloat containerH = floor(containerW * (4.0 / 3.0));
    CGFloat containerX = (screenW - containerW) / 2.0;
    
    CGFloat safeTop = 20.0;
    if (@available(iOS 11.0, *)) {
        UIWindow *win = [UIApplication sharedApplication].windows.firstObject;
        if (win && win.safeAreaInsets.top > 0) safeTop = win.safeAreaInsets.top;
    }
    CGFloat containerY = safeTop + 84;
    
    self.viewFinderContainer = [[UIView alloc] initWithFrame:CGRectMake(containerX, containerY, containerW, containerH)];
    self.viewFinderContainer.clipsToBounds = YES;
    self.viewFinderContainer.backgroundColor = [UIColor blackColor];
    self.viewFinderContainer.userInteractionEnabled = YES;
    UITapGestureRecognizer *tapFinder = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onViewFinderTapped)];
    [self.viewFinderContainer addGestureRecognizer:tapFinder];
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
    self.overlayView.userInteractionEnabled = NO;
    [self.viewFinderContainer addSubview:self.overlayView];
    self.cameraManager.ovalRect = self.overlayView.ovalRect;
    NSLog(@"[ACBFace] viewFinderBounds: %@, ovalRect: %@", NSStringFromCGRect(self.cameraManager.viewFinderBounds), NSStringFromCGRect(self.cameraManager.ovalRect));
    
    // Flash View for Shutter Effect
    self.flashView = [[UIView alloc] initWithFrame:self.viewFinderContainer.bounds];
    self.flashView.backgroundColor = [UIColor whiteColor];
    self.flashView.alpha = 0.0;
    self.flashView.userInteractionEnabled = NO;
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
    CGFloat availableBottom = (screenH - 36) - viewFinderBottom;
    CGFloat guideH = 50.0;
    CGFloat guideY = viewFinderBottom + (availableBottom - guideH) / 2.0;
    if (guideY < viewFinderBottom + 12) {
        guideY = viewFinderBottom + 12;
    }
    
    self.guideLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, guideY, screenW - 48, guideH)];
    self.guideLabel.text = @"Vui lòng đảm bảo khuôn mặt nằm trong khung, nhìn thẳng vào camera";
    self.guideLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.guideLabel.textColor = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0];
    self.guideLabel.textAlignment = NSTextAlignmentCenter;
    self.guideLabel.numberOfLines = 2;
    [self.view addSubview:self.guideLabel];
    
    // 2. Real-time Diagnostic status banner
    self.diagLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, screenH - 30, screenW - 20, 20)];
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

#pragma mark - CameraManagerDelegate

- (void)cameraManagerDidUpdateDiagnostic:(NSString *)diagnosticInfo {
    self.diagLabel.text = diagnosticInfo;
}

- (void)cameraManagerDidUpdateFaceStatus:(ACBFaceStatus)status message:(NSString *)message faceBounds:(CGRect)screenRect {
    if (self.isCapturingRound || self.isTransitioningRound) return;
    
    // ── REGISTER MODE: distance-phase-driven auto capture ──────────────────
    if (self.captureMode == ACBCaptureModeRegister) {
        [self handleRegisterModeStatus:status];
        return;
    }
    
    // ── LOGIN MODE (default): FaceOK consecutive-count auto capture ─────────
    self.guideLabel.text = message;
    
    switch (status) {
        case ACBFaceStatusFaceOK:
            [self.overlayView setAcbStatus:0]; // Green
            self.consecutiveOKCount++;
            ACBLog([NSString stringWithFormat:@"FaceOK consecutiveOKCount=%ld round=%ld", (long)self.consecutiveOKCount, (long)self.currentRound]);
            
            // Require 2 consecutive stable frames (~50ms) for fast and reliable auto-capture
            if (self.consecutiveOKCount >= 2) {
                ACBLog([NSString stringWithFormat:@"AUTO CAPTURE triggered for round %ld", (long)self.currentRound]);
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

// ── Register/CK Mode Phase Engine (100% Parity với ACB New TransferFace) ──
// Phase 0: Ảnh xa  — Vui lòng đảm bảo khuôn mặt nằm trong khung, nhìn thẳng vào camera
// Phase transition: Hiện prompt "Đưa mặt lại gần" đếm ngược 2 giây
// Phase 1: Ảnh gần — Đưa mặt lại gần, lấp đầy khung hướng dẫn

static NSString * const kRegisterPhaseInstructions[] = {
    @"Vui lòng đảm bảo khuôn mặt nằm trong khung, nhìn thẳng vào camera", // 0: Ảnh xa
    @"Đưa mặt lại gần, lấp đầy khung hướng dẫn",                           // 1: Ảnh gần
};

- (BOOL)registerPhaseMatchesStatus:(ACBFaceStatus)status {
    switch (self.registerPhase) {
        case 0: // Giai đoạn 1: Ảnh xa
            return (status == ACBFaceStatusFaceOK || status == ACBFaceStatusTooFar);
        case 1: // Giai đoạn 2: Ảnh gần
            return (status == ACBFaceStatusTooClose || status == ACBFaceStatusFaceOK);
        default:
            return NO;
    }
}

- (void)handleRegisterModeStatus:(ACBFaceStatus)status {
    if (status == ACBFaceStatusNoFace || status == ACBFaceStatusNotCentered || status == ACBFaceStatusMultipleFaces) {
        [self.overlayView setAcbStatus:3]; // Blue — no face
        self.phaseDistanceOKCount = 0;
        self.guideLabel.text = @"Vui lòng đảm bảo khuôn mặt nằm trong khung";
        return;
    }
    
    NSString *instruction = (self.registerPhase < 2) ? kRegisterPhaseInstructions[self.registerPhase] : @"";
    self.guideLabel.text = instruction;
    
    if ([self registerPhaseMatchesStatus:status]) {
        self.phaseDistanceOKCount++;
        [self.overlayView setAcbStatus:0]; // Green — correct distance for stage!
        ACBLog([NSString stringWithFormat:@"[Register] Phase %ld distance OK count=%ld", (long)self.registerPhase, (long)self.phaseDistanceOKCount]);
        
        if (self.phaseDistanceOKCount >= 2) {
            // Distance stable — auto capture this phase
            ACBLog([NSString stringWithFormat:@"[Register] Phase %ld AUTO CAPTURE triggered", (long)self.registerPhase]);
            [self captureCurrentRound];
        }
    } else {
        // Wrong distance for this stage
        self.phaseDistanceOKCount = 0;
        if (self.registerPhase == 0) {
            // Đang chụp ảnh xa nhưng mặt quá gần
            [self.overlayView setAcbStatus:2]; // Orange
            self.guideLabel.text = @"Di chuyển ra xa camera hơn";
        } else {
            // Đang chụp ảnh gần nhưng mặt còn xa
            [self.overlayView setAcbStatus:1]; // Orange
            self.guideLabel.text = @"Đưa khuôn mặt lại gần camera hơn";
        }
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

#pragma mark - Capture Orchestrator

- (void)onViewFinderTapped {
    if (!self.isCapturingRound && !self.isTransitioningRound) {
        ACBLog(@"User tapped viewfinder - manual capture triggered");
        [self captureCurrentRound];
    }
}

- (void)captureCurrentRound {
    if (self.isCapturingRound || self.isTransitioningRound) return;
    self.isCapturingRound = YES;
    self.consecutiveOKCount = 0;
    
    // Immediate UI feedback
    self.guideLabel.text = @"Đang chụp ảnh...";
    
    NSInteger capturedIndex = self.currentRound;
    ACBLog([NSString stringWithFormat:@"captureCurrentRound started for round %ld / %ld", (long)capturedIndex, (long)self.totalRounds]);
    
    [self.cameraManager captureStillFrameWithCompletion:^(UIImage * _Nullable image) {
        if (!image) {
            ACBLog([NSString stringWithFormat:@"Capture failed for round %ld - retrying", (long)capturedIndex]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                self.isCapturingRound = NO;
                self.guideLabel.text = @"Vui lòng giữ yên khuôn mặt";
            });
            return;
        }
        
        // Instant shutter sound & flash feedback upon successful capture
        AudioServicesPlaySystemSound(1108);
        [UIView animateWithDuration:0.08 animations:^{
            self.flashView.alpha = 0.85;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.12 animations:^{
                self.flashView.alpha = 0.0;
            }];
        }];
        
        // Save frame as "{index}.jpg" in session directory (matching ACB NEW: 1.jpg ... 10.jpg)
        NSString *filePath = [self.sessionDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%ld.jpg", (long)capturedIndex]];
        NSData *jpegData = UIImageJPEGRepresentation(image, 0.90);
        BOOL saved = [jpegData writeToFile:filePath atomically:YES];
        
        ACBLog([NSString stringWithFormat:@"Saved frame %ld: %@ (%lu bytes, ok=%d)", (long)capturedIndex, filePath, (unsigned long)jpegData.length, saved]);
        
        // Update dots indicator state immediately
        [self updateDotsIndicator];
        
        // Check if all rounds are finished
        if (capturedIndex >= self.totalRounds) {
            self.isCapturingRound = NO;
            self.guideLabel.text = @"Chụp thành công, đang tải lên...";
            [self startUploadFlow];
            return;
        }
        
        // Otherwise, run round transition countdown (ACB NEW: acb_login_next_shot_prompt)
        [self startRoundTransitionCountdown];
    }];
}

- (void)startRoundTransitionCountdown {
    self.isTransitioningRound = YES;
    self.isCapturingRound = YES; // Lock capture during countdown
    self.consecutiveOKCount = 0;
    self.phaseDistanceOKCount = 0;
    
    self.promptBox.hidden = NO;
    
    // Choose prompt based on mode
    if (self.captureMode == ACBCaptureModeRegister) {
        // Next phase is CLOSE (Ảnh gần) -> Prompt: "Đưa mặt lại gần" (chuẩn ACB New)
        self.promptTextLabel.text = @"Đưa mặt lại gần\nDi chuyển lại gần camera hơn rồi giữ yên";
    } else {
        self.promptTextLabel.text = @"Hãy di chuyển một chút rồi tiếp tục ảnh tiếp theo";
    }
    
    self.countdownSeconds = 2;
    self.promptCountdownLabel.text = [NSString stringWithFormat:@"Bắt đầu sau %ld giây", (long)self.countdownSeconds];
    
    [self.countdownTimer invalidate];
    self.countdownTimer = [NSTimer timerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(onCountdownTick)
                                                userInfo:nil
                                                 repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.countdownTimer forMode:NSRunLoopCommonModes];
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
        [self.overlayView setAcbStatus:3];
        
        if (self.captureMode == ACBCaptureModeRegister) {
            self.registerPhase++;
            self.phaseDistanceOKCount = 0;
            self.progressLabel.text = [NSString stringWithFormat:@"Bước %ld / %ld: %@", (long)self.currentRound, (long)self.totalRounds, (self.currentRound == 1 ? @"Ảnh xa" : @"Ảnh gần")];
            NSString *instruction = (self.registerPhase < 2) ? kRegisterPhaseInstructions[self.registerPhase] : @"";
            self.guideLabel.text = instruction;
            ACBLog([NSString stringWithFormat:@"[Register] Countdown done. Advanced to phase %ld, round %ld", (long)self.registerPhase, (long)self.currentRound]);
        } else {
            self.progressLabel.text = [NSString stringWithFormat:@"Ảnh %ld / %ld", (long)self.currentRound, (long)self.totalRounds];
            self.guideLabel.text = @"Vui lòng đảm bảo khuôn mặt nằm trong khung, nhìn thẳng vào camera";
            ACBLog([NSString stringWithFormat:@"Countdown completed. Ready for round %ld / %ld", (long)self.currentRound, (long)self.totalRounds]);
        }
        
        [self updateDotsIndicator];
        
        self.consecutiveOKCount = 0;
        self.isTransitioningRound = NO;
        self.isCapturingRound = NO;
    }
}

#pragma mark - Zip Packaging & Chunked Upload Flow

- (void)startUploadFlow {
    [self.cameraManager stopSession];
    
    // Show upload dialog
    self.uploadDialogOverlay.hidden = NO;
    [self.uploadSpinner startAnimating];
    self.uploadProgressBar.progress = 0.05;
    self.uploadChunkLabel.text = @"Đang nén dữ liệu...";
    ACBLog([NSString stringWithFormat:@"startUploadFlow: sessionDirectory=%@, serverBaseUrl=%@", self.sessionDirectory, self.serverBaseUrl]);
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Safety: verify all frames exist before zipping
        // For CK / Register mode (2 shots: 1=Ảnh xa, 2=Ảnh gần):
        // 1..5 is far shot (1.jpg), 6..10 is close shot (2.jpg) -> 10 valid JPEG frames for backend
        for (int i = 1; i <= 10; i++) {
            NSString *framePath = [self.sessionDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.jpg", i]];
            if (![[NSFileManager defaultManager] fileExistsAtPath:framePath]) {
                NSInteger srcIndex = (self.totalRounds == 2) ? (i <= 5 ? 1 : 2) : 1;
                NSString *srcPath = [self.sessionDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%ld.jpg", (long)srcIndex]];
                if (![[NSFileManager defaultManager] fileExistsAtPath:srcPath]) {
                    srcPath = [self.sessionDirectory stringByAppendingPathComponent:@"1.jpg"];
                }
                [[NSFileManager defaultManager] copyItemAtPath:srcPath toPath:framePath error:nil];
            }
        }
        
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
        
        // Show brief success alert then auto-dismiss back to mode selection screen
        NSString *modeLabel = (self.captureMode == ACBCaptureModeRegister) ? @"Khuôn mặt CK" : @"Khuôn mặt Đăng nhập";
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"✅ Hoàn tất thành công"
            message:[NSString stringWithFormat:@"Đã tải lên %@ thành công!\nSố thẻ: %@",
                     modeLabel, self.cardNumber]
            preferredStyle:UIAlertControllerStyleAlert];
        
        [self presentViewController:alert animated:YES completion:nil];
        
        // Auto-dismiss after 1.5 seconds → return to CardInputViewController
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:^{
                [self dismissViewControllerAnimated:YES completion:nil];
            }];
        });
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
    self.guideLabel.text = @"Vui lòng đảm bảo khuôn mặt nằm trong khung, nhìn thẳng vào camera";
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

