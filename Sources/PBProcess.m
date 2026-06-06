//
//  PBProcess.m
//
#import "PBProcess.h"

NSString *PBRunCapture(NSString *path, NSArray<NSString *> *args) {
    NSTask *t = [NSTask new]; t.launchPath = path; t.arguments = args;
    NSPipe *out = [NSPipe pipe]; t.standardOutput = out; t.standardError = [NSPipe pipe];
    @try { [t launch]; } @catch (id e) { return nil; }
    NSData *d = [out.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

void PBLaunchDetached(NSString *path, NSArray<NSString *> *args) {
    NSTask *t = [NSTask new]; t.launchPath = path; t.arguments = args;
    @try { [t launch]; } @catch (id e) {}
}
