// The text editor of the settings screen (see DmSettingsEditor.h). The limits and what counts as a valid text come from the DmSetting (DmSettings.m): this file only draws them.
#import "DmSettingsEditor.h"
#import "DmSettingsViews.h"

#pragma mark - Button

@interface DmEditButton : UIControl
- (instancetype)initWithTitle:(NSString *)title primary:(BOOL)primary compact:(BOOL)compact;
@property (nonatomic) BOOL dimmed;   // a primary button that cannot be used yet looks like the other one, greyed
@end
@implementation DmEditButton { UILabel *_label; BOOL _primary; }
- (instancetype)initWithTitle:(NSString *)title primary:(BOOL)primary compact:(BOOL)compact {
    if ((self = [super initWithFrame:CGRectZero])) {
        _primary = primary; self.layer.cornerRadius = compact ? 12 : 16;
        _label = [UILabel new]; _label.text = title; _label.textAlignment = NSTextAlignmentCenter; _label.font = [DmUI font:compact ? 16 : 19 weight:UIFontWeightSemibold]; _label.userInteractionEnabled = NO;
        [self addSubview:_label]; self.accessibilityLabel = title; self.accessibilityTraits = UIAccessibilityTraitButton;
        __weak DmEditButton *w = self; dm_on_style(self, ^{ [w paint]; });
    }
    return self;
}
- (void)paint {
    BOOL hot = _primary && !_dimmed;
    self.layer.backgroundColor = dm_cg(self, hot ? DmUI.accent : DmUI.row);
    _label.textColor = hot ? [UIColor colorWithRed:0.04 green:0.15 blue:0.19 alpha:1] : (_primary ? DmUI.sub : DmUI.text);   // dark ink on the cyan fill in both styles
}
- (void)setDimmed:(BOOL)d { _dimmed = d; [self paint]; }
- (void)setHighlighted:(BOOL)h { [super setHighlighted:h]; self.alpha = h ? 0.7 : 1; }
- (void)layoutSubviews { [super layoutSubviews]; _label.frame = self.bounds; }
@end

#pragma mark - Editor

