#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

// All state lives on the main run loop. No input text is logged or copied.
// An IME probe keeps ordinary input intact; accepted text is submitted to the
// original focused element, never to a replacement or the entire field value.
@class STInputBar;
static const int64_t STReplayedEvent = 0x5354494e505554;
static BOOL STPreviewDiagnostics;
static BOOL STBufferedPreview;
static BOOL STTraceDiagnostics;
static NSString *const STHealthRequest = @"org.owllinker.SquirrelTranslate.InputBar.HealthRequest";
static NSString *const STHealthResponse = @"org.owllinker.SquirrelTranslate.InputBar.HealthResponse";
static NSString *const STQueryMarker = @"~/Library/Rime/input_translation.query.active";

static NSString *STQueryMarkerPath(void) {
  return [STQueryMarker stringByExpandingTildeInPath];
}

static void STSetQueryMarker(BOOL active) {
  NSString *path = STQueryMarkerPath();
  if (active) {
    int descriptor = open(path.fileSystemRepresentation, O_CREAT | O_WRONLY | O_TRUNC, 0600);
    if (descriptor >= 0) {
      char process_id[32];
      int length = snprintf(process_id, sizeof(process_id), "%d\n", getpid());
      if (length > 0) write(descriptor, process_id, (size_t)length);
      close(descriptor);
    }
  } else {
    unlink(path.fileSystemRepresentation);
  }
}

@interface STPanel : NSPanel
@end
@implementation STPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface STTextView : NSView <NSTextInputClient>
@property(nonatomic, weak) STInputBar *owner;
@property(nonatomic, copy) NSString *string;
@property(nonatomic, strong) NSMutableAttributedString *marked;
@property(nonatomic) NSRange selection;
- (BOOL)deliverInputEvent:(NSEvent *)event;
- (BOOL)handleNativeInputEvent:(NSEvent *)event;
@end

@interface STInputBar : NSObject <NSApplicationDelegate, NSWindowDelegate> {
  CFMachPortRef _tap;
  CFRunLoopSourceRef _tapSource;
  BOOL _prefixProbe;
  BOOL _prefixTimeoutScheduled;
  NSUInteger _generation;
  NSTimeInterval _prefixReadyDeadline;
  BOOL _opening;
  BOOL _drainQueued;
  NSUInteger _drainQueuedGeneration;
  BOOL _dismissing;
  BOOL _dismissRequested;
  BOOL _triggerHeld;
  CGKeyCode _triggerKeyCode;
  BOOL _hostWordInProgress;
  BOOL _retainPrefixMarkedText;
}
@property(nonatomic, strong) STPanel *panel;
@property(nonatomic, strong) STTextView *textView;
@property(nonatomic, strong) NSRunningApplication *previousApp;
@property(nonatomic, copy) NSString *requestedSourceID;
@property(nonatomic, strong) NSMutableArray *pendingEvents;
@property(nonatomic, strong) NSMutableArray *prefixEvents;
@property(nonatomic, strong) id originalElement;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *capturedKeys;
@property(nonatomic, strong) NSTimer *permissionTimer;
- (CGEventRef)handleEvent:(CGEventRef)event type:(CGEventType)type;
- (void)beginPrefix:(CGEventRef)event application:(NSRunningApplication *)application;
- (BOOL)bufferPreviewEvent:(NSEvent *)event;
- (void)refreshSource;
- (BOOL)secureInputEnabled;
- (BOOL)shouldUseNativeInput:(NSRunningApplication *)application;
- (void)scheduleDrain;
- (void)dispatchReadyInput;
- (void)requestDismiss;
- (BOOL)acceptPrefixComposition;
- (BOOL)retainPrefixMarkedText;
- (void)commitText:(NSString *)text;
- (void)passPrefixThrough;
- (void)postEvents:(NSArray *)events toPID:(pid_t)pid;
- (void)submitText:(NSString *)text toElement:(id)element;
- (void)dismiss;
- (void)showPanel;
- (void)preparePanel;
- (void)installTextClient;
- (void)reportHealth:(NSNotification *)notification;
@end

static NSString *STInputSourceID(void) {
  TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
  if (!source) return @"";
  NSString *identifier = [(__bridge NSString *)TISGetInputSourceProperty(
      source, kTISPropertyInputSourceID) copy];
  CFRelease(source);
  return identifier ?: @"";
}

static BOOL STIsLetter(NSEvent *event) {
  if (!event || (event.type != NSEventTypeKeyDown && event.type != NSEventTypeKeyUp)) return NO;
  if (event.modifierFlags & (NSEventModifierFlagCommand |
                            NSEventModifierFlagControl |
                            NSEventModifierFlagOption)) return NO;
  NSString *characters = event.charactersIgnoringModifiers;
  if (characters.length != 1) return NO;
  unichar letter = [characters characterAtIndex:0];
  return (letter >= 'a' && letter <= 'z') ||
         (letter >= 'A' && letter <= 'Z');
}

static BOOL STIsTrigger(NSEvent *event) {
  return STIsLetter(event) &&
      !(event.modifierFlags & (NSEventModifierFlagShift | NSEventModifierFlagCapsLock)) &&
      [event.charactersIgnoringModifiers isEqualToString:@"u"];
}

static BOOL STIsLocalInputEvent(NSEvent *event) {
  if (!event.CGEvent) return NO;
  int64_t tag = CGEventGetIntegerValueField(event.CGEvent, kCGEventSourceUserData);
  return tag == STReplayedEvent;
}

static NSEvent *STLocalInputEvent(NSEvent *event) {
  if (!event || (event.type != NSEventTypeKeyDown &&
      event.type != NSEventTypeKeyUp && event.type != NSEventTypeFlagsChanged)) return nil;
  if (!event.CGEvent) return nil;
  CGEventRef copy = CGEventCreateCopy(event.CGEvent);
  if (!STIsLocalInputEvent(event))
    CGEventSetIntegerValueField(copy, kCGEventSourceUserData, STReplayedEvent);
  CGEventSetIntegerValueField(copy, kCGEventTargetUnixProcessID, getpid());
  NSEvent *local = [NSEvent eventWithCGEvent:copy];
  CFRelease(copy);
  return local;
}

static id STCopyAttribute(AXUIElementRef element, CFStringRef attribute) {
  CFTypeRef value = NULL;
  if (!element || AXUIElementCopyAttributeValue(element, attribute, &value) !=
                      kAXErrorSuccess) return nil;
  return CFBridgingRelease(value);
}

static BOOL STIsTextInputRole(NSString *role) {
  return [@[(NSString *)kAXTextFieldRole, (NSString *)kAXTextAreaRole,
             (NSString *)kAXComboBoxRole, @"AXSearchField", @"AXSecureTextField"]
      containsObject:role ?: @""];
}

static BOOL STIsInputMethodApplication(NSRunningApplication *application) {
  NSString *bundleID = application.bundleIdentifier ?: @"";
  return [bundleID isEqualToString:@"im.rime.inputmethod.Squirrel"] ||
      [bundleID hasPrefix:@"im.rime.inputmethod."] ||
      [bundleID hasPrefix:@"com.apple.inputmethod."];
}

static void STSourceChanged(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object,
                            CFDictionaryRef userInfo) {
  (void)center; (void)name; (void)object; (void)userInfo;
  dispatch_async(dispatch_get_main_queue(), ^{
    [(__bridge STInputBar *)observer refreshSource];
  });
}

static CGEventRef STEventTap(CGEventTapProxy proxy, CGEventType type,
                            CGEventRef event, void *context) {
  (void)proxy;
  @autoreleasepool {
    return [(__bridge STInputBar *)context handleEvent:event type:type];
  }
}

