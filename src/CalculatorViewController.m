#import "CalculatorViewController.h"
#import "RootViewController.h"

// 密码存本地，默认 0520，进隐藏列表后可改
static NSString *GHSecretCode(void) {
    NSString *c = [[NSUserDefaults standardUserDefaults] stringForKey:@"gh_secret_code"];
    return (c.length >= 3) ? c : @"0520";
}

@interface CalculatorViewController ()
@property (strong) UILabel *display;
@property (copy) NSString *current;      // 正在输入的数
@property (copy) NSString *previous;     // 上一个数
@property (copy) NSString *operation;    // + - × ÷
@property (assign) BOOL typingNumber;    // 正在输入新数？
@property (strong) NSMutableArray *keys; // 按钮，tag = 行*10+列
@end

@implementation CalculatorViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.current = @"0";
    [self buildUI];

    // 回到桌面再切回来时，自动退回计算器界面（防止把隐藏列表留在屏幕上）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(goBackToCalculator)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
}

- (void)goBackToCalculator {
    if (self.presentedViewController) [self dismissViewControllerAnimated:NO completion:nil];
}

#pragma mark - UI

- (UIButton *)keyWithTitle:(NSString *)title
                     color:(UIColor *)color
                   fgColor:(UIColor *)fg {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightRegular];
    [b setTitleColor:fg forState:UIControlStateNormal];
    b.backgroundColor = color;
    b.layer.cornerRadius = 38;
    [b addTarget:self action:@selector(keyPressed:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildUI {
    self.display = [[UILabel new] setText:@""];
    self.display.text = @"0";
    self.display.textColor = [UIColor whiteColor];
    self.display.font = [UIFont monospacedDigitSystemFontOfSize:60 weight:UIFontWeightLight];
    self.display.textAlignment = NSTextAlignmentRight;
    self.display.adjustsFontSizeToFitWidth = YES;
    self.display.minimumScaleFactor = 0.25;
    [self.view addSubview:self.display];

    self.keys = [NSMutableArray new];
    UIColor *dark  = [UIColor colorWithWhite:0.19 alpha:1];   // 数字键
    UIColor *light = [UIColor colorWithWhite:0.72 alpha:1];   // 功能键
    UIColor *orange = [UIColor colorWithRed:1.0 green:0.45 blue:0.10 alpha:1]; // 运算键

    NSArray *rows = @[
        @[@"AC", @"±", @"%", @"÷"],
        @[@"7", @"8", @"9", @"×"],
        @[@"4", @"5", @"6", @"−"],
        @[@"1", @"2", @"3", @"+"],
        @[@"0", @".", @"="]
    ];

    for (NSUInteger r = 0; r < rows.count; r++) {
        NSArray *row = rows[r];
        for (NSUInteger c = 0; c < 4; c++) {
            NSString *title = nil;
            if ([row[0] isEqualToString:@"0"] && row.count == 3) {
                // 底行：0 占两列
                if (c == 0) title = @"0";
                else if (c == 1) continue;                 // 0 的右半格
                else title = row[c - 1];                   // . 和 =
            } else {
                title = row[c];
            }

            UIColor *bg = dark, *fg = UIColor.whiteColor;
            if ([title isEqualToString:@"AC"] || [title isEqualToString:@"±"] || [title isEqualToString:@"%"]) {
                bg = light; fg = UIColor.blackColor;
            } else if ([title isEqualToString:@"÷"] || [title isEqualToString:@"×"] ||
                       [title isEqualToString:@"−"] || [title isEqualToString:@"+"] ||
                       [title isEqualToString:@"="]) {
                bg = orange;
            }
            UIButton *b = [self keyWithTitle:title color:bg fgColor:fg];
            b.tag = (NSInteger)(r * 10 + c);
            [self.view addSubview:b];
            [self.keys addObject:b];
        }
    }
}

// 手动布局：随屏幕尺寸铺满
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGRect safe = self.view.safeAreaInsets != UIEdgeInsetsZero
        ? UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets)
        : self.view.bounds;

    CGFloat pad = 10;
    CGFloat keyH = 76;
    CGFloat keyW = (safe.size.width - pad * 5) / 4.0;

    self.display.frame = CGRectMake(safe.origin.x + 16, safe.origin.y + 4,
                                    safe.size.width - 32, 120);

    CGFloat y = CGRectGetMaxY(self.display.frame) + pad;
    for (UIButton *b in self.keys) {
        NSInteger r = b.tag / 10;
        NSInteger c = b.tag % 10;
        CGFloat x = safe.origin.x + pad + c * (keyW + pad);
        CGRect f = CGRectMake(x, y + r * (keyH + pad), keyW, keyH);
        if ([b.currentTitle isEqualToString:@"0"]) {
            f.size.width = keyW * 2 + pad;   // 0 占两格
        }
        b.frame = f;
    }
}