@interface DmEditorView () <UITextFieldDelegate, UIGestureRecognizerDelegate>
@end
@implementation DmEditorView {
    DmSetting *_s; BOOL _compact, _done, _refused;
    UIView *_panel, *_box; UILabel *_title, *_detail, *_msg, *_count; DmFocusView *_ring; DmEditButton *_cancelBtn, *_saveBtn; UITextField *_field;
    CGFloat _kbTop; NSString *_refusal;
}
- (UITextField *)field { return _field; }
- (instancetype)initWithSetting:(DmSetting *)s text:(NSString *)text compact:(BOOL)compact {
    if ((self = [super initWithFrame:CGRectZero])) {
        _s = s; _compact = compact; _kbTop = CGFLOAT_MAX; self.accessibilityViewIsModal = YES;
        _panel = [UIView new]; _panel.layer.cornerRadius = compact ? 18 : 26;
        _panel.layer.shadowColor = UIColor.blackColor.CGColor; _panel.layer.shadowOpacity = 0.3; _panel.layer.shadowRadius = 28; _panel.layer.shadowOffset = CGSizeMake(0, 10);
        _title = [UILabel new]; _title.text = s.label; _title.font = [DmUI font:compact ? 18 : 26 weight:UIFontWeightBold]; _title.adjustsFontSizeToFitWidth = YES; _title.minimumScaleFactor = 0.8;
        _detail = [UILabel new]; _detail.text = s.detail; _detail.numberOfLines = 0; _detail.font = [DmUI font:compact ? 12 : 14 weight:UIFontWeightRegular];
        _box = [UIView new]; _box.layer.cornerRadius = compact ? 12 : 16;
        _ring = [DmFocusView new]; _ring.radius = compact ? 14 : 19; _ring.active = YES;
        _field = [UITextField new]; _field.font = [DmUI font:compact ? 16 : 20 weight:UIFontWeightSemibold]; _field.text = text; _field.delegate = self;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing; _field.autocorrectionType = UITextAutocorrectionTypeNo; _field.spellCheckingType = UITextSpellCheckingTypeNo;
        _field.autocapitalizationType = UITextAutocapitalizationTypeWords; _field.returnKeyType = UIReturnKeyDone; _field.accessibilityLabel = s.label;
        [_field addTarget:self action:@selector(edited) forControlEvents:UIControlEventEditingChanged];
        _msg = [UILabel new]; _msg.font = [DmUI font:compact ? 11 : 13 weight:UIFontWeightSemibold];
        _count = [UILabel new]; _count.font = _msg.font; _count.textAlignment = NSTextAlignmentRight;
        _cancelBtn = [[DmEditButton alloc] initWithTitle:@"Cancel" primary:NO compact:compact]; [_cancelBtn addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
        _saveBtn = [[DmEditButton alloc] initWithTitle:@"Save" primary:YES compact:compact]; [_saveBtn addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside];
        [_box addSubview:_field];
        for (UIView *v in @[_title, _detail, _box, _ring, _msg, _count, _cancelBtn, _saveBtn]) [_panel addSubview:v];
        [self addSubview:_panel];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cancel)]; tap.delegate = self; [self addGestureRecognizer:tap];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
        __weak DmEditorView *w = self;
        dm_on_style(self, ^{ DmEditorView *e = w; if (!e) return;
            e.backgroundColor = [UIColor colorWithWhite:0 alpha:e.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? 0.8 : 0.78];
            e->_panel.layer.backgroundColor = dm_cg(e, DmUI.panel); e->_box.layer.backgroundColor = dm_cg(e, DmUI.row);
            e->_title.textColor = DmUI.text; e->_detail.textColor = DmUI.sub; e->_field.textColor = DmUI.text; e->_field.tintColor = DmUI.accentText; e->_msg.textColor = DmUI.warn; [e refresh]; });
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

#pragma mark Text

// Counter and limit note follow the field; any edit takes the refusal back
- (void)refresh {
    NSString *t = _field.text ?: @"", *note = [_s textLimitNote:t];
    _count.text = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)[_s textCount:t], (unsigned long)_s.maxLength];
    _msg.text = _refusal ?: note;
    _count.textColor = note != nil || _refusal != nil ? DmUI.warn : DmUI.sub; _ring.warn = _refused;
    _saveBtn.dimmed = [_s normalized:t] == nil;
}
- (void)edited { _refusal = nil; _refused = NO; [self refresh]; }
- (void)refuse:(NSString *)why {   // the visible no: the border turns warm, the field shakes, the note says why
    _refusal = why; _refused = YES; [self refresh];
    CAKeyframeAnimation *k = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    k.values = @[@0, @-7, @7, @-4, @4, @0]; k.duration = 0.25;
    [_box.layer addAnimation:k forKey:@"shake"]; [_ring.layer addAnimation:k forKey:@"shake"];
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeWarning];
}
- (BOOL)textField:(UITextField *)f shouldChangeCharactersInRange:(NSRange)r replacementString:(NSString *)t {
    NSString *cur = f.text ?: @"", *clip = [_s clippedReplacement:t inText:cur range:r];
    if ([clip isEqualToString:t]) return YES;
    if (clip.length) {   // a paste past the limit keeps what fits
        f.text = [cur stringByReplacingCharactersInRange:r withString:clip];
        UITextPosition *p = [f positionFromPosition:f.beginningOfDocument offset:(NSInteger)(r.location + clip.length)]; if (p) f.selectedTextRange = [f textRangeFromPosition:p toPosition:p];
        [self edited];
    }
    [self refuse:nil];   // the counter and the limit note are already in the warning colour
    return NO;
}
- (BOOL)textFieldShouldReturn:(UITextField *)f { (void)f; [self save]; return NO; }
- (BOOL)textFieldShouldClear:(UITextField *)f { (void)f; dispatch_async(dispatch_get_main_queue(), ^{ [self edited]; }); return YES; }

#pragma mark Actions