@implementation STTextView
- (BOOL)acceptsFirstResponder { return YES; }
// NSView already owns its NSTextInputContext for NSTextInputClient subclasses.
// Use that instance so AppKit's responder lifecycle and all key delivery share
// the same conversion session, rather than maintaining a parallel context.
- (NSString *)string { return self.marked.string ?: @""; }
- (void)setString:(NSString *)string {
  self.marked = [[NSMutableAttributedString alloc] initWithString:string ?: @""];
  self.selection = NSMakeRange(self.marked.length, 0);
}
- (BOOL)hasMarkedText { return self.marked.length > 0; }
- (NSRange)markedRange {
  return self.hasMarkedText ? NSMakeRange(0, self.marked.length) : NSMakeRange(NSNotFound, 0);
}
- (NSRange)selectedRange { return self.selection; }
- (void)setMarkedText:(id)text selectedRange:(NSRange)selection
     replacementRange:(NSRange)replacement {
  (void)replacement;
  NSString *value = [text isKindOfClass:NSAttributedString.class] ? [text string] : text;
  if (STTraceDiagnostics)
    fprintf(stderr, "query: ime_marked=%d\n", value.length > 0);
  if (!value.length && [self.owner retainPrefixMarkedText] && self.hasMarkedText) {
    if (STTraceDiagnostics) fprintf(stderr, "query: ime_empty_marked_ignored=1\n");
    return;
  }
  if (value.length) [self.owner acceptPrefixComposition];
  self.string = value;
  NSUInteger start = MIN(selection.location, self.marked.length);
  self.selection = NSMakeRange(start, MIN(selection.length, self.marked.length - start));
  if (STPreviewDiagnostics) {
    fprintf(stderr, "preview: marked_length=%lu input_box=none\n", (unsigned long)self.marked.length);
  }
}
- (void)unmarkText {
  if (STTraceDiagnostics)
    fprintf(stderr, "query: client_unmark=1 had_marked=%d\n", self.hasMarkedText);
  if ([self.owner retainPrefixMarkedText] && self.hasMarkedText) {
    if (STTraceDiagnostics) fprintf(stderr, "query: client_unmark_ignored=1\n");
    return;
  }
  self.string = @"";
}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
                                               actualRange:(NSRangePointer)actual {
  if (range.location == NSNotFound || range.location > self.marked.length) return nil;
  range.length = MIN(range.length, self.marked.length - range.location);
  if (actual) *actual = range;
  return [self.marked attributedSubstringFromRange:range];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point { (void)point; return 0; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual {
  if (actual) *actual = range;
  return [self.window convertRectToScreen:[self convertRect:self.bounds toView:nil]];
}
- (void)insertText:(id)text replacementRange:(NSRange)range {
  (void)range;
  NSString *value = [text isKindOfClass:NSAttributedString.class] ? [text string] : text;
  if (STTraceDiagnostics)
    fprintf(stderr, "query: client_insert=1 nonempty=%d\n", value.length > 0);
  self.string = @"";
  [self.owner commitText:value];
}
- (void)doCommandBySelector:(SEL)selector {
  if (STTraceDiagnostics)
    fprintf(stderr, "query: client_command cancel=%d newline=%d\n",
        selector == @selector(cancelOperation:), selector == @selector(insertNewline:));
  if (selector == @selector(cancelOperation:) || selector == @selector(insertNewline:))
    [self.owner requestDismiss];
}
- (void)keyDown:(NSEvent *)event {
  if (STBufferedPreview && !STIsLocalInputEvent(event) &&
      [self.owner bufferPreviewEvent:event]) return;
  if (STTraceDiagnostics && event.keyCode == kVK_ANSI_U)
    fprintf(stderr, "query: client_received_u_key=1\n");
  // Give the input method the real AppKit event before applying a fallback.
  if ([self handleNativeInputEvent:event]) return;
  if (event.keyCode == kVK_Escape) {
    [self.owner requestDismiss];
    return;
  }
  if ((event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter) &&
      !self.hasMarkedText) {
    [self.owner requestDismiss];
    return;
  }
}
- (void)keyUp:(NSEvent *)event {
  if (STBufferedPreview && !STIsLocalInputEvent(event) &&
      [self.owner bufferPreviewEvent:event]) return;
  [self handleNativeInputEvent:event];
}
- (void)flagsChanged:(NSEvent *)event {
  if (STBufferedPreview && !STIsLocalInputEvent(event) &&
      [self.owner bufferPreviewEvent:event]) return;
  [self handleNativeInputEvent:event];
}
- (BOOL)deliverInputEvent:(NSEvent *)event {
  if (!self.window) return NO;
  NSEvent *local = STLocalInputEvent(event);
  if (!local) return NO;
  if (STTraceDiagnostics)
    fprintf(stderr, "query: app_dispatch type=%ld window_match=%d\n",
        (long)local.type, local.window == self.window);
  // Preserve the captured event's native backing and let AppKit's main event
  // loop dispatch it. A synchronous sendEvent does not establish currentEvent.
  [NSApp postEvent:local atStart:NO];
  return YES; // Dispatched locally; this is not an IME-consumption result.
}
- (BOOL)handleNativeInputEvent:(NSEvent *)event {
  BOOL handled = [self.inputContext handleEvent:event];
  if (STTraceDiagnostics)
    fprintf(stderr, "query: input_event type=%ld letter=%d escape=%d handled=%d current_context=%d app_event=%d window_match=%d\n",
        (long)event.type, STIsLetter(event), event.keyCode == kVK_Escape, handled,
        NSTextInputContext.currentInputContext == self.inputContext,
        NSApp.currentEvent == event, event.window == self.window);
  return handled;
}
@end

@implementation STInputBar
- (instancetype)init {
  if ((self = [super init])) {
    _pendingEvents = [NSMutableArray array];
    _prefixEvents = [NSMutableArray array];
    _capturedKeys = [NSMutableSet set];
  }
  return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  STSetQueryMarker(NO);
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  [self preparePanel];
  [[NSDistributedNotificationCenter defaultCenter] addObserver:self
      selector:@selector(reportHealth:) name:STHealthRequest object:nil
      suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
  [[NSWorkspace sharedWorkspace].notificationCenter addObserver:self
      selector:@selector(applicationActivated:)
      name:NSWorkspaceDidActivateApplicationNotification object:nil];
  CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(),
      (__bridge void *)self, STSourceChanged,
      kTISNotifySelectedKeyboardInputSourceChanged, NULL,
      CFNotificationSuspensionBehaviorDeliverImmediately);
  [self refreshSource];
  if (![self startEventTap]) {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    __weak STInputBar *weakSelf = self;
    self.permissionTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES
        block:^(NSTimer *timer) {
      STInputBar *owner = weakSelf;
      if (!owner || [owner startEventTap]) {
        [timer invalidate];
        owner.permissionTimer = nil;
      }
    }];
  }
}

- (void)reportHealth:(NSNotification *)notification {
  NSString *token = notification.object;
  NSNumber *pid = notification.userInfo[@"pid"];
  if (![token isKindOfClass:NSString.class] || token.length > 64 ||
      ![pid isKindOfClass:NSNumber.class] || pid.intValue != getpid()) return;
  [[NSDistributedNotificationCenter defaultCenter]
      postNotificationName:STHealthResponse object:token userInfo:@{
        @"pid": @(getpid()), @"accessibility": @(AXIsProcessTrusted()),
        @"event_tap": @(_tap && CGEventTapIsEnabled(_tap)),
        @"input_source": STInputSourceID(), @"secure_input": @([self secureInputEnabled]),
        @"client_visible": @(self.panel.visible), @"client_key": @(self.panel.keyWindow),
        @"ime_marked": @(self.textView.hasMarkedText), @"opening": @(_opening)
      } deliverImmediately:YES];
}

- (void)preparePanel {
  // A transparent key window keeps an ordinary IMK text client alive; it is
  // not hidden/offscreen, and has no controls, drawing, caret or shadow.
  self.panel = [[STPanel alloc] initWithContentRect:NSMakeRect(0, 0, 1, 24)
      styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
  self.panel.delegate = self;
  self.panel.title = @"SquirrelTranslate 候选查询";
  self.panel.level = NSFloatingWindowLevel;
  self.panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
                                  NSWindowCollectionBehaviorFullScreenAuxiliary;
  self.panel.hidesOnDeactivate = NO;
  self.panel.releasedWhenClosed = NO;
  self.panel.hasShadow = NO;
  self.panel.opaque = NO;
  self.panel.backgroundColor = NSColor.clearColor;
  self.panel.ignoresMouseEvents = YES;
}

- (BOOL)startEventTap {
  if (_tap) return YES;
  if (!AXIsProcessTrusted()) {
    if (STTraceDiagnostics) fprintf(stderr, "query: event_tap=permission_required\n");
    return NO;
  }
  CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) |
                     CGEventMaskBit(kCGEventKeyUp) |
                     CGEventMaskBit(kCGEventFlagsChanged) |
                     CGEventMaskBit(kCGEventLeftMouseDown) |
                     CGEventMaskBit(kCGEventLeftMouseUp);
  _tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
      kCGEventTapOptionDefault, mask, STEventTap, (__bridge void *)self);
  if (!_tap) {
    if (STTraceDiagnostics) fprintf(stderr, "query: event_tap=create_failed\n");
    return NO;
  }
  _tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
  if (!_tapSource) {
    CFMachPortInvalidate(_tap);
    CFRelease(_tap);
    _tap = NULL;
    if (STTraceDiagnostics)
      fprintf(stderr, "query: event_tap=run_loop_source_failed\n");
    return NO;
  }
  CFRunLoopAddSource(CFRunLoopGetMain(), _tapSource, kCFRunLoopCommonModes);
  CGEventTapEnable(_tap, true);
  if (STTraceDiagnostics) {
    fprintf(stderr, "query: event_tap=ready\n");
    fflush(stderr);
  }
  return YES;
}

