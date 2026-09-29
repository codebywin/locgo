#import "CardInputViewController.h"
#import "ViewController.h"

@interface CardInputViewController () <UITextFieldDelegate>
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
    
    // Background: deep dark navy / black (#0B0E17)
    self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.10 alpha:1.0];
    
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
    
    CGFloat startY = self.view.bounds.size.height * 0.28;
    
    self.titleLabel.frame = CGRectMake(padX, startY, contentW, 24);
    
    self.inputContainer.frame = CGRectMake(padX, CGRectGetMaxY(self.titleLabel.frame) + 12, contentW, 76);
    self.placeholderHeaderLabel.frame = CGRectMake(16, 10, contentW - 32, 18);
    self.cardTextField.frame = CGRectMake(16, 32, contentW - 32, 34);
    
    self.startCaptureButton.frame = CGRectMake(padX, CGRectGetMaxY(self.inputContainer.frame) + 36, contentW, 52);
    self.buttonGradient.frame = self.startCaptureButton.bounds;
}

- (void)setupUI {
    // 1. Label "Số thẻ ngân hàng"
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = @"Số thẻ ngân hàng";
    self.titleLabel.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [self.view addSubview:self.titleLabel];
    
    // 2. Input container box
    self.inputContainer = [[UIView alloc] init];
    self.inputContainer.backgroundColor = [UIColor colorWithRed:0.09 green:0.11 blue:0.16 alpha:1.0];
    self.inputContainer.layer.cornerRadius = 10;
    self.inputContainer.layer.borderWidth = 1.0;
    self.inputContainer.layer.borderColor = [UIColor colorWithRed:0.18 green:0.22 blue:0.32 alpha:1.0].CGColor;
    self.inputContainer.clipsToBounds = YES;
    [self.view addSubview:self.inputContainer];
    
    // Inner label "Nhập số thẻ ngân hàng"
    self.placeholderHeaderLabel = [[UILabel alloc] init];
    self.placeholderHeaderLabel.text = @"Nhập số thẻ ngân hàng";
    self.placeholderHeaderLabel.textColor = [UIColor colorWithWhite:0.50 alpha:1.0];
    self.placeholderHeaderLabel.font = [UIFont systemFontOfSize:13];
    [self.inputContainer addSubview:self.placeholderHeaderLabel];
    
    // Input text field
    self.cardTextField = [[UITextField alloc] init];
    self.cardTextField.text = @"18601771"; // Mac dinh giong anh
    self.cardTextField.textColor = [UIColor whiteColor];
    self.cardTextField.font = [UIFont boldSystemFontOfSize:22];
    self.cardTextField.keyboardType = UIKeyboardTypeNumberPad;
    self.cardTextField.returnKeyType = UIReturnKeyDone;
    self.cardTextField.delegate = self;
    [self.inputContainer addSubview:self.cardTextField];
    
    // 3. Button "Bắt đầu chụp" with beautiful gradient (Purple -> Blue)
    self.startCaptureButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.startCaptureButton.layer.cornerRadius = 14;
    self.startCaptureButton.clipsToBounds = YES;
    
    self.buttonGradient = [CAGradientLayer layer];
    self.buttonGradient.colors = @[
        (id)[UIColor colorWithRed:0.43 green:0.35 blue:0.96 alpha:1.0].CGColor, // #6E59F5
        (id)[UIColor colorWithRed:0.22 green:0.45 blue:0.96 alpha:1.0].CGColor  // #3873F5
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
    
    // Open Camera Face Capture screen
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
