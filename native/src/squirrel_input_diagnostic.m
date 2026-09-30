#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <InputMethodKit/InputMethodKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <rime_api_stdbool.h>
#include <rime_api.h>

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

typedef BOOL (*InputHandleFunction)(id, SEL, NSEvent *, id);

static InputHandleFunction original_handle = NULL;
static double last_keydown_seconds = 0.0;
static double trace_until_seconds = 0.0;
static unsigned int trace_events_remaining = 0;
static uint64_t event_sequence = 0;

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

static double monotonic_seconds(void) {
  struct timespec value = {};
  if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0.0;
  return (double)value.tv_sec + (double)value.tv_nsec / 1e9;
}

static void append_trace(const char *line) {
  FILE *file = fopen("/tmp/squirrel-input-diagnostic.log", "a");
  if (!file) return;
  fputs(line, file);
  fputc('\n', file);
  fclose(file);
}

static NSInteger marked_text_length(id sender) {
  SEL selector = sel_registerName("markedRange");
  if (!sender || ![sender respondsToSelector:selector]) return -1;
  NSRange (*send_range)(id, SEL) = (NSRange (*)(id, SEL))objc_msgSend;
  NSRange range = send_range(sender, selector);
  return range.location == NSNotFound ? 0 : (NSInteger)range.length;
}

static BOOL read_rime_state(id controller, size_t *input_length,
                            int *ascii_mode) {
  Ivar session_ivar =
      class_getInstanceVariable(object_getClass(controller), "session");
  RimeApi_stdbool *api = rime_get_api_stdbool();
  if (!session_ivar || !api || !api->get_input || !api->get_option) return NO;

  void *instance = (__bridge void *)controller;
  RimeSessionId session =
      *(RimeSessionId *)((uint8_t *)instance + ivar_getOffset(session_ivar));
  if (session == 0) return NO;

  const char *input = api->get_input(session);
  *input_length = input ? strlen(input) : 0;
  *ascii_mode = api->get_option(session, "ascii_mode") ? 1 : 0;
  return YES;
}

static unsigned int modifier_summary(NSEventModifierFlags flags) {
  unsigned int result = 0;
  if (flags & NSEventModifierFlagShift) result |= 1U;
  if (flags & NSEventModifierFlagControl) result |= 2U;
  if (flags & NSEventModifierFlagOption) result |= 4U;
  if (flags & NSEventModifierFlagCommand) result |= 8U;
  if (flags & NSEventModifierFlagCapsLock) result |= 16U;
  return result;
}

static BOOL is_ascii_letter(NSString *value) {
  if (value.length == 0) return NO;
  const unichar first = [value characterAtIndex:0];
  return (first >= 'A' && first <= 'Z') || (first >= 'a' && first <= 'z');
}

static const char *character_class(NSString *value) {
  if (value.length == 0) return "empty";
  if (value.length > 1) return "multi";
  const unichar character = [value characterAtIndex:0];
  if ((character >= 'A' && character <= 'Z') ||
      (character >= 'a' && character <= 'z')) return "letter";
  if (character >= '0' && character <= '9') return "digit";
  if (character <= 0x7f) {
    if ([[NSCharacterSet whitespaceAndNewlineCharacterSet]
            characterIsMember:character]) return "space";
    if ([[NSCharacterSet punctuationCharacterSet]
            characterIsMember:character]) return "punct";
    if ([[NSCharacterSet controlCharacterSet]
            characterIsMember:character]) return "control";
    return "ascii_other";
  }
  if ([[NSCharacterSet letterCharacterSet] characterIsMember:character])
    return "unicode_letter";
  return "unicode_other";
}

static BOOL is_physical_letter_keycode(unsigned short keycode) {
  static const unsigned short letter_keycodes[] = {
      kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E,
      kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
      kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O,
      kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
      kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y,
      kVK_ANSI_Z};
  for (size_t index = 0;
       index < sizeof(letter_keycodes) / sizeof(letter_keycodes[0]); ++index) {
    if (letter_keycodes[index] == keycode) return YES;
  }
  return NO;
}

