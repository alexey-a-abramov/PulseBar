//
//  LayoutEditorWindowController.h — the "size editor": pick a mode and tune
//  each tile's size (weight), priority and visibility, with a live preview.
//  Changes persist to NSUserDefaults and post PBLayoutChangedNotification.
//
#import <AppKit/AppKit.h>

@interface LayoutEditorWindowController : NSWindowController
- (void)present;
@end
