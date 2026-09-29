#import "CardInputViewController.h"
#import "ViewController.h"
#import <QuartzCore/QuartzCore.h>

@interface CardInputViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UILabel *brandLabel;
@property (nonatomic, strong) UILabel *brandSubtitleLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *inputContainer;
@property (nonatomic, strong) UILabel *placeholderHeaderLabel;
@property (nonatomic, strong) UITextField *cardTextField;
@property (nonatomic, strong) UIButton *startCaptureButton;
@property (nonatomic, strong) CAGradientLayer *buttonGradient;
@end

@implementation CardInputViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Background: Clean white matching ACB NEW app
    self.view.backgroundColor = [UIColor colorWithRed:0.96 green:0.97 blue:0.98 alpha:1.0];
    
    // Tap outside to dismiss keyboard
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    [self.view addGestureRecognizer:tap];
    
    [self setupUI];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    CGFloat screenW = self.view.bounds.size.width;
    CGFloat padX = 24.0;
    CGFloat contentW = screenW - padX * 2;
    
    CGFloat safeTop = 50.0;
    if (@available(iOS 11.0, *)) {
        UIWindow *win = [UIApplication sharedApplication].windows.firstObject;
        if (win && win.safeAreaInsets.top > 0) safeTop = win.safeAreaInsets.top;
    }
    
    CGFloat startY = safeTop + 60.0;
    
    self.brandLabel.frame = CGRectMake(padX, startY, contentW, 36);
    self.brandSubtitleLabel.frame = CGRectMake(padX, CGRectGetMaxY(self.brandLabel.frame) + 6, contentW, 20);
    
    self.titleLabel.frame = CGRectMake(padX, CGRectGetMaxY(self.brandSubtitleLabel.frame) + 40, contentW, 24);
    
    self.inputContainer.frame = CGRectMake(padX, CGRectGetMaxY(self.titleLabel.frame) + 12, contentW, 76);
    self.placeholderHeaderLabel.frame = CGRectMake(16, 10, contentW - 32, 18);
    self.cardTextField.frame = CGRectMake(16, 32, contentW - 32, 34);
    
    self.startCaptureButton.frame = CGRectMake(padX, CGRectGetMaxY(self.inputContainer.frame) + 36, contentW, 54);
    self.buttonGradient.frame = self.startCaptureButton.bounds;
}

- (void)setupUI {
    // 0. Branding Header (ACB Face)
    self.brandLabel = [[UILabel alloc] init];
    self.brandLabel.text = @"ACB Face";
    self.brandLabel.textColor = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0]; // #00427A ACB Navy
    self.brandLabel.font = [UIFont boldSystemFontOfSize:30];
    self.brandLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.brandLabel];
    
    self.brandSubtitleLabel = [[UILabel alloc] init];
    self.brandSubtitleLabel.text = @"Xác thực khuôn mặt eKYC";
    self.brandSubtitleLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    self.brandSubtitleLabel.font = [UIFont systemFontOfSize:14];
    self.brandSubtitleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.brandSubtitleLabel];
    
    // 1. Label "Số thẻ ngân hàng"
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = @"Số thẻ ngân hàng";
    self.titleLabel.textColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [self.view addSubview:self.titleLabel];
    
    // 2. Input container box
    self.inputContainer = [[UIView alloc] init];
    self.inputContainer.backgroundColor = [UIColor whiteColor];
    self.inputContainer.layer.cornerRadius = 14;
    self.inputContainer.layer.borderWidth = 1.5;
    self.inputContainer.layer.borderColor = [UIColor colorWithRed:0.86 green:0.89 blue:0.92 alpha:1.0].CGColor;
    self.inputContainer.layer.shadowColor = [UIColor blackColor].CGColor;
    self.inputContainer.layer.shadowOpacity = 0.04;
    self.inputContainer.layer.shadowOffset = CGSizeMake(0, 4);
    self.inputContainer.layer.shadowRadius = 8;
    [self.view addSubview:self.inputContainer];
    
    // Inner label "Nhập số thẻ ngân hàng"
    self.placeholderHeaderLabel = [[UILabel alloc] init];
    self.placeholderHeaderLabel.text = @"Nhập số thẻ ngân hàng";
    self.placeholderHeaderLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    self.placeholderHeaderLabel.font = [UIFont systemFontOfSize:13];
    [self.inputContainer addSubview:self.placeholderHeaderLabel];
    
    // Input text field
    self.cardTextField = [[UITextField alloc] init];
    self.cardTextField.text = @"18601771";
    self.cardTextField.textColor = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:1.0];
    self.cardTextField.font = [UIFont boldSystemFontOfSize:22];
    self.cardTextField.keyboardType = UIKeyboardTypeNumberPad;
    self.cardTextField.returnKeyType = UIReturnKeyDone;
    self.cardTextField.delegate = self;
    [self.inputContainer addSubview:self.cardTextField];
    
    // 3. Button "Bắt đầu chụp" with ACB Navy Gradient
    self.startCaptureButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.startCaptureButton.layer.cornerRadius = 14;
    self.startCaptureButton.clipsToBounds = YES;
    self.startCaptureButton.layer.shadowColor = [UIColor colorWithRed:0.0 green:0.26 blue:0.48 alpha:0.35].CGColor;
    self.startCaptureButton.layer.shadowOpacity = 0.8;
    self.startCaptureButton.layer.shadowOffset = CGSizeMake(0, 6);
    self.startCaptureButton.layer.shadowRadius = 12;
    
    self.buttonGradient = [CAGradientLayer layer];
    self.buttonGradient.colors = @[
        (id)[UIColor colorWithRed:0.0 green:0.32 blue:0.58 alpha:1.0].CGColor, // #005294
        (id)[UIColor colorWithRed:0.0 green:0.22 blue:0.42 alpha:1.0].CGColor  // #00386B
    ];
    self.buttonGradient.startPoint = CGPointMake(0.0, 0.5);
    self.buttonGradient.endPoint = CGPointMake(1.0, 0.5);
    [self.startCaptureButton.layer insertSublayer:self.buttonGradient atIndex:0];
    
    [self.startCaptureButton setTitle:@"Bắt đầu chụp" forState:UIControlStateNormal];
    [self.startCaptureButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.startCaptureButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [self.startCaptureButton addTarget:self action:@selector(onStartCaptureTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.startCaptureButton];
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)onStartCaptureTapped {
    [self dismissKeyboard];
    
    NSString *cardNum = [self.cardTextField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cardNum.length == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Thông báo"
                                                                       message:@"Vui lòng nhập số thẻ ngân hàng để tiếp tục."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    // Open Camera Face Capture screen (Orchestrator 10 rounds)
    ViewController *camVC = [[ViewController alloc] init];
    camVC.cardNumber = cardNum;
    camVC.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:camVC animated:YES completion:nil];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
