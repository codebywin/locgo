#import "CardInputViewController.h"
#import "ViewController.h"
#import <QuartzCore/QuartzCore.h>

@interface CardInputViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UILabel     *brandLabel;
@property (nonatomic, strong) UILabel     *brandSubtitleLabel;
@property (nonatomic, strong) UILabel     *titleLabel;
@property (nonatomic, strong) UIView      *inputContainer;
@property (nonatomic, strong) UILabel     *placeholderHeaderLabel;
@property (nonatomic, strong) UITextField *cardTextField;
// Two action buttons (like ACB New: BankAdaptActivity = Login, BADOOActivity = Register/CK)
@property (nonatomic, strong) UIButton    *loginButton;       // Chụp Đăng nhập (10 ảnh burst)
@property (nonatomic, strong) CAGradientLayer *loginGradient;
@property (nonatomic, strong) UIButton    *registerButton;    // Chụp CK / Đăng ký (color phase)
// Server settings
@property (nonatomic, strong) UISwitch    *localServerSwitch;
@property (nonatomic, strong) UILabel     *localServerLabel;
@property (nonatomic, strong) UITextField *serverTextField;
@end

@implementation CardInputViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.96 green:0.97 blue:0.98 alpha:1.0];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    [self.view addGestureRecognizer:tap];
    [self setupUI];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat screenW = self.view.bounds.size.width;
    CGFloat padX    = 24.0;
    CGFloat contentW = screenW - padX * 2;

    CGFloat safeTop = 50.0;
    if (@available(iOS 11.0, *)) {
        UIWindow *win = [UIApplication sharedApplication].windows.firstObject;
        if (win && win.safeAreaInsets.top > 0) safeTop = win.safeAreaInsets.top;
    }

    CGFloat y = safeTop + 50.0;

    self.brandLabel.frame        = CGRectMake(padX, y, contentW, 36);
    y = CGRectGetMaxY(self.brandLabel.frame) + 6;
    self.brandSubtitleLabel.frame = CGRectMake(padX, y, contentW, 20);
    y = CGRectGetMaxY(self.brandSubtitleLabel.frame) + 32;

    self.titleLabel.frame = CGRectMake(padX, y, contentW, 24);
    y = CGRectGetMaxY(self.titleLabel.frame) + 12;

    self.inputContainer.frame = CGRectMake(padX, y, contentW, 76);
    self.placeholderHeaderLabel.frame = CGRectMake(16, 10, contentW - 32, 18);
    self.cardTextField.frame          = CGRectMake(16, 32, contentW - 32, 34);
    y = CGRectGetMaxY(self.inputContainer.frame) + 20;

    // Server switch row
    self.localServerSwitch.frame = CGRectMake(padX, y, 51, 31);
    self.localServerLabel.frame  = CGRectMake(padX + 60, y + 4, contentW - 60, 24);
    y += 38;
    self.serverTextField.frame   = CGRectMake(padX, y, contentW, 36);
    y = CGRectGetMaxY(self.serverTextField.frame) + 24;

    // Login button (full width)
    self.loginButton.frame    = CGRectMake(padX, y, contentW, 54);
    self.loginGradient.frame  = self.loginButton.bounds;
    y = CGRectGetMaxY(self.loginButton.frame) + 14;

    // Register / CK button (full width, outline style)
    self.registerButton.frame = CGRectMake(padX, y, contentW, 54);
    self.registerButton.layer.cornerRadius = 14;
    self.registerButton.layer.borderWidth  = 2.0;
    self.registerButton.layer.borderColor  = [UIColor colorWithRed:0.0 green:0.32 blue:0.58 alpha:1.0].CGColor;
}