- (void)open {
    self.alpha = 0; _panel.transform = CGAffineTransformMakeScale(0.96, 0.96); [self refresh];
    [UIView animateWithDuration:0.15 animations:^{ self.alpha = 1; self->_panel.transform = CGAffineTransformIdentity; }];
    [_field becomeFirstResponder];
}
- (void)finish:(void (^)(void))call {
    if (_done) return; _done = YES; [_field resignFirstResponder];
    if (call) call();
    [UIView animateWithDuration:0.12 animations:^{ self.alpha = 0; } completion:^(BOOL x) { (void)x; [self removeFromSuperview]; }];
}
- (void)save {
    NSString *n = [_s normalized:_field.text];
    if (!n) { [self refuse:[NSString stringWithFormat:@"%@ cannot be empty", _s.label]]; return; }
    [self finish:^{ if (self.onSave) self.onSave(n); }];
}
- (void)cancel { [self finish:^{ if (self.onCancel) self.onCancel(); }]; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t { (void)g; return !CGRectContainsPoint(_panel.frame, [t locationInView:self]); }

#pragma mark Layout

- (void)keyboardChanged:(NSNotification *)n {
    if (!self.window) return;
    CGRect end = [self convertRect:[n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil], b = self.bounds;
    _kbTop = (end.size.width < b.size.width * 0.9 || end.origin.y >= b.size.height) ? CGFLOAT_MAX : end.origin.y;   // a floating or hidden keyboard covers nothing
    [UIView animateWithDuration:[n.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue] animations:^{ [self setNeedsLayout]; [self layoutIfNeeded]; }];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds; UIEdgeInsets si = self.safeAreaInsets;
    CGFloat pad = _compact ? 16 : 26, W = MIN(_compact ? 440 : 560, b.size.width - si.left - si.right - (_compact ? 32 : 80)), iw = W - pad * 2;
    CGFloat th = ceil(_title.font.lineHeight), fh = _compact ? 44 : 56, sh = ceil(_msg.font.lineHeight), bh = _compact ? 44 : 56, gap = _compact ? 12 : 18, inner = _compact ? 12 : 18;
    CGFloat dh = ceil([_detail sizeThatFits:CGSizeMake(iw, CGFLOAT_MAX)].height);
    CGFloat top = MAX(si.top, 0) + 8, bottom = MIN(b.size.height - si.bottom, _kbTop) - 8, avail = bottom - top;
    CGFloat rest = pad + th + gap + fh + 6 + sh + gap + bh + pad, total = rest + dh + 4;
    BOOL showDetail = total <= avail || avail <= 0; if (!showDetail) { total = rest; dh = 0; }   // not enough room above the keyboard: the explanation goes, the limit is in the counter
    _detail.hidden = !showDetail;
    CGFloat y = pad;
    _panel.bounds = CGRectMake(0, 0, W, total); _panel.center = CGPointMake(b.size.width / 2, top + MAX(0, (avail - total) / 2) + total / 2);
    _title.frame = CGRectMake(pad, y, iw, th); y += th;
    if (showDetail) { _detail.frame = CGRectMake(pad, y + 4, iw, dh); y += 4 + dh; }
    y += gap; _box.frame = CGRectMake(pad, y, iw, fh); _ring.frame = CGRectInset(_box.frame, -3, -3); _field.frame = CGRectMake(inner, 0, iw - inner * 2, fh); y += fh + 6;
    NSString *widest = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)_s.maxLength, (unsigned long)_s.maxLength];
    CGFloat cw = ceil([widest sizeWithAttributes:@{NSFontAttributeName: _count.font}].width) + 8;
    _msg.frame = CGRectMake(pad + 4, y, iw - cw - 8, sh); _count.frame = CGRectMake(pad + iw - cw - 4, y, cw, sh); y += sh + gap;
    CGFloat g = _compact ? 8 : 12, w2 = (iw - g) / 2;
    _cancelBtn.frame = CGRectMake(pad, y, w2, bh); _saveBtn.frame = CGRectMake(pad + w2 + g, y, w2, bh);
}
@end