- (void)refreshSource {
  NSString *sourceID = STInputSourceID();
  if (![sourceID isEqualToString:self.requestedSourceID]) {
    // A manual input-source switch starts a fresh query attempt. In particular,
    // allow retrying u immediately after switching to the Chinese IME.
    _hostWordInProgress = NO;
  }
  // Preserve the user's source without classifying it or querying Rime mode.
  if (!self.panel.visible && !_opening) self.requestedSourceID = sourceID;
}

- (void)applicationActivated:(NSNotification *)notification {
  NSRunningApplication *app = notification.userInfo[NSWorkspaceApplicationKey];
  if (app.processIdentifier == getpid() || STIsInputMethodApplication(app)) return;
  if (self.panel.visible && self.previousApp &&
      app.processIdentifier != self.previousApp.processIdentifier) {
    if (STTraceDiagnostics) fprintf(stderr,
        "query: close_reason=other_application app=%s pid=%d previous=%s previous_pid=%d\n",
        app.bundleIdentifier.UTF8String ?: "", app.processIdentifier,
        self.previousApp.bundleIdentifier.UTF8String ?: "", self.previousApp.processIdentifier);
    [self dismiss];
  }
  _hostWordInProgress = NO;
}

- (BOOL)secureInputEnabled { return IsSecureEventInputEnabled(); }

- (BOOL)shouldUseNativeInput:(NSRunningApplication *)application {
  // Check metadata only at a possible prefix boundary, never read field text.
  // Missing/slow accessibility information must not steal a real editor's u.
  AXUIElementRef app = AXUIElementCreateApplication(application.processIdentifier);
  AXUIElementSetMessagingTimeout(app, 0.02);
  id focused = STCopyAttribute(app, kAXFocusedUIElementAttribute);
  CFRelease(app);
  if (!focused || CFGetTypeID((__bridge CFTypeRef)focused) != AXUIElementGetTypeID())
    return YES;
  AXUIElementRef element = (__bridge AXUIElementRef)focused;
  AXUIElementSetMessagingTimeout(element, 0.02);
  id role = STCopyAttribute(element, kAXRoleAttribute);
  if (![role isKindOfClass:NSString.class]) return YES;
  if (STIsTextInputRole(role)) return YES;
  id editable = STCopyAttribute(element, CFSTR("AXEditable"));
  if ([editable isKindOfClass:NSNumber.class] && [editable boolValue]) return YES;
  Boolean selectedTextIsSettable = false;
  AXError error = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute,
                                                &selectedTextIsSettable);
  if (error == kAXErrorSuccess) return selectedTextIsSettable;
  return error != kAXErrorAttributeUnsupported;
}

- (void)queueEvent:(CGEventRef)event {
  CGEventRef copy = CGEventCreateCopy(event);
  [self.pendingEvents addObject:CFBridgingRelease(copy)];
  [self scheduleDrain];
}

- (void)scheduleDrain {
  if (_drainQueued && _drainQueuedGeneration == _generation) return;
  _drainQueued = YES;
  NSUInteger generation = _generation;
  _drainQueuedGeneration = generation;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (generation != self->_generation) {
      if (self->_drainQueuedGeneration == generation)
        self->_drainQueued = NO;
      return;
    }
    if (self->_opening && !self.panel.visible) [self showPanel];
    // Once the IMK client has accepted the initial prefix, this drain is only
    // a continuation trigger. Squirrel may briefly change key/context state
    // while opening its candidate panel; the startup timeout must not close a
    // session that has already produced candidates.
    if (!self->_opening) {
      self->_drainQueued = NO;
      if (self.pendingEvents.count > 0) [self drainEvents];
      return;
    }
    if (!self.panel.keyWindow || !NSApp.active ||
        self.panel.firstResponder != self.textView ||
        NSTextInputContext.currentInputContext != self.textView.inputContext) {
      self->_drainQueued = NO;
      if (NSProcessInfo.processInfo.systemUptime >= self->_prefixReadyDeadline) {
        if (STTraceDiagnostics) fprintf(stderr, "query: prefix_response=window_timeout\n");
        if (self->_prefixProbe) [self passPrefixThrough];
        else [self dismiss];
      } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
          if (generation == self->_generation) [self scheduleDrain];
        });
      }
      return;
    }
    [self dispatchReadyInput];
  });
}

- (void)dispatchReadyInput {
  NSUInteger generation = _generation;
  // Send the mode probe exactly once. Lua replaces its prefix on the next
  // letter inside Rime, without cancelling this native conversion session.
  if (_prefixProbe) {
    if (!_prefixTimeoutScheduled) {
      _prefixTimeoutScheduled = YES;
      if (STTraceDiagnostics) fprintf(stderr, "query: input_context_ready=1\n");
      if (self.prefixEvents.count) {
        NSEvent *probe = [NSEvent eventWithCGEvent:
            (__bridge CGEventRef)self.prefixEvents.firstObject];
        [self.textView deliverInputEvent:probe];
      }
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                     dispatch_get_main_queue(), ^{
        if (generation == self->_generation && self->_prefixProbe)
          [self passPrefixThrough];
      });
    }
    // Acceptance queued continuation; keep its drain guard intact.
    if (_prefixProbe) _drainQueued = NO;
    return;
  }
  _drainQueued = NO;
  _opening = NO;
  [self drainEvents];
  if (self.pendingEvents.count > 0) [self scheduleDrain];
}

