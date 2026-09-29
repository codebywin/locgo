#import "LoginFaceOverlayView.h"

@implementation LoginFaceOverlayView {
    UIColor *_ovalColor;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        _acbStatus = 3;
        // Default state: #03A9F4 (Light Blue)
        _ovalColor = [UIColor colorWithRed:0.01 green:0.66 blue:0.96 alpha:1.0];
    }
    return self;
}

- (void)setAcbStatus:(NSInteger)status {
    if (_acbStatus == status) return;
    _acbStatus = status;
    
    if (status == 0) {
        // STATE_CORRECT: #28FA63 (Green)
        _ovalColor = [UIColor colorWithRed:0.16 green:0.98 blue:0.39 alpha:1.0];
    } else if (status == 1 || status == 2 || status == 4) {
        // STATE_TOO_FAR / TOO_CLOSE / MULTI_FACE: #FF5722 (Orange)
        _ovalColor = [UIColor colorWithRed:1.0 green:0.34 blue:0.13 alpha:1.0];
    } else {
        // STATE_NOT_CENTERED / DEFAULT: #03A9F4 (Light Blue)
        _ovalColor = [UIColor colorWithRed:0.01 green:0.66 blue:0.96 alpha:1.0];
    }
    [self setNeedsDisplay];
}

- (CGRect)ovalRect {
    CGFloat w = self.bounds.size.width;
    CGFloat halfW = w / 2.0;
    
    // Exact formulas from ACB NEW LoginFaceOverlayView.smali:
    // OVAL_WIDTH_RATIO = 0.47f
    // OVAL_ASPECT_RATIO = 1.3333334f (4/3)
    CGFloat ovalW = w * 0.47;
    CGFloat ovalH = ovalW * (4.0 / 3.0);
    
    return CGRectMake(halfW - ovalW / 2.0, halfW - ovalH / 2.0, ovalW, ovalH);
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    
    CGFloat w = rect.size.width;
    CGFloat h = rect.size.height;
    if (w <= 0 || h <= 0) return;
    
    CGFloat halfW = w / 2.0;
    
    // 1. Draw solid white background over entire view
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextFillRect(ctx, rect);
    
    // 2. Clear circular hole at top: centered at (halfW, halfW) with diameter = w
    CGRect circleRect = CGRectMake(0, 0, w, w);
    CGContextSetBlendMode(ctx, kCGBlendModeClear);
    CGContextFillEllipseInRect(ctx, circleRect);
    
    // Back to normal blend mode for borders
    CGContextSetBlendMode(ctx, kCGBlendModeNormal);
    
    // 3. Draw outer circular border: #E8E8E8 (4.0pt width)
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.91 green:0.91 blue:0.91 alpha:1.0].CGColor);
    CGContextSetLineWidth(ctx, 4.0);
    CGContextStrokeEllipseInRect(ctx, CGRectInset(circleRect, 2.0, 2.0));
    
    // 4. Draw inner circular border: #D0D0D0 (1.5pt width)
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.82 green:0.82 blue:0.82 alpha:1.0].CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextStrokeEllipseInRect(ctx, CGRectInset(circleRect, 6.0, 6.0));
    
    // 5. Draw Dashed Oval
    CGRect oval = self.ovalRect;
    UIColor *color = _ovalColor ?: [UIColor colorWithRed:0.01 green:0.66 blue:0.96 alpha:1.0];
    CGContextSetStrokeColorWithColor(ctx, color.CGColor);
    CGContextSetLineWidth(ctx, 4.5);
    
    // Dash pattern matching ACB NEW: 10px line, 14px gap, rounded caps
    CGFloat dashLengths[] = {10.0, 14.0};
    CGContextSetLineDash(ctx, 0, dashLengths, 2);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextStrokeEllipseInRect(ctx, oval);
}

@end

