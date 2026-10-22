// Hearth's Home screen (HearthHomeVC.h). Step 2: one tile per game, its state line when it cannot start, a tap launches it
#import "HearthHomeVC.h"
#import "HearthLaunch.h"

static NSString *state_line(HearthGame *g) {
    switch (g.reason) {
        case 0: return nil;
        case 2: return @"Rebuild needed";
        case 3: return @"Incomplete";
        default: return @"Not a game";
    }
}

@implementation HearthHomeVC {
    UIStackView *_row;
    NSArray<HearthGame *> *_games;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _row = [UIStackView new]; _row.axis = UILayoutConstraintAxisHorizontal; _row.spacing = 32; _row.alignment = UIStackViewAlignmentTop;
    _row.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_row];
    [NSLayoutConstraint activateConstraints:@[[_row.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor], [_row.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self reload]; }
- (void)reload {
    _games = [hearth_library() scan];
    fprintf(stderr, "home: %lu games\n", (unsigned long)_games.count);
    for (UIView *v in _row.arrangedSubviews) [v removeFromSuperview];
    if (!_games.count) {
        UILabel *l = [UILabel new]; l.text = @"No games yet"; l.textColor = UIColor.secondaryLabelColor;
        [_row addArrangedSubview:l]; return;
    }
    [_games enumerateObjectsUsingBlock:^(HearthGame *g, NSUInteger i, BOOL *stop) { (void)stop; [self->_row addArrangedSubview:[self tileFor:g index:i]]; }];
}
- (UIView *)tileFor:(HearthGame *)g index:(NSUInteger)i {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    UIButtonConfiguration *c = [UIButtonConfiguration plainButtonConfiguration];
    UIImage *icon = g.iconPath ? [UIImage imageWithContentsOfFile:g.iconPath] : [UIImage systemImageNamed:@"gamecontroller"];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(220, 220)];
    c.image = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) { (void)ctx;
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 220, 220) cornerRadius:22] addClip]; [icon drawInRect:CGRectMake(0, 0, 220, 220)]; }];
    c.title = g.name; c.subtitle = state_line(g); c.imagePlacement = NSDirectionalRectEdgeTop; c.imagePadding = 12;
    c.titleAlignment = UIButtonConfigurationTitleAlignmentCenter; c.baseForegroundColor = UIColor.labelColor;
    b.configuration = c; b.tag = (NSInteger)i; b.alpha = g.reason ? 0.5 : 1;
    b.accessibilityLabel = g.name;
    [b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    [b.widthAnchor constraintEqualToConstant:240].active = YES;
    return b;
}
- (void)tap:(UIButton *)b { hearth_launch(_games[(NSUInteger)b.tag], self.view.window); }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