- (void)setupUI {
    // ── Branding ──────────────────────────────────────────────────
    self.brandLabel = [[UILabel alloc] init];
    self.brandLabel.text          = @"ACB Face";
    self.brandLabel.textColor     = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0];
    self.brandLabel.font          = [UIFont boldSystemFontOfSize:30];
    self.brandLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.brandLabel];

    self.brandSubtitleLabel = [[UILabel alloc] init];
    self.brandSubtitleLabel.text          = @"Xác thực khuôn mặt eKYC";
    self.brandSubtitleLabel.textColor     = [UIColor colorWithWhite:0.45 alpha:1.0];
    self.brandSubtitleLabel.font          = [UIFont systemFontOfSize:14];
    self.brandSubtitleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.brandSubtitleLabel];

    // ── Card number input ─────────────────────────────────────────
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text      = @"Số thẻ ngân hàng";
    self.titleLabel.textColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    self.titleLabel.font      = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [self.view addSubview:self.titleLabel];

    self.inputContainer = [[UIView alloc] init];
    self.inputContainer.backgroundColor    = [UIColor whiteColor];
    self.inputContainer.layer.cornerRadius = 14;
    self.inputContainer.layer.borderWidth  = 1.5;
    self.inputContainer.layer.borderColor  = [UIColor colorWithRed:0.86 green:0.89 blue:0.92 alpha:1.0].CGColor;
    self.inputContainer.layer.shadowColor  = [UIColor blackColor].CGColor;
    self.inputContainer.layer.shadowOpacity = 0.04;
    self.inputContainer.layer.shadowOffset  = CGSizeMake(0, 4);
    self.inputContainer.layer.shadowRadius  = 8;
    [self.view addSubview:self.inputContainer];

    self.placeholderHeaderLabel = [[UILabel alloc] init];
    self.placeholderHeaderLabel.text      = @"Nhập số thẻ ngân hàng";
    self.placeholderHeaderLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    self.placeholderHeaderLabel.font      = [UIFont systemFontOfSize:13];
    [self.inputContainer addSubview:self.placeholderHeaderLabel];

    self.cardTextField = [[UITextField alloc] init];
    self.cardTextField.text                   = @"18601771";
    self.cardTextField.textColor              = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0];
    self.cardTextField.font                   = [UIFont boldSystemFontOfSize:22];
    self.cardTextField.keyboardType           = UIKeyboardTypeNumberPad;
    self.cardTextField.returnKeyType          = UIReturnKeyDone;
    self.cardTextField.delegate               = self;
    [self.inputContainer addSubview:self.cardTextField];

    // ── Local server switch ───────────────────────────────────────
    self.localServerSwitch = [[UISwitch alloc] init];
    self.localServerSwitch.on        = YES;
    self.localServerSwitch.onTintColor = [UIColor colorWithRed:0.0 green:0.45 blue:0.85 alpha:1.0];
    [self.view addSubview:self.localServerSwitch];

    self.localServerLabel = [[UILabel alloc] init];
    self.localServerLabel.text      = @"Test Mock Server";
    self.localServerLabel.font      = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.localServerLabel.textColor = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0];
    [self.view addSubview:self.localServerLabel];

    self.serverTextField = [[UITextField alloc] init];
    self.serverTextField.text                  = @"http://192.168.80.227:8080";
    self.serverTextField.placeholder           = @"http://<PC-IP>:8080";
    self.serverTextField.font                  = [UIFont fontWithName:@"Courier" size:13] ?: [UIFont systemFontOfSize:13];
    self.serverTextField.textColor             = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0];
    self.serverTextField.backgroundColor       = [UIColor colorWithWhite:1.0 alpha:0.9];
    self.serverTextField.layer.cornerRadius    = 8;
    self.serverTextField.layer.borderWidth     = 1.0;
    self.serverTextField.layer.borderColor     = [UIColor colorWithWhite:0.85 alpha:1.0].CGColor;
    self.serverTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.serverTextField.autocorrectionType    = UITextAutocorrectionTypeNo;
    self.serverTextField.clearButtonMode       = UITextFieldViewModeWhileEditing;
    UIView *leftPad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 20)];
    self.serverTextField.leftView     = leftPad;
    self.serverTextField.leftViewMode = UITextFieldViewModeAlways;
    [self.view addSubview:self.serverTextField];

    // ── Button 1: Chụp Đăng nhập (solid navy gradient — BankAdaptActivity) ──
    self.loginButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.loginButton.layer.cornerRadius = 14;
    self.loginButton.clipsToBounds      = YES;

    self.loginGradient = [CAGradientLayer layer];
    self.loginGradient.colors      = @[
        (id)[UIColor colorWithRed:0.0 green:0.32 blue:0.58 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.0 green:0.22 blue:0.42 alpha:1.0].CGColor
    ];
    self.loginGradient.startPoint  = CGPointMake(0.0, 0.5);
    self.loginGradient.endPoint    = CGPointMake(1.0, 0.5);
    [self.loginButton.layer insertSublayer:self.loginGradient atIndex:0];

    [self.loginButton setTitle:@"🔓  Khuôn mặt Đăng nhập  (10 ảnh)" forState:UIControlStateNormal];
    [self.loginButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.loginButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.loginButton addTarget:self action:@selector(onLoginTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.loginButton];

    // ── Button 2: Chụp Đăng ký / CK (outline style — BADOOActivity) ──────────
    self.registerButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.registerButton.backgroundColor = [UIColor whiteColor];
    [self.registerButton setTitle:@"📋  Khuôn mặt Chuyển khoản (CK)  (Chụp xa - gần)" forState:UIControlStateNormal];
    [self.registerButton setTitleColor:[UIColor colorWithRed:0.0 green:0.32 blue:0.58 alpha:1.0] forState:UIControlStateNormal];
    self.registerButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.registerButton addTarget:self action:@selector(onRegisterTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.registerButton];
}

#pragma mark - Actions

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (NSString *)resolvedServerUrl {
    if (!self.localServerSwitch.isOn) return nil;
    NSString *url = [self.serverTextField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return (url.length > 0) ? url : @"http://192.168.80.227:8080";
}

- (NSString *)resolvedCardNumber {
    return [self.cardTextField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)onLoginTapped {
    [self dismissKeyboard];
    [self launchWithMode:ACBCaptureModeLogin];
}

- (void)onRegisterTapped {
    [self dismissKeyboard];
    [self launchWithMode:ACBCaptureModeRegister];
}

- (void)launchWithMode:(ACBCaptureMode)mode {
    NSString *cardNum = [self resolvedCardNumber];
    if (cardNum.length == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Thông báo"
                                                                       message:@"Vui lòng nhập số thẻ ngân hàng để tiếp tục."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    @try {
        NSLog(@"[ACBFace] Opening camera mode=%d card=%@", (int)mode, cardNum);
        ViewController *camVC  = [[ViewController alloc] init];
        camVC.cardNumber       = cardNum;
        camVC.captureMode      = mode;
        camVC.serverBaseUrl    = [self resolvedServerUrl];
        camVC.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:camVC animated:YES completion:nil];
    } @catch (NSException *ex) {
        NSLog(@"[ACBFace] CRASH opening camera: %@: %@", ex.name, ex.reason);
        UIAlertController *err = [UIAlertController alertControllerWithTitle:@"Lỗi Khởi Động Camera"
                                                                     message:[NSString stringWithFormat:@"%@: %@", ex.name, ex.reason]
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [err addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:err animated:YES completion:nil];
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end

