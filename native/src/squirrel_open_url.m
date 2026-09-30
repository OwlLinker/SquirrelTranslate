#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 2) return 2;

    NSString *url_string = [NSString stringWithUTF8String:argv[1]];
    if (!url_string || url_string.length == 0) return 2;

    NSURL *https_url = [NSURL URLWithString:@"https://example.com"];
    NSURL *browser_url = [[NSWorkspace sharedWorkspace]
        URLForApplicationToOpenURL:https_url];
    if (!browser_url) return 3;
    NSString *bundle_identifier =
        [NSBundle bundleWithURL:browser_url].bundleIdentifier;
    if (bundle_identifier.length == 0) return 3;

    NSAppleEventDescriptor *target =
        [NSAppleEventDescriptor descriptorWithBundleIdentifier:bundle_identifier];
    if (!target) return 4;

    NSAppleEventDescriptor *event = [NSAppleEventDescriptor
        appleEventWithEventClass:kInternetEventClass
                         eventID:kAEGetURL
                 targetDescriptor:target
                     returnID:kAutoGenerateReturnID
                transactionID:kAnyTransactionID];
    [event setParamDescriptor:[NSAppleEventDescriptor descriptorWithString:url_string]
                   forKeyword:keyDirectObject];

    NSError *error = nil;
    NSAppleEventDescriptor *reply =
        [event sendEventWithOptions:kAENoReply timeout:3 error:&error];
    return reply || !error ? 0 : 5;
  }
}