- (CGEventRef)handleEvent:(CGEventRef)event type:(CGEventType)type {
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    if (_tap) CGEventTapEnable(_tap, true);
    return event;
  }
  int64_t eventTag = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
  if (eventTag == STReplayedEvent)
    return event;
  if (type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp) {
    if (!self.panel.visible && !_opening) {
      _hostWordInProgress = NO;
    }
    return event;
  }
  NSNumber *key = @(CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode));
  if (_triggerHeld && key.unsignedIntValue == _triggerKeyCode) {
    if (type == kCGEventKeyUp) {
      if (_prefixProbe) [self.prefixEvents addObject:CFBridgingRelease(CGEventCreateCopy(event))];
      _triggerHeld = NO;
      [self.capturedKeys removeObject:key];
      return NULL;
    }
    // Only consume the initiating prefix press and its unmatched release.
    // A later u/U press (including autorepeat) belongs to the query, not to
    // the probe. Its release must follow the ordinary capture path as well.
    if (type == kCGEventKeyDown) _triggerHeld = NO;
  }
  if (type == kCGEventKeyUp && [self.capturedKeys containsObject:key]) {
    [self.capturedKeys removeObject:key];
    if (_prefixProbe) [self.prefixEvents addObject:CFBridgingRelease(CGEventCreateCopy(event))];
    if (!_opening && self.panel.visible && self.panel.keyWindow && NSApp.active)
      return event;
    if (_opening) {
      if (_prefixProbe) [self.pendingEvents addObject:CFBridgingRelease(CGEventCreateCopy(event))];
      else [self queueEvent:event];
    }
    return NULL;
  }
  if ([self secureInputEnabled]) return event;
  if (type == kCGEventFlagsChanged && !self.panel.visible && !_opening) {
    // Shift and other modifiers do not finish a word or a live composition.
    // Actual input-source changes are handled separately by refreshSource.
    return event;
  }
  NSEvent *native = [NSEvent eventWithCGEvent:event];
  if (!native) return event;
  if (STTraceDiagnostics && type == kCGEventKeyDown && native.keyCode == kVK_ANSI_U) {
    fprintf(stderr, "query: prefix_event characters=%lu trigger=%d visible=%d opening=%d\n",
        (unsigned long)native.charactersIgnoringModifiers.length, STIsTrigger(native),
        self.panel.visible, _opening);
    fflush(stderr);
  }
  if (!self.panel.visible && !_opening && type == kCGEventKeyDown &&
      (native.keyCode == kVK_Escape || native.keyCode == kVK_Space ||
       native.keyCode == kVK_Return || native.keyCode == kVK_ANSI_KeypadEnter)) {
    _hostWordInProgress = NO;
    return event;
  }
  if (self.panel.visible || _opening) {
    if (!_opening && self.panel.keyWindow && NSApp.active) {
      // Once focused, let AppKit/IMK receive original hardware events normally.
      // Remember releases in case a candidate shortcut activates another app.
      if (type == kCGEventKeyDown) [self.capturedKeys addObject:key];
      return event;
    }
    if (!_opening) {
      [self dismiss];
      return event;
    }
    // Keep ordinary application-switching and non-editing Command shortcuts.
    if (type == kCGEventKeyDown && (native.modifierFlags & NSEventModifierFlagCommand) &&
        ![@[@"a", @"c", @"v", @"x", @"z"] containsObject:native.charactersIgnoringModifiers.lowercaseString]) {
      [self dismiss];
      return event;
    }
    if (type == kCGEventKeyDown) [self.capturedKeys addObject:key];
    if (type == kCGEventKeyDown || type == kCGEventFlagsChanged) {
      if (_prefixProbe) {
        [self.prefixEvents addObject:CFBridgingRelease(CGEventCreateCopy(event))];
        [self.pendingEvents addObject:CFBridgingRelease(CGEventCreateCopy(event))];
        [self scheduleDrain];
      } else [self queueEvent:event];
      return NULL;
    }
    return event;
  }
  if (type != kCGEventKeyDown || !STIsLetter(native)) return event;
  if (!STIsTrigger(native)) {
    _hostWordInProgress = YES;
    return event;
  }
  if (STTraceDiagnostics) {
    fprintf(stderr, "query: trigger repeat=%lld host_word_in_progress=%d\n",
        (long long)CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat),
        _hostWordInProgress);
    fflush(stderr);
  }
  if (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) ||
      _hostWordInProgress) {
    // A pause never turns the u in lu/shuru into a new query prefix.
    _hostWordInProgress = YES;
    return event;
  }
  NSRunningApplication *application = NSWorkspace.sharedWorkspace.frontmostApplication;
  if (!application || application.processIdentifier == getpid() ||
      [@[@"com.apple.loginwindow", @"com.apple.SecurityAgent"]
          containsObject:application.bundleIdentifier ?: @""]) return event;
  if ([self shouldUseNativeInput:application]) {
    _hostWordInProgress = YES;
    return event;
  }
  [self beginPrefix:event application:application];
  return NULL;
}

- (void)beginPrefix:(CGEventRef)event application:(NSRunningApplication *)application {
  STSetQueryMarker(YES);
  self.previousApp = application;
  ++_generation;
  _drainQueued = NO;
  [self.pendingEvents removeAllObjects];
  [self.prefixEvents removeAllObjects];
  [self.prefixEvents addObject:CFBridgingRelease(CGEventCreateCopy(event))];
  self.requestedSourceID = STInputSourceID();
  _prefixProbe = YES;
  _prefixTimeoutScheduled = NO;
  _prefixReadyDeadline = NSProcessInfo.processInfo.systemUptime + 1.0;
  _opening = YES;
  _dismissRequested = NO;
  _triggerHeld = YES;
  _triggerKeyCode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
  [self.capturedKeys addObject:@(_triggerKeyCode)];
  [self scheduleDrain];
}

- (BOOL)bufferPreviewEvent:(NSEvent *)event {
  CGEventRef raw = event.CGEvent;
  if (!raw) return NO;
  if (!_opening && !self.textView.hasMarkedText &&
      event.type == NSEventTypeKeyDown && STIsTrigger(event)) {
    [self beginPrefix:raw application:self.previousApp];
    return YES;
  }
  return [self handleEvent:raw type:CGEventGetType(raw)] == NULL;
}

- (void)postEvents:(NSArray *)events toPID:(pid_t)pid {
  for (id object in events) {
    CGEventRef copy = CGEventCreateCopy((__bridge CGEventRef)object);
    if (!copy) continue;
    CGEventSetIntegerValueField(copy, kCGEventSourceUserData, STReplayedEvent);
    CGEventPostToPid(pid, copy);
    CFRelease(copy);
  }
}

- (BOOL)acceptPrefixComposition {
  if (!_prefixProbe) return NO;
  if (STTraceDiagnostics) fprintf(stderr, "query: prefix_accepted=1\n");
  _prefixProbe = NO;
  _opening = NO;
  _retainPrefixMarkedText = YES;
  [self.prefixEvents removeAllObjects];
  _dismissRequested = NO;
  // Acknowledge Chinese composition without clearing or deactivating it.
  // Following letters use native delivery; the helper-scoped Lua processor
  // replaces only the first prefix inside the same Rime key transaction.
  _drainQueued = NO;
  [self scheduleDrain];
  if (STTraceDiagnostics) {
    NSUInteger generation = _generation;
    NSArray<NSNumber *> *delays = @[@100, @300, @600, @1000];
    for (NSNumber *delay in delays) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay.longLongValue * NSEC_PER_MSEC),
                     dispatch_get_main_queue(), ^{
        if (generation != self->_generation) return;
        fprintf(stderr, "query: prefix_wait_snapshot_ms=%lld visible=%d key=%d active=%d marked=%d current_context=%d\n",
            delay.longLongValue, self.panel.visible, self.panel.keyWindow, NSApp.active,
            self.textView.hasMarkedText,
            NSTextInputContext.currentInputContext == self.textView.inputContext);
        fflush(stderr);
      });
    }
  }
  return YES;
}

