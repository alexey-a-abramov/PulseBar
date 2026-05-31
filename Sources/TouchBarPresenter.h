//
//  TouchBarPresenter.h — owns the private Touch Bar SPI: presenting the custom
//  bar system-wide, the Control-Strip fallback item, and the reversible
//  full-width takeover (defaults + TouchBarServer restart). Keeps the riskiest,
//  least-testable code behind one interface.
//
#import <AppKit/AppKit.h>

@interface PBTouchBarPresenter : NSObject
@property (nonatomic, readonly) BOOL spiAvailable;
- (instancetype)initWithContentView:(NSView *)contentView;
- (void)attach;                           // present the system-modal full bar
- (void)reassert;                         // re-present + re-hide the close box (after an app switch)
- (void)detach;                           // dismiss + restore the Control Strip if we took over
- (void)setStripTitle:(NSString *)title;  // Control-Strip fallback button label (e.g. "⟂ 42%")
- (void)applyFullBar:(BOOL)on;            // toggle the global takeover (defaults + width + restart + reattach)
@end
