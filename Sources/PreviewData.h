//
//  PreviewData.h — deterministic sample telemetry for the layout editor's
//  live preview and the offscreen render harnesses (so they can't drift).
//
#import "BarView.h"

// Feed `frames` ticks of canned stats into a BarView. frames>1 builds up the
// CPU/net/GPU sparkline history; frames<1 is treated as 1.
void PBFeedSample(BarView *v, int frames);