- (BOOL)retainPrefixMarkedText {
  return _retainPrefixMarkedText;
}


- (void)passPrefixThrough {
  if (!_prefixProbe) return;
  if (STTraceDiagnostics) fprintf(stderr, "query: prefix_passthrough=1\n");
  NSArray *events = [self.prefixEvents copy];
  NSRunningApplication *target = self.previousApp;
  _triggerHeld = NO;
  [self.capturedKeys removeAllObjects];
  [self dismiss];
  NSUInteger generation = _generation;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
    if (generation != self->_generation || !target || target.terminated ||
        [self secureInputEnabled] ||
        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != target.processIdentifier)
      return;
    [self postEvents:events toPID:target.processIdentifier];
  });
}

- (void)commitText:(NSString *)text {
  // Ignore callbacks from a client already closed by fallback or Escape.
  // Otherwise a late insert could cancel the scheduled replay generation.
  if (_dismissing || (!self.panel.visible && !_opening)) return;
  if (STTraceDiagnostics)
    fprintf(stderr, "query: commit_callback probe=%d marked=%d\n",
        _prefixProbe, self.textView.hasMarkedText);
  if (_prefixProbe) {
    if (STTraceDiagnostics) fprintf(stderr, "query: prefix_response=direct_commit\n");
    // A direct commit means no composition was formed. Replay actual events
    // (including u and buffered following keys), not an inferred English mode.
    [self passPrefixThrough];
    return;
  }
  if (![text isKindOfClass:NSString.class] || !text.length) return;
  id element = self.originalElement;
  NSRunningApplication *target = self.previousApp;
  [self dismiss];
  NSUInteger generation = _generation;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
    if (generation != self->_generation || !target || target.terminated ||
        [self secureInputEnabled] ||
        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != target.processIdentifier)
      return;
    if (!element || CFGetTypeID((__bridge CFTypeRef)element) != AXUIElementGetTypeID()) return;
    AXUIElementRef app = AXUIElementCreateApplication(target.processIdentifier);
    AXUIElementSetMessagingTimeout(app, 0.15);
    id focused = STCopyAttribute(app, kAXFocusedUIElementAttribute);
    CFRelease(app);
    if (!focused || !CFEqual((__bridge CFTypeRef)focused, (__bridge CFTypeRef)element)) return;
    [self submitText:text toElement:element];
  });
}

- (void)submitText:(NSString *)text toElement:(id)element {
  // Only replace the current selection. Do not read or replace the field's
  // complete value, synthesize paste, or classify whether this is an editor.
  AXUIElementRef target = (__bridge AXUIElementRef)element;
  AXUIElementSetMessagingTimeout(target, 0.15);
  AXError error = AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute,
                                              (__bridge CFStringRef)text);
  if (STTraceDiagnostics) fprintf(stderr, "query: commit_status=%d\n", error);
}

- (void)installTextClient {
  STTextView *previousClient = self.textView;
  previousClient.owner = nil;
  previousClient.string = @"";
  [previousClient.inputContext discardMarkedText];
  self.textView = [[STTextView alloc] initWithFrame:NSMakeRect(0, 0, 1, 24)];
  self.textView.string = @"";
  self.textView.owner = self;
  self.panel.contentView = self.textView;
  [self.panel makeFirstResponder:self.textView];
  if (self.requestedSourceID.length &&
      ![STInputSourceID() isEqualToString:self.requestedSourceID])
    self.textView.inputContext.selectedKeyboardInputSource = self.requestedSourceID;
  // activate/deactivate are system-invoked override points, not client APIs.
  // Becoming first responder in the key window activates this context.
}

- (void)showPanel {
  // Capture only the original destination. No role/editability classification
  // and no failure here can prevent the candidate session from opening.
  self.originalElement = nil;
  if (self.previousApp && !self.previousApp.terminated) {
    AXUIElementRef app = AXUIElementCreateApplication(self.previousApp.processIdentifier);
    AXUIElementSetMessagingTimeout(app, 0.15);
    self.originalElement = STCopyAttribute(app, kAXFocusedUIElementAttribute);
    CFRelease(app);
  }
  NSScreen *screen = NSScreen.mainScreen;
  NSPoint mouse = NSEvent.mouseLocation;
  for (NSScreen *candidate in NSScreen.screens) {
    if (NSPointInRect(mouse, candidate.frame)) { screen = candidate; break; }
  }
  NSRect visible = screen.visibleFrame;
  [self.panel setFrameOrigin:NSMakePoint(
      MIN(MAX(mouse.x + 12, NSMinX(visible)), NSMaxX(visible) - 1),
      MIN(MAX(mouse.y - 24, NSMinY(visible)), NSMaxY(visible) - 24))];
  // Prepare the responder before activating the window. Do not first expose
  // an empty key window and then start a second IMK activation transaction.
  [self installTextClient];
  [NSApp activateIgnoringOtherApps:YES];
  [self.panel makeKeyAndOrderFront:nil];
  if (STTraceDiagnostics) {
    fprintf(stderr, "query: window_visible=%d key_window=%d app_active=%d\n",
        self.panel.visible, self.panel.keyWindow, NSApp.active);
    fflush(stderr);
  }
}

- (void)drainEvents {
  NSArray *pending = [self.pendingEvents copy];
  [self.pendingEvents removeAllObjects];
  for (id object in pending) {
    CGEventRef raw = (__bridge CGEventRef)object;
    NSEvent *native = [NSEvent eventWithCGEvent:raw];
    if (!native) continue;
    if (_dismissRequested && native.type == NSEventTypeKeyDown && STIsLetter(native)) {
      [self.textView.inputContext discardMarkedText];
      self.textView.string = @"";
      _dismissRequested = NO;
    }
    if (!self.panel.visible || !self.panel.keyWindow || !NSApp.active) continue;
    // AppKit must see the helper-window event before its native input context.
    // Never hand the original application's windowless event straight to IMK.
    [self.textView deliverInputEvent:native];
  }
  if (_dismissRequested) {
    // Let the input method finish Escape before taking away its text client.
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self->_dismissRequested && self.pendingEvents.count == 0) [self dismiss];
    });
  }
}

- (void)requestDismiss {
  if (_dismissing || (!self.panel.visible && !_opening)) return;
  if (STTraceDiagnostics) fprintf(stderr, "query: close_reason=text_client\n");
  _dismissRequested = YES;
  NSUInteger generation = _generation;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (generation == self->_generation && self->_dismissRequested &&
        !self->_drainQueued && self.pendingEvents.count == 0)
      [self dismiss];
  });
}


- (void)dismiss {
  if (_dismissing || (!self.panel.visible && !_opening && !self.previousApp)) return;
  _dismissing = YES;
  STSetQueryMarker(NO);
  ++_generation;
  _prefixProbe = NO;
  _retainPrefixMarkedText = NO;
  _prefixTimeoutScheduled = NO;
  _drainQueued = NO;
  self.textView.owner = nil;
  [self.textView unmarkText];
  [self.textView.inputContext discardMarkedText];
  [self.panel orderOut:nil];
  _opening = NO;
  _dismissRequested = NO;
  if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == getpid() &&
      self.previousApp && !self.previousApp.terminated)
    [self.previousApp activateWithOptions:NSApplicationActivateIgnoringOtherApps];
  self.previousApp = nil;
  self.originalElement = nil;
  [self.pendingEvents removeAllObjects];
  [self.prefixEvents removeAllObjects];
  _dismissing = NO;
  _hostWordInProgress = NO;
  if (STPreviewDiagnostics) fprintf(stderr, "preview: closed=%d marked_length=%lu\n",
      !self.panel.visible, (unsigned long)self.textView.string.length);
}