static const char *key_class(unsigned short keycode) {
  if (is_physical_letter_keycode(keycode)) return "letter";
  switch (keycode) {
    case kVK_Escape: return "escape";
    case kVK_Delete: return "backspace";
    case kVK_ForwardDelete: return "forward_delete";
    case kVK_Return:
    case kVK_ANSI_KeypadEnter: return "return";
    case kVK_Space: return "space";
    case kVK_Tab: return "tab";
    case kVK_UpArrow:
    case kVK_DownArrow:
    case kVK_LeftArrow:
    case kVK_RightArrow: return "arrow";
    case kVK_Shift:
    case kVK_RightShift:
    case kVK_Control:
    case kVK_RightControl:
    case kVK_Option:
    case kVK_RightOption:
    case kVK_Command:
    case kVK_RightCommand: return "modifier";
    default: return "other";
  }
}

static BOOL diagnostic_handle(id self, SEL selector, NSEvent *event,
                             id sender) {
  const double now = monotonic_seconds();
  BOOL trace = NO;
  BOOL starts_burst = NO;
  double idle_ms = -1.0;
  uint64_t sequence = 0;

  @synchronized([NSProcessInfo processInfo]) {
    if (event && event.type == NSEventTypeKeyDown) {
      if (last_keydown_seconds > 0.0) {
        idle_ms = (now - last_keydown_seconds) * 1000.0;
      }
      if ((last_keydown_seconds == 0.0 || idle_ms >= 500.0) &&
          now > trace_until_seconds) {
        // Leave enough bounded time to capture a full repeated-input attempt
        // after idle, while keeping the diagnostic short and low overhead.
        trace_until_seconds = now + 8.0;
        trace_events_remaining = 24;
        starts_burst = YES;
      }
      last_keydown_seconds = now;
      trace = now <= trace_until_seconds && trace_events_remaining > 0;
      if (trace) {
        --trace_events_remaining;
        sequence = ++event_sequence;
      }
    }
  }

  NSString *characters = event.charactersIgnoringModifiers;
  const BOOL has_characters = characters.length > 0;
  NSString *event_characters = event.characters;
  const BOOL ignoring_is_letter = is_ascii_letter(characters);
  const BOOL event_is_letter = is_ascii_letter(event_characters);
  const BOOL physical_letter = is_physical_letter_keycode(event.keyCode);
  size_t input_length_before = 0;
  int ascii_mode_before = -1;
  const BOOL has_rime_state_before =
      read_rime_state(self, &input_length_before, &ascii_mode_before);
  const BOOL handled = original_handle
                           ? original_handle(self, selector, event, sender)
                           : NO;

  if (trace) {
    if (starts_burst) {
      const char *log_path = "/tmp/squirrel-input-diagnostic.log";
      struct stat log_status = {};
      const char *mode =
          stat(log_path, &log_status) == 0 && log_status.st_size > 65536
              ? "w"
              : "a";
      FILE *file = fopen(log_path, mode);
      if (file) {
        fprintf(file, "new_idle_burst seq=%" PRIu64 "\n", sequence);
        fclose(file);
      }
    }
    size_t input_length_after = 0;
    int ascii_mode_after = -1;
    const BOOL has_rime_state_after =
        read_rime_state(self, &input_length_after, &ascii_mode_after);
    const NSInteger marked_length = marked_text_length(sender);
    char line[256];
    snprintf(line, sizeof(line),
             "seq=%" PRIu64
             " idle_ms=%.1f chars=%d ignore_class=%s event_class=%s"
             " key_class=%s mods=%u handled=%d marked_len=%ld"
             " rime=%d input_bytes=%zu->%zu ascii=%d->%d",
             sequence, idle_ms, has_characters ? 1 : 0,
             character_class(characters), character_class(event_characters),
             key_class(event.keyCode), modifier_summary(event.modifierFlags),
             handled ? 1 : 0,
             (long)marked_length,
             has_rime_state_before && has_rime_state_after ? 1 : 0,
             input_length_before, input_length_after, ascii_mode_before,
             ascii_mode_after);
    append_trace(line);
  }
  return handled;
}

__attribute__((constructor)) static void install_input_diagnostic(void) {
  @autoreleasepool {
    Class controller = find_controller_class();
    if (!controller) {
      append_trace("hook_error=SquirrelInputController class not found");
      return;
    }
    // The Swift override is exported by Objective-C as handleEvent:client:.
    SEL selector = sel_registerName("handleEvent:client:");
    Method method = class_getInstanceMethod(controller, selector);
    if (!method) {
      char line[256];
      snprintf(line, sizeof(line), "hook_error=selector missing on %s",
               class_getName(controller));
      append_trace(line);
      return;
    }

    original_handle = (InputHandleFunction)method_getImplementation(method);
    method_setImplementation(method, (IMP)diagnostic_handle);
    append_trace("hook_installed; logs contain no key text or key codes");
  }
}