#pragma mark - 按键逻辑

- (void)keyPressed:(UIButton *)b {
    NSString *t = b.currentTitle;

    // ★ 密码入口：输入密码后按 = 翻开隐藏列表
    if ([t isEqualToString:@"="]) {
        NSString *input = self.current ?: @"";
        if ([input isEqualToString:GHSecretCode()]) {
            [self unlockVault];
            return;
        }
        [self pressEquals];
        return;
    }

    if ([t isEqualToString:@"AC"]) { [self clearAll]; return; }
    if ([t isEqualToString:@"±"]) {
        if (self.current.doubleValue != 0) {
            self.current = [self.current hasPrefix:@"-"]
                ? [self.current substringFromIndex:1]
                : [@"-" stringByAppendingString:self.current];
            [self refreshDisplay];
        }
        return;
    }
    if ([t isEqualToString:@"%"]) {
        self.current = [NSString stringWithFormat:@"%g", self.current.doubleValue / 100.0];
        [self refreshDisplay];
        return;
    }
    if ([t isEqualToString:@"÷"] || [t isEqualToString:@"×"] ||
        [t isEqualToString:@"−"] || [t isEqualToString:@"+"]) {
        [self setOperation:t];
        return;
    }
    if ([t isEqualToString:@"."]) { [self pressDot]; return; }

    // 数字
    [self pressDigit:t];
}

- (void)clearAll {
    self.current = @"0";
    self.previous = nil;
    self.operation = nil;
    self.typingNumber = NO;
    [self refreshDisplay];
}

- (void)refreshDisplay {
    NSString *text = self.current ?: @"0";
    // 000 开头的多余零去掉（简单处理）
    while (text.length > 1 && [text hasPrefix:@"0"] && ![text hasPrefix:@"0."] ) {
        text = [text substringFromIndex:1];
    }
    self.display.text = text;
}

- (void)pressDigit:(NSString *)d {
    if (self.typingNumber) {
        self.current = [self.current isEqualToString:@"0"] ? d
                       : [self.current stringByAppendingString:d];
    } else {
        self.current = d;
        self.typingNumber = YES;
    }
    [self refreshDisplay];
}

- (void)pressDot {
    if (!self.typingNumber) {
        self.current = @"0.";
        self.typingNumber = YES;
    } else if (![self.current containsString:@"."]) {
        self.current = [self.current stringByAppendingString:@"."];
    }
    [self refreshDisplay];
}

- (void)setOperation:(NSString *)op {
    if (self.operation && self.typingNumber) [self pressEquals];   // 连续运算
    self.previous = self.current ?: @"0";
    self.operation = op;
    self.typingNumber = NO;
}

- (double)apply:(double)a op:(NSString *)op b:(double)b {
    if ([op isEqualToString:@"+"]) return a + b;
    if ([op isEqualToString:@"−"]) return a - b;
    if ([op isEqualToString:@"×"]) return a * b;
    if ([op isEqualToString:@"÷"]) return b != 0 ? a / b : NAN;
    return b;
}

- (void)pressEquals {
    if (!self.operation) {
        self.typingNumber = NO;
        return;
    }
    double result = [self apply:self.previous.doubleValue
                             op:self.operation
                              b:self.current.doubleValue];
    if (isnan(result)) {
        self.current = @"错误";
    } else {
        self.current = [NSString stringWithFormat:@"%g", result];
    }
    self.operation = nil;
    self.previous = nil;
    self.typingNumber = NO;
    [self refreshDisplay];
}

#pragma mark - 解锁

- (void)unlockVault {
    RootViewController *vault = [[RootViewController alloc] initWithStyle:UITableViewStylePlain];
    vault.unlocked = YES;                       // 密码已经验证过，不再弹面容
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vault];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];

    // 清掉输入痕迹，别人看到的就是一个刚清零的计算器
    [self clearAll];
}

@end