- (void)windowDidResignKey:(NSNotification *)notification {
  (void)notification;
  // IMK/Squirrel can temporarily move key status while updating its native
  // candidate panel. Losing key status alone is not a close request; actual
  // application switches are handled by the workspace activation observer.
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  (void)notification;
  STSetQueryMarker(NO);
  [self.permissionTimer invalidate];
  [[NSWorkspace sharedWorkspace].notificationCenter removeObserver:self];
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
  CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDistributedCenter(),
                                          (__bridge void *)self);
  if (_tapSource) {
    CFRunLoopRemoveSource(CFRunLoopGetMain(), _tapSource, kCFRunLoopCommonModes);
    CFRelease(_tapSource); _tapSource = NULL;
  }
  if (_tap) { CFMachPortInvalidate(_tap); CFRelease(_tap); _tap = NULL; }
}
@end

// Exercise the input-capture boundary without installing a tap, opening a
// window, requesting permissions, or injecting keys into another application.
@interface STInputBarTestClient : STTextView
@property(nonatomic) NSUInteger deliveredEvents;
@property(nonatomic, copy) NSString *firstCharacters;
@end
@implementation STInputBarTestClient
- (BOOL)deliverInputEvent:(NSEvent *)event {
  if (!self.deliveredEvents) self.firstCharacters = event.characters;
  ++self.deliveredEvents;
  if (event.type == NSEventTypeKeyDown)
    [self setMarkedText:event.characters selectedRange:NSMakeRange(1, 0)
        replacementRange:NSMakeRange(NSNotFound, 0)];
  return YES;
}
@end

@interface STInputBarTest : STInputBar
@property(nonatomic) BOOL testSecureInput;
@property(nonatomic) BOOL testNativeInput;
@property(nonatomic, strong) NSArray *passedEvents;
@property(nonatomic, copy) NSString *submittedText;
@property(nonatomic) NSUInteger installedClients;
- (void)runTests;
@end

static CGEventRef STTestKey(CGKeyCode code, unichar letter, BOOL down) {
  CGEventRef event = CGEventCreateKeyboardEvent(NULL, code, down);
  CGEventSetFlags(event, 0);
  CGEventKeyboardSetUnicodeString(event, 1, &letter);
  return event;
}

