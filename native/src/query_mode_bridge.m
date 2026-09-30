#import <AppKit/AppKit.h>
#include <unistd.h>

// Read-only IPC. The callback runs on Squirrel's main thread, where its Rime
// contexts live. Nothing here hooks IMK methods or changes an input source.
typedef int (*STModeReader)(const char *, int, void *);
static STModeReader modeReader;
static void *modeContext;
static NSObject *observer;
static NSString *const requestName = @"org.owllinker.SquirrelTranslate.QueryModeRequest";
static NSString *const responseName = @"org.owllinker.SquirrelTranslate.QueryModeResponse";

@interface STQueryModeObserver : NSObject
- (void)request:(NSNotification *)notification;
@end
@implementation STQueryModeObserver
- (void)request:(NSNotification *)notification {
  NSDictionary *info = notification.userInfo;
  NSString *token = info[@"token"];
  NSString *app = info[@"app"];
  NSNumber *pid = info[@"pid"];
  NSNumber *targetPID = info[@"target_pid"];
  if (![token isKindOfClass:NSString.class] || token.length > 64 ||
      ![app isKindOfClass:NSString.class] || app.length > 255 ||
      ![pid isKindOfClass:NSNumber.class] ||
      ![targetPID isKindOfClass:NSNumber.class]) return;
  NSRunningApplication *requester = [NSRunningApplication
      runningApplicationWithProcessIdentifier:pid.intValue];
  if (![requester.bundleIdentifier isEqualToString:@"org.owllinker.SquirrelTranslate.InputBar"])
    return;
  dispatch_async(dispatch_get_main_queue(), ^{
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    int mode = -1;
    if (modeReader && [front.bundleIdentifier isEqualToString:app] &&
        front.processIdentifier == targetPID.intValue)
      mode = modeReader(app.UTF8String, targetPID.intValue, modeContext);
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:responseName object:token
        userInfo:@{@"mode": @(mode), @"app": app, @"pid": @(getpid())}
        deliverImmediately:YES];
  });
}
@end

int SquirrelTranslateQueryClientPID(const char *app) {
  NSString *name = app ? [NSString stringWithUTF8String:app] : nil;
  NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
  return [front.bundleIdentifier isEqualToString:name] ? front.processIdentifier : 0;
}

void SquirrelTranslateQueryBridgeStart(STModeReader reader, void *context) {
  modeReader = reader;
  modeContext = context;
  if (observer) return;
  observer = [STQueryModeObserver new];
  [[NSDistributedNotificationCenter defaultCenter] addObserver:observer
      selector:@selector(request:) name:requestName object:nil
      suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
}

void SquirrelTranslateQueryBridgeStop(void) {
  if (observer) [[NSDistributedNotificationCenter defaultCenter] removeObserver:observer];
  observer = nil;
  modeReader = NULL;
  modeContext = NULL;
}

void SquirrelTranslateQueryModeChanged(const char *app) {
  if (!app || !*app) return;
  NSString *name = [NSString stringWithUTF8String:app];
  if (!name) return;
  [[NSDistributedNotificationCenter defaultCenter]
      postNotificationName:@"org.owllinker.SquirrelTranslate.QueryModeChanged"
      object:name userInfo:@{@"pid": @(getpid())} deliverImmediately:YES];
}
