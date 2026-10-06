#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <dispatch/dispatch.h>
#import <InputMethodKit/InputMethodKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <rime_api_stdbool.h>
#include <rime_api.h>

#include <stdint.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef BOOL (*InputHandleFunction)(id, SEL, NSEvent *, id);
typedef void (*InputDeactivateFunction)(id, SEL, id);

static InputHandleFunction original_handle = NULL;
static InputDeactivateFunction original_deactivate = NULL;
static Ivar session_ivar = NULL;
static BOOL trace_enabled = NO;
static NSUInteger install_attempts = 0;

static void trace_escape(const char *line) {
  if (!trace_enabled) return;
  const char *path = "/tmp/squirrel-escape-guard.log";
  struct stat status = {};
  const char *mode = stat(path, &status) == 0 && status.st_size > 16384
                         ? "w"
                         : "a";
  FILE *file = fopen(path, mode);
  if (!file) return;
  fputs(line, file);
  fputc('\n', file);
  fclose(file);
}

static Class find_controller_class(void) {
  const char *suffix = "SquirrelInputController";
  int count = objc_getClassList(NULL, 0);
  if (count <= 0) return Nil;

  Class *classes = (__unsafe_unretained Class *)calloc((size_t)count,
                                                        sizeof(Class));
  if (!classes) return Nil;
  count = objc_getClassList(classes, count);
  Class result = Nil;
  const size_t suffix_length = strlen(suffix);
  for (int index = 0; index < count; ++index) {
    const char *name = class_getName(classes[index]);
    if (name && strlen(name) >= suffix_length &&
        strcmp(name + strlen(name) - suffix_length, suffix) == 0) {
      result = classes[index];
      break;
    }
  }
  free(classes);
  return result;
}

static RimeSessionId session_for_controller(id controller) {
  if (!controller || !session_ivar) return 0;
  void *instance = (__bridge void *)controller;
  return *(RimeSessionId *)((uint8_t *)instance + ivar_getOffset(session_ivar));
}

static BOOL rime_input_length(RimeSessionId session, size_t *length) {
  if (!session || !length) return NO;
  RimeApi_stdbool *api = rime_get_api_stdbool();
  if (!api || !api->get_input) return NO;
  const char *input = api->get_input(session);
  *length = input ? strlen(input) : 0;
  return YES;
}

static size_t safe_input_length(RimeSessionId session, BOOL *available) {
  size_t length = 0;
  *available = rime_input_length(session, &length);
  return length;
}

static BOOL rime_has_candidate_menu(RimeSessionId session, BOOL *available) {
  *available = NO;
  if (!session) return NO;
  RimeApi_stdbool *api = rime_get_api_stdbool();
  if (!api || !api->get_context || !api->free_context) return NO;
  RimeContext_stdbool context = {};
  RIME_STRUCT_INIT(RimeContext_stdbool, context);
  if (!api->get_context(session, &context)) return NO;
  *available = YES;
  const BOOL visible = context.menu.num_candidates > 0;
  api->free_context(&context);
  return visible;
}

static void install_escape_guard(void);

static void set_composition_visible(BOOL visible) {
  NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:
      @"Library/Rime"];
  [[NSFileManager defaultManager] createDirectoryAtPath:directory
      withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *path = [directory stringByAppendingPathComponent:
      @"input_translation.composition.state"];
  NSString *value = visible ? @"1\n" : @"0\n";
  if ([value writeToFile:path atomically:YES encoding:NSUTF8StringEncoding
                   error:nil])
    chmod(path.fileSystemRepresentation, 0600);
}

static void escape_guard_deactivate(id self, SEL selector, id sender) {
  set_composition_visible(NO);
  original_deactivate(self, selector, sender);
}

static void retry_install(void) {
  if (++install_attempts >= 40) {
    trace_escape("hook=not_installed reason=retry_limit");
    return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
                   install_escape_guard();
                 });
}

static BOOL escape_guard_handle(id self, SEL selector, NSEvent *event,
                                id sender) {
  const BOOL is_plain_escape =
      event && event.type == NSEventTypeKeyDown &&
      event.keyCode == kVK_Escape &&
      (event.modifierFlags & (NSEventModifierFlagShift |
                              NSEventModifierFlagControl |
                              NSEventModifierFlagOption |
                              NSEventModifierFlagCommand)) == 0;

  const RimeSessionId session = session_for_controller(self);
  BOOL candidate_state_available = NO;
  const BOOL candidate_panel_was_visible = is_plain_escape
      ? rime_has_candidate_menu(session, &candidate_state_available)
      : NO;
  BOOL input_before_available = NO;
  const size_t input_before = is_plain_escape
                                  ? safe_input_length(session,
                                                      &input_before_available)
                                  : 0;
  const BOOL handled = original_handle
                           ? original_handle(self, selector, event, sender)
                           : NO;
  BOOL input_after_available = NO;
  const size_t input_after = is_plain_escape
                                 ? safe_input_length(session,
                                                     &input_after_available)
                                 : 0;

  // Rime can clear an active composition while reporting Escape as unhandled.
  // Consume only that exact transition, so the synthetic Escape forwarded by
  // Hammerspoon cannot leak to the foreground app; ordinary Escape behavior is
  // unchanged when there was no Rime input to cancel.
  // A visible candidate menu owns plain Escape even if Rime reports it as
  // unhandled. With no visible candidates, leave Escape to the active app.
  const BOOL force_consume = is_plain_escape && !handled &&
      candidate_state_available && candidate_panel_was_visible;
  if (is_plain_escape) {
    char line[160];
    snprintf(line, sizeof(line),
             "escape api=%d/%d input_bytes=%zu->%zu original=%d forced=%d",
             input_before_available ? 1 : 0, input_after_available ? 1 : 0,
             input_before, input_after, handled ? 1 : 0,
             force_consume ? 1 : 0);
    trace_escape(line);
  }
  if (force_consume) {
    return YES;
  }
  return handled;
}

static void install_escape_guard(void) {
  @autoreleasepool {
    Class controller = find_controller_class();
    if (!controller) {
      retry_install();
      return;
    }

    SEL selector = sel_registerName("handleEvent:client:");
    Method method = class_getInstanceMethod(controller, selector);
    if (!method) {
      retry_install();
      return;
    }

    session_ivar = class_getInstanceVariable(controller, "session");
    if (!session_ivar) {
      session_ivar = class_getInstanceVariable(object_getClass(controller),
                                               "session");
    }
    if (!session_ivar) {
      retry_install();
      return;
    }

    if (!original_handle) {
      original_handle = (InputHandleFunction)method_getImplementation(method);
      method_setImplementation(method, (IMP)escape_guard_handle);
      trace_escape("hook=handle_installed");
    }

    SEL deactivate_selector = sel_registerName("deactivateServer:");
    Method deactivate_method = class_getInstanceMethod(controller, deactivate_selector);
    if (deactivate_method && !original_deactivate) {
      original_deactivate = (InputDeactivateFunction)method_getImplementation(deactivate_method);
      method_setImplementation(deactivate_method, (IMP)escape_guard_deactivate);
      trace_escape("hook=deactivate_installed");
    }
  }
}

__attribute__((constructor)) static void initialize_escape_guard(void) {
  const char *home = getenv("HOME");
  if (home) {
    char marker[PATH_MAX];
    snprintf(marker, sizeof(marker),
             "%s/Library/Rime/input_translation.escape_guard.trace", home);
    trace_enabled = access(marker, F_OK) == 0;
  }
  install_escape_guard();
}