@implementation STInputBarTest
- (void)scheduleDrain { }
- (BOOL)secureInputEnabled { return self.testSecureInput; }
- (BOOL)shouldUseNativeInput:(NSRunningApplication *)application {
  (void)application;
  return self.testNativeInput;
}
- (void)installTextClient {
  ++self.installedClients;
  self.textView.owner = nil;
  self.textView = [[STInputBarTestClient alloc] initWithFrame:NSMakeRect(0, 0, 1, 24)];
  self.textView.owner = self;
}
- (void)drainEvents {
  NSArray *events = [self.pendingEvents copy];
  [self.pendingEvents removeAllObjects];
  for (id object in events)
    [self.textView deliverInputEvent:[NSEvent eventWithCGEvent:(__bridge CGEventRef)object]];
}
- (void)passPrefixThrough {
  self.passedEvents = [self.prefixEvents copy];
  [self.prefixEvents removeAllObjects];
  [self.pendingEvents removeAllObjects];
  [self.capturedKeys removeAllObjects];
  _prefixProbe = _opening = _triggerHeld = _prefixTimeoutScheduled = NO;
  _hostWordInProgress = NO;
}
- (void)commitText:(NSString *)text {
  if (_prefixProbe || _dismissing) [super commitText:text];
  else self.submittedText = text;
}
- (void)runTests {
  CGEventRef triggerDown = STTestKey(kVK_ANSI_U, 'u', YES);
  CGEventRef triggerUp = STTestKey(kVK_ANSI_U, 'u', NO);
  CGEventRef first = STTestKey(kVK_ANSI_N, 'n', YES);
  CGEventRef second = STTestKey(kVK_ANSI_I, 'i', YES);
  CGEventRef firstUp = STTestKey(kVK_ANSI_N, 'n', NO);
  NSEvent *originalKey = [NSEvent eventWithCGEvent:triggerDown];
  NSEvent *localKey = STLocalInputEvent(originalKey);
  NSCAssert(STIsLocalInputEvent(localKey) && localKey.type == originalKey.type &&
      localKey.keyCode == originalKey.keyCode && localKey.timestamp == originalKey.timestamp &&
      localKey.modifierFlags == originalKey.modifierFlags &&
      [localKey.characters isEqualToString:originalKey.characters] &&
      [localKey.charactersIgnoringModifiers isEqualToString:originalKey.charactersIgnoringModifiers],
      @"captured input must preserve native backing, characters and modifiers");
  NSCAssert(STIsTextInputRole(@"AXTextField") && STIsTextInputRole(@"AXTextArea") &&
      STIsTextInputRole(@"AXComboBox") && STIsTextInputRole(@"AXSecureTextField") &&
      !STIsTextInputRole(@"AXWebArea") && !STIsTextInputRole(@"AXOutline"),
      @"native text fields must stay native; non-editing web/list regions can query");
  self.testNativeInput = YES;
  NSCAssert([self handleEvent:triggerDown type:kCGEventKeyDown] == triggerDown &&
      [self handleEvent:triggerUp type:kCGEventKeyUp] == triggerUp &&
      !_opening && !_prefixProbe && !_triggerHeld && !self.previousApp &&
      self.pendingEvents.count == 0 && self.prefixEvents.count == 0 &&
      self.capturedKeys.count == 0 && _hostWordInProgress,
      @"native or uncertain focus must receive original u events without takeover or replay");
  self.testNativeInput = NO;
  _hostWordInProgress = NO;
  NSCAssert([self handleEvent:triggerDown type:kCGEventKeyDown] == NULL &&
      _opening && _prefixProbe && self.prefixEvents.count == 1,
      @"non-editing u starts without input-source, mode or application-session gates");
  NSCAssert([self handleEvent:first type:kCGEventKeyDown] == NULL,
      @"capture the first following letter while activation settles");
  [self handleEvent:triggerUp type:kCGEventKeyUp];
  [self handleEvent:second type:kCGEventKeyDown];
  [self handleEvent:firstUp type:kCGEventKeyUp];
  NSCAssert(self.pendingEvents.count == 3 && self.prefixEvents.count == 5 &&
      CGEventGetIntegerValueField((__bridge CGEventRef)self.pendingEvents[0], kCGKeyboardEventKeycode) == kVK_ANSI_N &&
      CGEventGetIntegerValueField((__bridge CGEventRef)self.pendingEvents[1], kCGKeyboardEventKeycode) == kVK_ANSI_I &&
      CGEventGetType((__bridge CGEventRef)self.pendingEvents[2]) == kCGEventKeyUp,
      @"keep pinyin and fallback event order without losing key releases");

  [self commitText:@"u"];
  NSCAssert(!_opening && !_prefixProbe && self.passedEvents.count == 5 &&
      CGEventGetIntegerValueField((__bridge CGEventRef)self.passedEvents[0], kCGKeyboardEventKeycode) == kVK_ANSI_U &&
      CGEventGetIntegerValueField((__bridge CGEventRef)self.passedEvents[1], kCGKeyboardEventKeycode) == kVK_ANSI_N,
      @"an IME direct commit must replay u and all following original events");

  CGEventRef repeatedU = CGEventCreateCopy(triggerDown);
  CGEventSetIntegerValueField(repeatedU, kCGKeyboardEventAutorepeat, 1);
  CGEventRef uppercaseU = STTestKey(kVK_ANSI_U, 'U', YES);
  CGEventSetFlags(uppercaseU, kCGEventFlagMaskShift);
  CGEventRef uppercaseUp = STTestKey(kVK_ANSI_U, 'U', NO);
  CGEventSetFlags(uppercaseUp, kCGEventFlagMaskShift);
  [self handleEvent:triggerDown type:kCGEventKeyDown];
  NSCAssert([self handleEvent:repeatedU type:kCGEventKeyDown] == NULL &&
      !_triggerHeld && self.pendingEvents.count == 1,
      @"only the initial u is a prefix; held repeats must enter the query");
  [self handleEvent:triggerUp type:kCGEventKeyUp];
  [self handleEvent:triggerDown type:kCGEventKeyDown];
  [self handleEvent:triggerUp type:kCGEventKeyUp];
  [self handleEvent:uppercaseU type:kCGEventKeyDown];
  [self handleEvent:uppercaseUp type:kCGEventKeyUp];
  NSCAssert(self.prefixEvents.count == 7 && self.pendingEvents.count == 6 &&
      CGEventGetIntegerValueField((__bridge CGEventRef)self.pendingEvents[0],
          kCGKeyboardEventAutorepeat) == 1 &&
      [[NSEvent eventWithCGEvent:(__bridge CGEventRef)self.pendingEvents[2]]
          .characters isEqualToString:@"u"] &&
      [[NSEvent eventWithCGEvent:(__bridge CGEventRef)self.pendingEvents[4]]
          .characters isEqualToString:@"U"] &&
      (CGEventGetFlags((__bridge CGEventRef)self.pendingEvents[4]) & kCGEventFlagMaskShift),
      @"subsequent u/U and paired releases must be buffered unchanged, not stripped");
  [self passPrefixThrough];
  NSCAssert(self.passedEvents.count == 7,
      @"ordinary-input fallback must preserve the prefix and every later u/U");

  [self handleEvent:triggerDown type:kCGEventKeyDown];
  STInputBarTestClient *probeClient = [[STInputBarTestClient alloc]
      initWithFrame:NSMakeRect(0, 0, 1, 24)];
  probeClient.owner = self;
  self.textView = probeClient;
  _drainQueued = YES;
  [self dispatchReadyInput];
  NSCAssert(!_prefixProbe && !_opening &&
      self.prefixEvents.count == 0 && self.pendingEvents.count == 0 &&
      probeClient.owner == self && self.textView == probeClient &&
      [probeClient.string isEqualToString:@"u"] && probeClient.deliveredEvents == 1 &&
      self.installedClients == 0,
      @"a lone u must retain its native composition and client without clearing the panel");
  [self dispatchReadyInput];
  NSCAssert(!_opening && probeClient.owner == self &&
      [probeClient.string isEqualToString:@"u"] && self.installedClients == 0,
      @"waiting without pinyin must neither clear nor replace the prefix client");
  [self queueEvent:first];
  NSCAssert(CGEventGetIntegerValueField((__bridge CGEventRef)self.pendingEvents[0],
      kCGKeyboardEventKeycode) == kVK_ANSI_N,
      @"the first query key must be retained without replacing the native client");
  [self queueEvent:triggerDown];
  [self queueEvent:triggerUp];
  [self queueEvent:uppercaseU];
  [self queueEvent:uppercaseUp];
  NSCAssert(!_prefixProbe && self.prefixEvents.count == 0 &&
      self.pendingEvents.count == 5 &&
      [[NSEvent eventWithCGEvent:(__bridge CGEventRef)self.pendingEvents[1]]
          .characters isEqualToString:@"u"] &&
      [[NSEvent eventWithCGEvent:(__bridge CGEventRef)self.pendingEvents[3]]
          .characters isEqualToString:@"U"],
      @"after prefix acceptance subsequent u/U must remain ordinary query events");
  [self dispatchReadyInput];
  NSCAssert(!_opening && !_dismissRequested && probeClient.owner == self &&
      self.installedClients == 0 && self.textView == probeClient &&
      probeClient.deliveredEvents == 6 && [probeClient.firstCharacters isEqualToString:@"u"] &&
      [probeClient.string isEqualToString:@"U"] && self.pendingEvents.count == 0,
      @"native u and all query keys must stay in one client with no cancellation keys or lifecycle reset");
  probeClient.owner = nil;
  [self passPrefixThrough];
  STTextView *queryClient = [[STTextView alloc] initWithFrame:NSMakeRect(0, 0, 1, 24)];
  queryClient.owner = self;
  self.textView = queryClient;
  _opening = NO;
  [queryClient setMarkedText:@"n" selectedRange:NSMakeRange(1, 0)
      replacementRange:NSMakeRange(NSNotFound, 0)];
  NSCAssert([queryClient.string isEqualToString:@"n"],
      @"retain the first real pinyin response without clearing or restarting it");
  NSUInteger closedGeneration = _generation;
  [super commitText:@"u"];
  [self requestDismiss];
  NSCAssert(_generation == closedGeneration && !self.submittedText,
      @"late callbacks from a closed client must not invalidate fallback or the next query");
  _opening = _drainQueued = _triggerHeld = NO;
  [self.pendingEvents removeAllObjects];
  [self.capturedKeys removeAllObjects];
  probeClient.owner = nil;
  [self handleEvent:triggerDown type:kCGEventKeyDown];
  NSUInteger retryGeneration = _generation;
  [probeClient insertText:@"u" replacementRange:NSMakeRange(NSNotFound, 0)];
  NSCAssert(_prefixProbe && _opening && _generation == retryGeneration,
      @"a detached previous client must not close a repeated prefix invocation");
  [self passPrefixThrough];

  _hostWordInProgress = NO;
  self.testSecureInput = YES;
  NSCAssert([self handleEvent:triggerDown type:kCGEventKeyDown] == triggerDown && !_opening,
      @"secure input must always stay in the original application");
  self.testSecureInput = NO;
  CGEventSetFlags(triggerDown, kCGEventFlagMaskControl);
  NSCAssert([self handleEvent:triggerDown type:kCGEventKeyDown] == triggerDown,
      @"Control+u must remain an application shortcut");
  CGEventSetFlags(triggerDown, kCGEventFlagMaskShift);
  NSCAssert([self handleEvent:triggerDown type:kCGEventKeyDown] == triggerDown,
      @"Shift+u must remain ordinary input");
  CGEventSetFlags(triggerDown, 0);
  CGEventRef ordinary = STTestKey(kVK_ANSI_G, 'g', YES);
  NSCAssert([self handleEvent:ordinary type:kCGEventKeyDown] == ordinary && !_opening,
      @"other letters must not open a session");
  NSCAssert([self handleEvent:triggerDown type:kCGEventKeyDown] == triggerDown,
      @"do not split letters already passed to the host");
  CGEventRef letterL = STTestKey(kVK_ANSI_L, 'l', YES);
  NSCAssert([self handleEvent:letterL type:kCGEventKeyDown] == letterL,
      @"ordinary l must stay in the original application");
  [NSThread sleepForTimeInterval:0.35];
  NSCAssert([self handleEvent:triggerDown type:kCGEventKeyDown] == triggerDown &&
      !_opening && _hostWordInProgress,
      @"a pause longer than 300ms must not intercept the u following l");
  CGEventRef shiftChange = STTestKey(kVK_Shift, 0, YES);
  CGEventSetType(shiftChange, kCGEventFlagsChanged);
  CGEventSetFlags(shiftChange, kCGEventFlagMaskShift);
  NSEvent *localShift = STLocalInputEvent([NSEvent eventWithCGEvent:shiftChange]);
  NSCAssert(localShift.type == NSEventTypeFlagsChanged && STIsLocalInputEvent(localShift) &&
      localShift.keyCode == kVK_Shift && (localShift.modifierFlags & NSEventModifierFlagShift) &&
      !STIsLetter(localShift),
      @"modifier events must preserve native backing and their flags");
  NSCAssert([self handleEvent:shiftChange type:kCGEventFlagsChanged] == shiftChange &&
      [self handleEvent:uppercaseU type:kCGEventKeyDown] == uppercaseU &&
      [self handleEvent:triggerDown type:kCGEventKeyDown] == triggerDown && !_opening,
      @"Shift must not rearm the prefix inside ordinary input");
  [self.capturedKeys addObject:@(kVK_ANSI_N)];
  NSCAssert([self handleEvent:firstUp type:kCGEventKeyUp] == NULL,
      @"consume a captured release even after the query closes");
  CGEventRef escape = STTestKey(kVK_Escape, 0x1b, YES);
  NSCAssert([self handleEvent:escape type:kCGEventKeyDown] == escape &&
      [self handleEvent:triggerDown type:kCGEventKeyDown] == NULL,
      @"a new prefix after Escape must not be rejected as part of the previous word");
  [self passPrefixThrough];

  STTextView *client = [[STTextView alloc] initWithFrame:NSMakeRect(0, 0, 1, 24)];
  client.owner = self;
  NSTextInputContext *(*viewContext)(id, SEL) =
      (NSTextInputContext *(*)(id, SEL))[NSView instanceMethodForSelector:@selector(inputContext)];
  NSCAssert(client.inputContext == viewContext(client, @selector(inputContext)) &&
      client.inputContext.client == client,
      @"use the one input context owned by AppKit, not a second manually created context");
  [client setMarkedText:@"nihao" selectedRange:NSMakeRange(5, 0)
      replacementRange:NSMakeRange(NSNotFound, 0)];
  NSCAssert(client.hasMarkedText && client.markedRange.length == 5,
      @"the transparent client must retain real composition");
  NSInteger clipboardVersion = NSPasteboard.generalPasteboard.changeCount;
  [client insertText:[[NSAttributedString alloc] initWithString:@"你好"]
      replacementRange:NSMakeRange(NSNotFound, 0)];
  NSCAssert([self.submittedText isEqualToString:@"你好"] && !client.hasMarkedText &&
      NSPasteboard.generalPasteboard.changeCount == clipboardVersion,
      @"candidate commits must be forwarded, never discarded or copied");
  CFRelease(triggerDown); CFRelease(triggerUp); CFRelease(first);
  CFRelease(second); CFRelease(firstUp); CFRelease(ordinary); CFRelease(escape);
  CFRelease(repeatedU); CFRelease(uppercaseU); CFRelease(uppercaseUp);
  CFRelease(letterL); CFRelease(shiftChange);
  puts("PASS: native-backed keyboard/modifier events, single AppKit-owned input context, native-field u passthrough, non-editing u trigger, retained lone-u composition, same-client query delivery without cancellation, ordinary lu preserved after pauses and Shift, preserved subsequent u/U and autorepeat, retained pinyin, ordered plain-input replay, late-callback and repeated-query guards, secure-input and shortcut guards, paired releases, forwarded commits, clipboard unchanged");
}
@end

@interface STInputBarPreview : STInputBar
@end
@implementation STInputBarPreview
- (void)windowDidResignKey:(NSNotification *)notification { (void)notification; }
- (void)commitText:(NSString *)text {
  if (STTraceDiagnostics) fprintf(stderr, "preview: commit_nonempty=%d forwarded=0\n", text.length > 0);
  [self dismiss]; // Never write a UI test's text into an unrelated application.
}
- (void)postEvents:(NSArray *)events toPID:(pid_t)pid {
  (void)pid;
  if (STTraceDiagnostics) fprintf(stderr, "preview: replay_count=%lu forwarded=0\n", (unsigned long)events.count);
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  [self preparePanel];
  self.previousApp = NSWorkspace.sharedWorkspace.frontmostApplication;
  self.requestedSourceID = STInputSourceID();
  [self showPanel];
}
@end

// Ask the real service: a CLI child can inherit Codex/Terminal's TCC trust and
// must never use its own AXIsProcessTrusted result as evidence for launchd.
// Read-only diagnostics contain no text, AX values, URLs or clipboard data.
static int STDiagnose(BOOL verbose) {
  NSRunningApplication *service = nil;
  for (NSRunningApplication *app in [NSRunningApplication
      runningApplicationsWithBundleIdentifier:@"org.owllinker.SquirrelTranslate.InputBar"]) {
    if (app.processIdentifier != getpid()) { service = app; break; }
  }
  if (!service) { puts("service=not_running"); return 4; }
  NSString *token = NSUUID.UUID.UUIDString;
  __block NSDictionary *health = nil;
  NSDistributedNotificationCenter *center = NSDistributedNotificationCenter.defaultCenter;
  id observer = [center addObserverForName:STHealthResponse object:token queue:nil
      usingBlock:^(NSNotification *notification) {
    if ([notification.userInfo[@"pid"] intValue] == service.processIdentifier)
      health = notification.userInfo;
  }];
  [center postNotificationName:STHealthRequest object:token
      userInfo:@{@"pid": @(service.processIdentifier)} deliverImmediately:YES];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
  while (!health && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:deadline];
  [center removeObserver:observer];
  if (!health) { puts("service=unresponsive"); return 4; }
  BOOL trusted = [health[@"accessibility"] boolValue];
  BOOL ready = [health[@"event_tap"] boolValue];
  printf("service_pid=%d\naccessibility=%s\nevent_tap=%s\ninput_source=%s\nsecure_input=%s\n",
      service.processIdentifier, trusted ? "granted" : "required",
      ready ? "ready" : "unavailable", [health[@"input_source"] UTF8String],
      [health[@"secure_input"] boolValue] ? "yes" : "no");
  if (verbose)
    printf("startup_policy=current_ime_response\nfocus_gate=native_or_unknown_passthrough\nmode_gate=disabled\n"
           "client_visible=%d\nclient_key=%d\nime_marked=%d\nopening=%d\n",
        [health[@"client_visible"] boolValue], [health[@"client_key"] boolValue],
        [health[@"ime_marked"] boolValue], [health[@"opening"] boolValue]);
  return trusted && ready ? 0 : 3;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc == 2 && strcmp(argv[1], "--diagnose") == 0) return STDiagnose(YES);
    if (argc == 2 && strcmp(argv[1], "--check") == 0) return STDiagnose(NO);
    [NSApplication sharedApplication];
    if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
      [[STInputBarTest new] runTests];
      return 0;
    }
    STBufferedPreview = argc == 2 && strcmp(argv[1], "--preview-buffered") == 0;
    BOOL preview = STBufferedPreview || (argc == 2 && strcmp(argv[1], "--preview") == 0);
    STPreviewDiagnostics = preview;
    STTraceDiagnostics = STBufferedPreview || (argc == 2 && strcmp(argv[1], "--trace") == 0);
    STInputBar *delegate = preview ? [STInputBarPreview new] : [STInputBar new];
    NSApp.delegate = delegate;
    [NSApp run];
  }
  return 0;
}
