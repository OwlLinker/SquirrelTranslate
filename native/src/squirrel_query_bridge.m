#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>

#include <rime_api_stdbool.h>
#include <rime_api.h>
#include "query_translation_service.h"

#include <dispatch/dispatch.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <math.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// This bridge is deliberately self-contained. It runs inside Squirrel, uses
// the already initialized Rime API, and owns only a small non-activating panel.
// It does not replace Squirrel's IMK controller or touch Hammerspoon.

static RimeApi_stdbool *query_api;
static RimeSessionId query_session;
static CFMachPortRef query_tap;
static CFRunLoopSourceRef query_tap_source;
static NSPanel *query_panel;
static dispatch_source_t query_refresh_source;
static dispatch_source_t query_permission_watchdog;
static BOOL query_active;
static BOOL query_installed;
static BOOL query_bridge_disarmed;
static BOOL query_escape_keyup_pending;
static BOOL query_copy_keyup_pending;
static BOOL query_space_keyup_pending;
static BOOL query_paste_keyup_pending;
static BOOL query_help_keyup_pending;
static uint64_t query_number_keyup_pending;
static BOOL query_help_visible;
static NSInteger query_help_page;
static NSInteger query_help_page_count = 1;
static BOOL query_panel_position_pinned;
static NSPoint query_panel_pinned_top_left;
static CGKeyCode query_search_keyup_pending;
static NSMutableString *query_text;
static NSDate *query_time_snapshot;
static struct timespec query_cache_mtime;
static off_t query_cache_size = -1;
static CFAbsoluteTime query_last_key_time;
static BOOL query_prefix_armed = YES;
static NSString *query_ip_details;
static NSString *query_ip_public_ip;
static NSURLSessionDataTask *query_ip_task;
static NSUInteger query_utility_generation;
static NSData *query_phone_data;
static NSInteger query_utility_highlighted;
static NSString *query_search_feedback;
static NSMutableDictionary<NSString *, NSString *> *query_public_translations;
static NSMutableArray<NSString *> *query_public_translation_order;
static NSColorSampler *query_color_sampler;
static NSColor *query_color_sample;
static CGPoint query_color_cursor_position;
static BOOL query_color_cursor_position_valid;
static BOOL query_color_sampling_active;
static BOOL query_color_sampler_started;
static BOOL query_color_confirmation_pending;
static BOOL query_color_cancel_pending;
static NSUInteger query_color_session_generation;
static NSUInteger query_color_confirmation_generation;
static const int64_t kQueryColorSyntheticClickMarker = 0x5351434C;
static AXError query_last_focus_error = kAXErrorSuccess;
static void ShowQueryContext(void);

static void AdvanceQueryGeneration(void) {
  ++query_utility_generation;
  SquirrelQueryTranslationSetGeneration((uint64_t)query_utility_generation);
}

static NSString *QueryTranslationKey(NSString *target, NSString *word) {
  return [NSString stringWithFormat:@"%@\x1f%@", target, word];
}

static NSString *QueryTargetForCandidate(NSString *candidate) {
  static NSCharacterSet *asciiLetters;
  static NSCharacterSet *englishCharacters;
  static NSCharacterSet *nonEnglishCharacters;
  static NSCharacterSet *cjkCharacters;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    asciiLetters = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"];
    englishCharacters = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 '-."];
    nonEnglishCharacters = [englishCharacters invertedSet];
    cjkCharacters = [NSCharacterSet characterSetWithRange:
        NSMakeRange(0x4E00, 0xA000 - 0x4E00)];
  });
  BOOL hasASCII = [candidate rangeOfCharacterFromSet:asciiLetters].location !=
      NSNotFound;
  if (hasASCII && [candidate rangeOfCharacterFromSet:nonEnglishCharacters].location ==
                      NSNotFound)
    return @"zh-CN";
  return [candidate rangeOfCharacterFromSet:cjkCharacters].location != NSNotFound ?
      @"en" : nil;
}

static void QueryTranslationDidFinish(uint64_t generation, const char *word,
                                     const char *target,
                                     const char *translation,
                                     const char *phonetic, void *context) {
  (void)context;
  if (!word || !target || !translation || !translation[0]) return;
  NSString *wordValue = [NSString stringWithUTF8String:word];
  NSString *targetValue = [NSString stringWithUTF8String:target];
  NSMutableString *result = [NSMutableString stringWithUTF8String:translation];
  NSString *phoneticValue = phonetic && phonetic[0] ?
      [NSString stringWithUTF8String:phonetic] : nil;
  if (phoneticValue.length) [result appendFormat:@"  /%@/", phoneticValue];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!query_active || generation != query_utility_generation) return;
    if (!query_public_translations) {
      query_public_translations = [NSMutableDictionary dictionary];
      query_public_translation_order = [NSMutableArray array];
    }
    NSString *key = QueryTranslationKey(targetValue, wordValue);
    if (!query_public_translations[key])
      [query_public_translation_order addObject:key];
    query_public_translations[key] = result;
    while (query_public_translation_order.count > 400) {
      NSString *oldest = query_public_translation_order.firstObject;
      [query_public_translation_order removeObjectAtIndex:0];
      [query_public_translations removeObjectForKey:oldest];
    }
    ShowQueryContext();
  });
}

static void SetQueryBridgeStatus(NSString *state) {
  NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:
      @"Library/Rime"];
  [[NSFileManager defaultManager] createDirectoryAtPath:directory
      withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *path = [directory stringByAppendingPathComponent:
      @"input_translation.query_bridge.status"];
  NSString *contents = [NSString stringWithFormat:@"%@\n", state ?: @"unknown"];
  if ([contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding
                      error:nil])
    chmod(path.fileSystemRepresentation, 0600);
}

static NSString *QuerySearchProfilePath(void) {
  return [@"~/Library/Rime/input_translation.search-engines"
      stringByExpandingTildeInPath];
}

static NSString *QuerySearchEngineURL(NSString *name) {
  static NSDictionary<NSString *, NSString *> *engines;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    engines = @{
      @"google": @"https://www.google.com/search?q={query}",
      @"bing": @"https://www.bing.com/search?q={query}",
      @"baidu": @"https://www.baidu.com/s?wd={query}",
      @"duckduckgo": @"https://duckduckgo.com/?q={query}",
      @"yahoo": @"https://search.yahoo.com/search?p={query}",
      @"brave": @"https://search.brave.com/search?q={query}",
      @"sogou": @"https://www.sogou.com/web?query={query}",
      @"yandex": @"https://yandex.com/search/?text={query}"
    };
  });
  return engines[name.lowercaseString];
}

static NSString *CurrentSearchEngineURL(BOOL secondary) {
  NSString *slot = secondary ? @"secondary" : @"default";
  NSString *profile = [NSString stringWithContentsOfFile:QuerySearchProfilePath()
      encoding:NSUTF8StringEncoding error:nil] ?: @"";
  for (NSString *line in [profile componentsSeparatedByCharactersInSet:
                          NSCharacterSet.newlineCharacterSet]) {
    NSString *prefix = [slot stringByAppendingString:@"="];
    if ([line hasPrefix:prefix]) {
      NSString *value = [line substringFromIndex:prefix.length];
      if ([value hasPrefix:@"https://"] || [value hasPrefix:@"http://"])
        return value;
    }
  }
  char propertyValue[2048] = {0};
  const char *property = secondary ?
      "_translation_search_secondary_url" : "_translation_search_default_url";
  NSString *configured = query_api && query_session && query_api->get_property &&
      query_api->get_property(query_session, property, propertyValue,
                              sizeof(propertyValue)) ?
      [NSString stringWithUTF8String:propertyValue] : nil;
  if (([configured hasPrefix:@"https://"] || [configured hasPrefix:@"http://"]) &&
      [configured containsString:@"{query}"])
    return configured;
  return secondary ? @"https://www.bing.com/search?q={query}" :
      @"https://www.google.com/search?q={query}";
}

static NSString *SearchEngineDisplayName(BOOL secondary) {
  NSString *url = CurrentSearchEngineURL(secondary);
  NSString *host = [[NSURLComponents componentsWithString:url].host lowercaseString];
  NSDictionary<NSString *, NSString *> *known = @{
    @"google.com": @"Google", @"bing.com": @"Bing",
    @"baidu.com": @"百度", @"duckduckgo.com": @"DuckDuckGo",
    @"yahoo.com": @"Yahoo", @"brave.com": @"Brave",
    @"sogou.com": @"搜狗", @"yandex.com": @"Yandex",
    @"yandex.ru": @"Yandex"
  };
  for (NSString *domain in known) {
    if ([host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]])
      return known[domain];
  }
  if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
  NSString *firstLabel = [[host componentsSeparatedByString:@"."] firstObject];
  return firstLabel.length ? firstLabel.capitalizedString :
      (secondary ? @"Bing" : @"Google");
}

static NSString *ConfigureQuerySearchEngine(NSString *command) {
  if (command.length < 2) return nil;
  unichar slotCharacter = [command characterAtIndex:command.length - 1];
  if (slotCharacter != '1' && slotCharacter != '2') return nil;
  NSString *engineName = [command substringToIndex:command.length - 1];
  NSString *engineURL = QuerySearchEngineURL(engineName);
  if (!engineURL) return nil;

  NSString *path = QuerySearchProfilePath();
  NSString *existing = [NSString stringWithContentsOfFile:path
      encoding:NSUTF8StringEncoding error:nil] ?: @"";
  NSMutableDictionary<NSString *, NSString *> *profile = [NSMutableDictionary dictionary];
  for (NSString *line in [existing componentsSeparatedByCharactersInSet:
                          NSCharacterSet.newlineCharacterSet]) {
    NSRange separator = [line rangeOfString:@"="];
    if (separator.location == NSNotFound) continue;
    NSString *key = [line substringToIndex:separator.location];
    NSString *value = [line substringFromIndex:separator.location + 1];
    if (([key isEqualToString:@"default"] || [key isEqualToString:@"secondary"]) &&
        value.length) profile[key] = value;
  }
  NSString *slot = slotCharacter == '1' ? @"default" : @"secondary";
  profile[slot] = engineURL;

  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  for (NSString *key in @[@"default", @"secondary"]) {
    NSString *value = profile[key];
    if (value) [lines addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
  }
  NSError *error = nil;
  NSString *contents = [lines componentsJoinedByString:@"\n"];
  if (lines.count) contents = [contents stringByAppendingString:@"\n"];
  if (![contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding
                       error:&error]) {
    return nil;
  }
  [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600}
                                    ofItemAtPath:path error:nil];

  NSString *displayName = [engineName capitalizedString];
  NSString *shortcut = slotCharacter == '1' ? @"⌃G" : @"⌃B";
  return [NSString stringWithFormat:@"%@已设为%@搜索引擎", displayName, shortcut];
}

static NSString *QueryURLEncode(NSString *value) {
  NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
  const unsigned char *characters = bytes.bytes;
  NSMutableString *encoded = [NSMutableString string];
  for (NSUInteger index = 0; index < bytes.length; ++index) {
    unsigned char character = characters[index];
    BOOL unreserved = (character >= 'A' && character <= 'Z') ||
        (character >= 'a' && character <= 'z') ||
        (character >= '0' && character <= '9') ||
        character == '-' || character == '.' || character == '_' || character == '~';
    if (unreserved) [encoded appendFormat:@"%c", character];
    else [encoded appendFormat:@"%%%02X", character];
  }
  return encoded;
}

static void OpenQuerySearch(CGKeyCode keycode) {
  if (!query_api || !query_session || !query_api->get_context) return;
  RimeContext_stdbool context = {0};
  RIME_STRUCT_INIT(RimeContext_stdbool, context);
  if (!query_api->get_context(query_session, &context)) return;
  int index = context.menu.highlighted_candidate_index;
  NSString *candidate = index >= 0 && index < context.menu.num_candidates &&
      context.menu.candidates[index].text ?
      [NSString stringWithUTF8String:context.menu.candidates[index].text] : nil;
  query_api->free_context(&context);
  if (!candidate.length) return;

  NSString *template = CurrentSearchEngineURL(keycode != kVK_ANSI_G);
  NSString *urlString = [template stringByReplacingOccurrencesOfString:@"{query}"
                                                              withString:QueryURLEncode(candidate)];
  NSURL *url = [NSURL URLWithString:urlString];
  if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

static void OpenQueryNews(void) {
  if (!query_active || !query_api || !query_session ||
      !query_api->get_context) return;
  RimeContext_stdbool context = {0};
  RIME_STRUCT_INIT(RimeContext_stdbool, context);
  if (!query_api->get_context(query_session, &context)) return;
  int index = context.menu.highlighted_candidate_index;
  NSString *candidate = index >= 0 && index < context.menu.num_candidates &&
      context.menu.candidates[index].text ?
      [NSString stringWithUTF8String:context.menu.candidates[index].text] : nil;
  query_api->free_context(&context);
  if (!candidate.length) return;

  NSString *url = [NSString stringWithFormat:
      @"chrome-extension://ggdjphniobpobmofgoimigpdcefmljed/news/news.html?q=%@",
      QueryURLEncode(candidate)];
  NSString *helper = [[NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Rime/bin"]
      stringByAppendingPathComponent:@"squirrel-open-url"];
  if (![[NSFileManager defaultManager] isExecutableFileAtPath:helper]) return;
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:helper];
  task.arguments = @[url];
  task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
  task.standardError = [NSFileHandle fileHandleWithNullDevice];
  [task launchAndReturnError:nil];
}

static NSString *QueryMarkerPath(void) {
  return [@"~/Library/Rime/input_translation.query_bridge.enabled"
      stringByExpandingTildeInPath];
}

static BOOL QueryEnabled(void) {
  return access(QueryMarkerPath().fileSystemRepresentation, F_OK) == 0;
}

static void SetCompositionVisible(BOOL visible) {
  NSString *path = [NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Rime/input_translation.composition.state"];
  NSString *value = visible ? @"1\n" : @"0\n";
  [value writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static BOOL IsSquirrelInputSource(void) {
  TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
  if (!source) return NO;
  NSString *identifier = (__bridge NSString *)TISGetInputSourceProperty(
      source, kTISPropertyInputSourceID);
  BOOL result = [identifier isEqualToString:
      @"im.rime.inputmethod.Squirrel.Hans"];
  CFRelease(source);
  return result;
}

static NSString *UtilityPayload(NSString *text, NSString *command);

static NSString *PhoneDigits(void) {
  NSString *input = UtilityPayload(query_text, @"phone") ?: @"";
  NSMutableString *digits = [NSMutableString string];
  for (NSUInteger index = 0; index < input.length; ++index) {
    unichar c = [input characterAtIndex:index];
    if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
  }
  if (digits.length == 13 && [digits hasPrefix:@"86"])
    [digits deleteCharactersInRange:NSMakeRange(0, 2)];
  return digits;
}

static BOOL IPv4QueryStatus(NSString *value, BOOL *complete) {
  if (complete) *complete = NO;
  // A complete ip keyword is required by the caller; wait for the first dot
  // before treating its numeric payload as an IPv4 address.
  if (!value.length || [value rangeOfString:@"."].location == NSNotFound) return NO;
  NSArray<NSString *> *octets = [value componentsSeparatedByString:@"."];
  if (octets.count > 4) return NO;
  for (NSUInteger index = 0; index < octets.count; ++index) {
    NSString *octet = octets[index];
    if (!octet.length) {
      if (index == octets.count - 1 && octets.count < 4) continue;
      return NO;
    }
    if (octet.length > 3) return NO;
    NSUInteger number = 0;
    for (NSUInteger digitIndex = 0; digitIndex < octet.length; ++digitIndex) {
      unichar character = [octet characterAtIndex:digitIndex];
      if (character < '0' || character > '9') return NO;
      number = number * 10 + (NSUInteger)(character - '0');
    }
    if (number > 255) return NO;
  }
  BOOL isComplete = octets.count == 4 && octets.lastObject.length > 0;
  if (complete) *complete = isComplete;
  return YES;
}

static NSString *UtilityPayload(NSString *text, NSString *command) {
  if ([text isEqualToString:command]) return @"";
  if (text.length <= command.length ||
      ![[text substringToIndex:command.length] isEqualToString:command])
    return nil;
  // A command's payload begins immediately after its keyword. Legacy
  // punctuation separators are deliberately not interpreted.
  unichar first = [text characterAtIndex:command.length];
  return first == ':' || first == '=' ? nil :
      [text substringFromIndex:command.length];
}

static NSString *SpecificIPInput(void) {
  NSString *payload = UtilityPayload(query_text, @"ip");
  return payload.length ? payload : nil;
}

static BOOL IsColorQuery(void) {
  return UtilityPayload(query_text, @"color") != nil ||
      UtilityPayload(query_text, @"yanse") != nil;
}

static BOOL IsBareColorQuery(void) {
  return [query_text isEqualToString:@"color"] ||
      [query_text isEqualToString:@"yanse"];
}

static BOOL IsColorConversionQuery(void) {
  NSString *payload = UtilityPayload(query_text, @"color");
  if (!payload) payload = UtilityPayload(query_text, @"yanse");
  return payload.length > 0;
}

static NSString *ColorConversionInput(void) {
  NSString *payload = UtilityPayload(query_text, @"color");
  if (!payload) payload = UtilityPayload(query_text, @"yanse");
  NSCharacterSet *separators = NSCharacterSet.whitespaceAndNewlineCharacterSet;
  return [payload stringByTrimmingCharactersInSet:separators];
}

static NSArray<NSString *> *ColorFormatNames(void) {
  static NSArray<NSString *> *formats;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    formats = @[
      @"HEX", @"HEX（无 #）", @"HEX + Alpha", @"RGB", @"RGBA",
      @"HSL", @"HSLA", @"HSV", @"HSVA"
    ];
  });
  return formats;
}

static NSArray<NSString *> *ColorValuesForColor(NSColor *color) {
  NSColor *sample = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (!sample) return nil;

  CGFloat red = 0, green = 0, blue = 0, alpha = 1;
  [sample getRed:&red green:&green blue:&blue alpha:&alpha];
  NSUInteger r = (NSUInteger)lround(red * 255.0);
  NSUInteger g = (NSUInteger)lround(green * 255.0);
  NSUInteger b = (NSUInteger)lround(blue * 255.0);
  NSUInteger a = (NSUInteger)lround(alpha * 255.0);
  CGFloat maximum = MAX(red, MAX(green, blue));
  CGFloat minimum = MIN(red, MIN(green, blue));
  CGFloat delta = maximum - minimum;
  CGFloat hue = 0;
  if (delta > 0) {
    if (maximum == red) hue = 60.0 * fmod((green - blue) / delta, 6.0);
    else if (maximum == green) hue = 60.0 * ((blue - red) / delta + 2.0);
    else hue = 60.0 * ((red - green) / delta + 4.0);
    if (hue < 0) hue += 360.0;
  }
  CGFloat lightness = (maximum + minimum) / 2.0;
  CGFloat hslSaturation = delta == 0 ? 0 :
      delta / (1.0 - fabs(2.0 * lightness - 1.0));
  CGFloat hsvSaturation = maximum == 0 ? 0 : delta / maximum;
  CGFloat opacity = alpha;
  return @[
    [NSString stringWithFormat:@"#%02lX%02lX%02lX",
        (unsigned long)r, (unsigned long)g, (unsigned long)b],
    [NSString stringWithFormat:@"%02lX%02lX%02lX",
        (unsigned long)r, (unsigned long)g, (unsigned long)b],
    [NSString stringWithFormat:@"#%02lX%02lX%02lX%02lX",
        (unsigned long)r, (unsigned long)g, (unsigned long)b, (unsigned long)a],
    [NSString stringWithFormat:@"rgb(%lu, %lu, %lu)",
        (unsigned long)r, (unsigned long)g, (unsigned long)b],
    [NSString stringWithFormat:@"rgba(%lu, %lu, %lu, %.2f)",
        (unsigned long)r, (unsigned long)g, (unsigned long)b, opacity],
    [NSString stringWithFormat:@"hsl(%.0f, %.1f%%, %.1f%%)",
        hue, hslSaturation * 100.0, lightness * 100.0],
    [NSString stringWithFormat:@"hsla(%.0f, %.1f%%, %.1f%%, %.2f)",
        hue, hslSaturation * 100.0, lightness * 100.0, opacity],
    [NSString stringWithFormat:@"hsv(%.0f, %.1f%%, %.1f%%)",
        hue, hsvSaturation * 100.0, maximum * 100.0],
    [NSString stringWithFormat:@"hsva(%.0f, %.1f%%, %.1f%%, %.2f)",
        hue, hsvSaturation * 100.0, maximum * 100.0, opacity]
  ];
}

static int HexDigit(unichar character) {
  if (character >= '0' && character <= '9') return character - '0';
  if (character >= 'a' && character <= 'f') return character - 'a' + 10;
  if (character >= 'A' && character <= 'F') return character - 'A' + 10;
  return -1;
}

static NSColor *ColorFromConversionInput(NSString *rawInput) {
  NSString *input = [[rawInput stringByTrimmingCharactersInSet:
      NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
  if (![input hasPrefix:@"#"] &&
      (input.length == 3 || input.length == 4 || input.length == 6 ||
       input.length == 8)) {
    BOOL isHex = YES;
    for (NSUInteger index = 0; index < input.length; ++index) {
      if (HexDigit([input characterAtIndex:index]) < 0) {
        isHex = NO;
        break;
      }
    }
    if (isHex) input = [@"#" stringByAppendingString:input];
  }
  if ([input hasPrefix:@"#"]) {
    NSString *digits = [input substringFromIndex:1];
    if (digits.length == 3 || digits.length == 4) {
      int values[4] = {0, 0, 0, 255};
      for (NSUInteger index = 0; index < digits.length; ++index) {
        int digit = HexDigit([digits characterAtIndex:index]);
        if (digit < 0) return nil;
        values[index] = digit * 17;
      }
      return [NSColor colorWithSRGBRed:values[0] / 255.0
          green:values[1] / 255.0 blue:values[2] / 255.0
          alpha:values[3] / 255.0];
    }
    if (digits.length == 6 || digits.length == 8) {
      int values[4] = {0, 0, 0, 255};
      for (NSUInteger index = 0; index < digits.length / 2; ++index) {
        int high = HexDigit([digits characterAtIndex:index * 2]);
        int low = HexDigit([digits characterAtIndex:index * 2 + 1]);
        if (high < 0 || low < 0) return nil;
        values[index] = high * 16 + low;
      }
      return [NSColor colorWithSRGBRed:values[0] / 255.0
          green:values[1] / 255.0 blue:values[2] / 255.0
          alpha:values[3] / 255.0];
    }
    return nil;
  }

  BOOL rgba = [input hasPrefix:@"rgba("];
  if ((!rgba && ![input hasPrefix:@"rgb("]) ||
      ![input hasSuffix:@")"]) return nil;
  NSUInteger prefixLength = rgba ? 5 : 4;
  NSString *body = [input substringWithRange:
      NSMakeRange(prefixLength, input.length - prefixLength - 1)];
  NSArray<NSString *> *parts = [body componentsSeparatedByString:@","];
  if (parts.count != (rgba ? 4u : 3u)) return nil;
  double components[4] = {0, 0, 0, 1};
  for (NSUInteger index = 0; index < parts.count; ++index) {
    NSString *part = [parts[index] stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSScanner *scanner = [NSScanner scannerWithString:part];
    if (![scanner scanDouble:&components[index]] || !scanner.isAtEnd ||
        !isfinite(components[index])) return nil;
    double upperBound = index == 3 ? 1.0 : 255.0;
    if (components[index] < 0 || components[index] > upperBound ||
        (index < 3 && floor(components[index]) != components[index])) return nil;
  }
  return [NSColor colorWithSRGBRed:components[0] / 255.0
      green:components[1] / 255.0 blue:components[2] / 255.0
      alpha:components[3]];
}

static NSArray<NSArray<NSString *> *> *RowsForColorConversion(void) {
  NSColor *color = ColorFromConversionInput(ColorConversionInput());
  NSArray<NSString *> *values = ColorValuesForColor(color);
  if (!values) return @[
    @[@"HEX", @"输入 #RGB、#RGBA、#RRGGBB、#RRGGBBAA"],
    @[@"RGB", @"或输入 rgb(r, g, b) / rgba(r, g, b, a)"],
  ];
  NSArray<NSString *> *formats = ColorFormatNames();
  NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray array];
  for (NSUInteger index = 0; index < formats.count; ++index)
    [rows addObject:@[formats[index], values[index]]];
  return rows;
}

static BOOL IsTimeQuery(void) {
  return UtilityPayload(query_text, @"time") != nil;
}

static BOOL IsDateQuery(void) {
  return UtilityPayload(query_text, @"date") != nil;
}

static BOOL IsUnitQuery(void) {
  return UtilityPayload(query_text, @"conv") != nil;
}

static BOOL IsKeywordInputMode(void) {
  return IsColorQuery() || IsTimeQuery() || IsDateQuery() || IsUnitQuery() ||
      UtilityPayload(query_text, @"ip") != nil ||
      UtilityPayload(query_text, @"phone") != nil ||
      QuerySearchEngineURL(query_text) != nil;
}

static NSString *ActiveUtilityKeyword(void) {
  // yanse is an alias for the color tool; show the English word whose
  // pronunciation appears in the result column.
  if (UtilityPayload(query_text, @"yanse") != nil) return @"color";
  for (NSString *keyword in @[@"color", @"time", @"date", @"conv",
                             @"ip", @"phone"]) {
    if (UtilityPayload(query_text, keyword) != nil) return keyword;
  }
  return nil;
}

static NSString *FormatDateForZone(NSDate *date, NSTimeZone *zone) {
  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  formatter.timeZone = zone;
  formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss z";
  return [formatter stringFromDate:date] ?: @"不可用";
}

static NSDate *DateFromISO8601Day(NSString *value) {
  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  formatter.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:
      NSCalendarIdentifierGregorian];
  formatter.lenient = NO;
  formatter.dateFormat = @"yyyy-MM-dd";
  NSDate *date = [formatter dateFromString:value];
  return date && [[formatter stringFromDate:date] isEqualToString:value] ? date : nil;
}

static NSString *UtilityNumber(double value) {
  char buffer[64];
  snprintf(buffer, sizeof(buffer), "%.7g", value);
  return [NSString stringWithUTF8String:buffer];
}

static NSArray<NSArray<NSString *> *> *RowsForTimeQuery(void) {
  NSString *payload = UtilityPayload(query_text, @"time");
  NSString *value = [payload stringByTrimmingCharactersInSet:
      NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!query_time_snapshot) query_time_snapshot = [NSDate date];
  NSDate *date = query_time_snapshot;
  NSTimeZone *displayZone = NSTimeZone.localTimeZone;
  if (value.length && ![value isEqualToString:@"now"]) {
    NSScanner *scanner = [NSScanner scannerWithString:value];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    double timestamp = 0;
    if ([scanner scanDouble:&timestamp] && scanner.isAtEnd && isfinite(timestamp)) {
      if (fabs(timestamp) >= 100000000000.0) timestamp /= 1000.0;
      if (timestamp < -62135596800.0 || timestamp > 253402300799.0)
        return @[@[@"时间戳超出范围", @"仅支持公元 0001–9999 年"]];
      date = [NSDate dateWithTimeIntervalSince1970:timestamp];
    } else if (value.length) {
      NSTimeZone *zone = [NSTimeZone timeZoneWithName:value];
      if (!zone) return @[
        @[@"时区或时间戳", @"输入 Unix 秒／毫秒，或时区名如 Asia/Tokyo"]
      ];
      displayZone = zone;
    }
  }
  int64_t seconds = (int64_t)floor(date.timeIntervalSince1970);
  return @[
    @[@"本地时间", FormatDateForZone(date, NSTimeZone.localTimeZone)],
    @[@"目标时区", FormatDateForZone(date, displayZone)],
    @[@"UTC", FormatDateForZone(date, [NSTimeZone timeZoneForSecondsFromGMT:0])],
    @[@"Unix 秒", [NSString stringWithFormat:@"%lld", (long long)seconds]],
    @[@"Unix 毫秒", [NSString stringWithFormat:@"%lld", (long long)llround(date.timeIntervalSince1970 * 1000.0)]]
  ];
}

static NSArray<NSArray<NSString *> *> *RowsForDateQuery(void) {
  NSString *payload = UtilityPayload(query_text, @"date");
  NSString *value = [payload stringByTrimmingCharactersInSet:
      NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSArray<NSString *> *dates = [value componentsSeparatedByString:@".."];
  if (dates.count == 1 && value.length) {
    NSDateFormatter *todayFormatter = [[NSDateFormatter alloc] init];
    todayFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    todayFormatter.timeZone = NSTimeZone.localTimeZone;
    todayFormatter.dateFormat = @"yyyy-MM-dd";
    dates = @[value, [todayFormatter stringFromDate:[NSDate date]]];
  }
  if (dates.count != 2) return @[
    @[@"日期间隔", @"格式：udateYYYY-MM-DD..YYYY-MM-DD"]
  ];
  NSDate *start = DateFromISO8601Day(dates[0]);
  NSDate *end = DateFromISO8601Day(dates[1]);
  if (!start || !end) return @[
    @[@"日期格式", @"请使用有效日期，例如 2026-01-01..2026-09-30"]
  ];
  int64_t days = (int64_t)llround([end timeIntervalSinceDate:start] / 86400.0);
  return @[
    @[@"相差天数", [NSString stringWithFormat:@"%lld 天", (long long)labs(days)]],
    @[@"方向", days < 0 ? @"结束日期早于开始日期" : @"结束日期不早于开始日期"],
    @[@"开始日期", dates[0]],
    @[@"结束日期", dates[1]],
  ];
}

typedef NS_ENUM(NSInteger, STUnitDimension) {
  STUnitLength, STUnitMass, STUnitVolume, STUnitTemperature
};

typedef struct {
  __unsafe_unretained NSString *symbol;
  __unsafe_unretained NSString *name;
  double factor;
} STUnitDefinition;

static NSArray<NSArray<NSString *> *> *RowsForUnitInput(NSString *payload) {
  NSScanner *scanner = [NSScanner scannerWithString:payload ?: @""];
  scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  double inputValue = 0;
  if (![scanner scanDouble:&inputValue] || !isfinite(inputValue)) return @[
    @[@"单位换算", @"格式：uconv数值单位，例如 uconv5mi 或 uconv72°F"]
  ];
  NSString *inputUnit = [[payload substringFromIndex:scanner.scanLocation]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  inputUnit = [[inputUnit stringByReplacingOccurrencesOfString:@"°" withString:@""]
      lowercaseString];
  NSDictionary<NSString *, NSString *> *aliases = @{
    @"millimeter": @"mm", @"millimeters": @"mm", @"毫米": @"mm",
    @"centimeter": @"cm", @"centimeters": @"cm", @"厘米": @"cm",
    @"meter": @"m", @"meters": @"m", @"米": @"m",
    @"kilometer": @"km", @"kilometers": @"km", @"公里": @"km",
    @"inch": @"in", @"inches": @"in", @"英寸": @"in",
    @"feet": @"ft", @"foot": @"ft", @"英尺": @"ft",
    @"yard": @"yd", @"yards": @"yd", @"码": @"yd",
    @"mile": @"mi", @"miles": @"mi", @"英里": @"mi",
    @"milligram": @"mg", @"milligrams": @"mg", @"毫克": @"mg",
    @"gram": @"g", @"grams": @"g", @"克": @"g",
    @"kilogram": @"kg", @"kilograms": @"kg", @"公斤": @"kg", @"千克": @"kg",
    @"ounce": @"oz", @"ounces": @"oz", @"盎司": @"oz",
    @"pound": @"lb", @"pounds": @"lb", @"磅": @"lb",
    @"milliliter": @"ml", @"milliliters": @"ml", @"毫升": @"ml",
    @"liter": @"l", @"liters": @"l", @"升": @"l",
    @"gallon": @"gal", @"gallons": @"gal", @"加仑": @"gal",
    @"celsius": @"c", @"fahrenheit": @"f", @"kelvin": @"k"
  };
  inputUnit = aliases[inputUnit] ?: inputUnit;

  static const STUnitDefinition length[] = {
    {@"mm", @"毫米", 0.001}, {@"cm", @"厘米", 0.01},
    {@"m", @"米", 1.0}, {@"km", @"公里", 1000.0},
    {@"in", @"英寸", 0.0254}, {@"ft", @"英尺", 0.3048},
    {@"yd", @"码", 0.9144}, {@"mi", @"英里", 1609.344}
  };
  static const STUnitDefinition mass[] = {
    {@"mg", @"毫克", 0.000001}, {@"g", @"克", 0.001},
    {@"kg", @"千克", 1.0}, {@"oz", @"盎司", 0.028349523125},
    {@"lb", @"磅", 0.45359237}
  };
  static const STUnitDefinition volume[] = {
    {@"ml", @"毫升", 0.001}, {@"l", @"升", 1.0},
    {@"gal", @"美制加仑", 3.785411784}
  };
  const STUnitDefinition *definitions = NULL;
  size_t definitionCount = 0;
  STUnitDimension dimension = STUnitLength;
  if ([inputUnit isEqualToString:@"mm"] || [inputUnit isEqualToString:@"cm"] ||
      [inputUnit isEqualToString:@"m"] || [inputUnit isEqualToString:@"km"] ||
      [inputUnit isEqualToString:@"in"] || [inputUnit isEqualToString:@"ft"] ||
      [inputUnit isEqualToString:@"yd"] || [inputUnit isEqualToString:@"mi"]) {
    definitions = length; definitionCount = sizeof(length) / sizeof(length[0]);
  } else if ([inputUnit isEqualToString:@"mg"] || [inputUnit isEqualToString:@"g"] ||
             [inputUnit isEqualToString:@"kg"] || [inputUnit isEqualToString:@"oz"] ||
             [inputUnit isEqualToString:@"lb"]) {
    definitions = mass; definitionCount = sizeof(mass) / sizeof(mass[0]);
    dimension = STUnitMass;
  } else if ([inputUnit isEqualToString:@"ml"] || [inputUnit isEqualToString:@"l"] ||
             [inputUnit isEqualToString:@"gal"]) {
    definitions = volume; definitionCount = sizeof(volume) / sizeof(volume[0]);
    dimension = STUnitVolume;
  } else if ([inputUnit isEqualToString:@"c"] || [inputUnit isEqualToString:@"f"] ||
             [inputUnit isEqualToString:@"k"]) {
    dimension = STUnitTemperature;
  } else {
    return @[@[@"单位不支持", @"长度、质量、体积：mm cm m km in ft yd mi mg g kg oz lb ml l gal；温度：°C °F K"]];
  }

  NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray array];
  if (dimension == STUnitTemperature) {
    double celsius = [inputUnit isEqualToString:@"f"] ?
        (inputValue - 32.0) * 5.0 / 9.0 :
        ([inputUnit isEqualToString:@"k"] ? inputValue - 273.15 : inputValue);
    if (celsius < -273.15)
      return @[@[@"温度超出范围", @"不能低于绝对零度 -273.15 °C"]];
    [rows addObject:@[@"摄氏度", [NSString stringWithFormat:@"%@ °C", UtilityNumber(celsius)]]];
    [rows addObject:@[@"华氏度", [NSString stringWithFormat:@"%@ °F", UtilityNumber(celsius * 9.0 / 5.0 + 32.0)]]];
    [rows addObject:@[@"开尔文", [NSString stringWithFormat:@"%@ K", UtilityNumber(celsius + 273.15)]]];
    return rows;
  }

  double baseValue = inputValue;
  BOOL foundInput = NO;
  for (size_t index = 0; index < definitionCount; ++index) {
    if ([inputUnit isEqualToString:definitions[index].symbol]) {
      baseValue *= definitions[index].factor;
      foundInput = YES;
      break;
    }
  }
  if (!foundInput) return @[@[@"单位不支持", inputUnit]];
  if (!isfinite(baseValue))
    return @[@[@"数值超出范围", @"请缩小输入数值"]];
  for (size_t index = 0; index < definitionCount; ++index) {
    double converted = baseValue / definitions[index].factor;
    if (!isfinite(converted))
      return @[@[@"数值超出范围", @"请缩小输入数值"]];
    NSString *label = [NSString stringWithFormat:@"%@ (%@)",
        definitions[index].name, definitions[index].symbol];
    NSString *result = [NSString stringWithFormat:@"%@ %@",
        UtilityNumber(converted), definitions[index].symbol];
    [rows addObject:@[label, result]];
  }
  return rows;
}

static NSArray<NSArray<NSString *> *> *RowsForQuickConversions(double value);

static NSArray<NSArray<NSString *> *> *RowsForUnitQuery(void) {
  NSString *payload = UtilityPayload(query_text, @"conv");
  NSScanner *scanner = [NSScanner scannerWithString:payload ?: @""];
  scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  double value = 0;
  if ([scanner scanDouble:&value] && isfinite(value) && scanner.isAtEnd)
    return RowsForQuickConversions(value);
  return RowsForUnitInput(payload);
}

// A number following conv has no implied unit; each row names both sides.
static NSArray<NSArray<NSString *> *> *RowsForQuickConversions(double value) {
  if (fabs(value) > 1e100) return @[@[@"数值超出范围", @"请缩小输入数值"]];
  return @[
    @[@"km → mi",
      [NSString stringWithFormat:@"%@ mi", UtilityNumber(value / 1.609344)]],
    @[@"mi → km",
      [NSString stringWithFormat:@"%@ km", UtilityNumber(value * 1.609344)]],
    @[@"kg → lb",
      [NSString stringWithFormat:@"%@ lb", UtilityNumber(value / 0.45359237)]],
    @[@"lb → kg",
      [NSString stringWithFormat:@"%@ kg", UtilityNumber(value * 0.45359237)]],
    @[@"°C → °F",
      [NSString stringWithFormat:@"%@ °F", UtilityNumber(value * 9.0 / 5.0 + 32.0)]],
    @[@"°F → °C",
      [NSString stringWithFormat:@"%@ °C", UtilityNumber((value - 32.0) * 5.0 / 9.0)]],
    @[@"L → gal",
      [NSString stringWithFormat:@"%@ gal", UtilityNumber(value / 3.785411784)]],
    @[@"gal → L",
      [NSString stringWithFormat:@"%@ L", UtilityNumber(value * 3.785411784)]]
  ];
}

static BOOL MoveColorSampleCursor(CGKeyCode keycode, CGPoint eventPosition) {
  if (!query_color_cursor_position_valid) {
    query_color_cursor_position = eventPosition;
    query_color_cursor_position_valid = YES;
  }
  uint32_t displayCount = 0;
  CGDirectDisplayID display = kCGNullDirectDisplay;
  if (CGGetDisplaysWithPoint(query_color_cursor_position, 1, &display,
                             &displayCount) != kCGErrorSuccess ||
      displayCount == 0) return NO;

  CGRect bounds = CGDisplayBounds(display);
  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
  size_t pixelWidth = mode ? CGDisplayModeGetPixelWidth(mode) :
      CGDisplayPixelsWide(display);
  size_t pixelHeight = mode ? CGDisplayModeGetPixelHeight(mode) :
      CGDisplayPixelsHigh(display);
  if (mode) CGDisplayModeRelease(mode);
  CGFloat stepX = pixelWidth ? bounds.size.width / pixelWidth : 1.0;
  CGFloat stepY = pixelHeight ? bounds.size.height / pixelHeight : 1.0;
  // CGDisplayPixelsWide can report logical points, not the mode's pixel grid.
  // Mouse-moved events keep this cached position current; do not resync from
  // the key event, whose pointer location can lag behind queued arrow events.
  CGPoint next = query_color_cursor_position;
  if (keycode == kVK_LeftArrow) next.x -= stepX;
  else if (keycode == kVK_RightArrow) next.x += stepX;
  else if (keycode == kVK_UpArrow) next.y -= stepY;
  else if (keycode == kVK_DownArrow) next.y += stepY;
  else return NO;

  next.x = MIN(MAX(next.x, CGRectGetMinX(bounds)),
               CGRectGetMaxX(bounds) - stepX);
  next.y = MIN(MAX(next.y, CGRectGetMinY(bounds)),
               CGRectGetMaxY(bounds) - stepY);
  CGError warpResult = CGWarpMouseCursorPosition(next);
  query_color_cursor_position = next;

  // Do not attach a mouse button to a move event. NSColorSampler interprets
  // left-button state as a drag, which can draw a selection rectangle.
  CGEventRef moved = CGEventCreate(NULL);
  if (moved) {
    CGEventSetType(moved, kCGEventMouseMoved);
    CGEventSetLocation(moved, next);
    CGEventPost(kCGHIDEventTap, moved);
    CFRelease(moved);
  }
  return warpResult == kCGErrorSuccess || moved != NULL;
}

static void ConfirmColorSampleAtPoint(CGPoint position) {
  if (!query_color_sampling_active || !query_color_sampler ||
      !query_color_confirmation_pending) return;
  NSUInteger session = query_color_session_generation;
  NSUInteger confirmation = ++query_color_confirmation_generation;
  CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown,
                                            position, kCGMouseButtonLeft);
  CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp,
                                          position, kCGMouseButtonLeft);
  if (down && up) {
    CGEventSetIntegerValueField(down, kCGEventSourceUserData,
                                kQueryColorSyntheticClickMarker);
    CGEventSetIntegerValueField(up, kCGEventSourceUserData,
                                kQueryColorSyntheticClickMarker);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    // A rejected synthetic click must not block a later physical Space/Escape.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
      if (session != query_color_session_generation ||
          confirmation != query_color_confirmation_generation ||
          !query_color_sampling_active || !query_color_confirmation_pending)
        return;
      query_color_confirmation_pending = NO;
      SetQueryBridgeStatus(@"color: simulated confirmation timed out");
    });
  } else {
    query_color_confirmation_pending = NO;
    SetQueryBridgeStatus(@"color: simulated confirmation unavailable");
  }
  if (down) CFRelease(down);
  if (up) CFRelease(up);
}

static void ConfirmColorSampleAtCursor(void) {
  CGEventRef cursor = CGEventCreate(NULL);
  if (!cursor) {
    query_color_confirmation_pending = NO;
    return;
  }
  CGPoint position = query_color_cursor_position_valid ?
      query_color_cursor_position : CGEventGetLocation(cursor);
  CFRelease(cursor);
  ConfirmColorSampleAtPoint(position);
}

static void StartQueryColorSampling(void) {
  if (!query_active || !IsBareColorQuery() || query_color_sampling_active ||
      query_color_sampler_started) return;
  query_color_sampler_started = YES;
  NSUInteger session = ++query_color_session_generation;
  query_color_sampling_active = YES;
  query_color_confirmation_pending = NO;
  query_color_cancel_pending = NO;
  query_color_cursor_position_valid = NO;
  // Keep the result panel visible below the system magnifier.
  query_panel.level = NSStatusWindowLevel;
  CGEventRef cursorEvent = CGEventCreate(NULL);
  if (cursorEvent) {
    query_color_cursor_position = CGEventGetLocation(cursorEvent);
    query_color_cursor_position_valid = YES;
    CFRelease(cursorEvent);
  }
  query_color_sampler = [[NSColorSampler alloc] init];
  [query_color_sampler showSamplerWithSelectionHandler:^(NSColor *selectedColor) {
    if (session != query_color_session_generation) return;
    BOOL wasCancelled = query_color_cancel_pending;
    SetQueryBridgeStatus(wasCancelled ? @"color: magnifier cancelled" :
        (selectedColor ? @"color: selected" : @"color: sampler dismissed"));
    query_color_sampling_active = NO;
    // This flag means the bare-color query already opened a sampler. Keep it
    // set after dismissal so ShowQueryContext does not open another one.
    // Only a new query or manual Space clears it.
    query_color_sampler_started = YES;
    query_color_confirmation_pending = NO;
    query_color_cancel_pending = NO;
    query_color_sampler = nil;
    query_panel.level = CGShieldingWindowLevel();
    if (!query_active || !IsColorQuery()) return;
    if (!wasCancelled) {
      query_color_sample = selectedColor ?
          [selectedColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace] : nil;
    }
    ShowQueryContext();
  }];
}

static NSInteger QueryUtilityCandidateCount(void) {
  NSInteger count = 0;
  if (IsColorQuery())
    count = IsColorConversionQuery() ? (NSInteger)RowsForColorConversion().count :
        (NSInteger)ColorFormatNames().count;
  else if (IsTimeQuery()) count = (NSInteger)RowsForTimeQuery().count;
  else if (IsDateQuery()) count = (NSInteger)RowsForDateQuery().count;
  else if (IsUnitQuery()) count = (NSInteger)RowsForUnitQuery().count;
  else if ([query_text isEqualToString:@"ip"]) count = 2;
  else if (UtilityPayload(query_text, @"ip") != nil ||
           UtilityPayload(query_text, @"phone") != nil) count = 1;
  return count + (count > 0 && ActiveUtilityKeyword() != nil ? 1 : 0);
}

static NSString *LocalIPAddress(void) {
  struct ifaddrs *interfaces = NULL;
  if (getifaddrs(&interfaces) != 0) return @"不可用";
  NSString *fallback = nil;
  for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
    if (!item->ifa_addr || (item->ifa_flags & IFF_LOOPBACK)) continue;
    int family = item->ifa_addr->sa_family;
    if (family != AF_INET && family != AF_INET6) continue;
    char address[INET6_ADDRSTRLEN] = {0};
    const void *source = family == AF_INET ?
        (const void *)&((struct sockaddr_in *)item->ifa_addr)->sin_addr :
        (const void *)&((struct sockaddr_in6 *)item->ifa_addr)->sin6_addr;
    if (!inet_ntop(family, source, address, sizeof(address))) continue;
    NSString *value = [NSString stringWithUTF8String:address];
    if (family == AF_INET && ![value hasPrefix:@"169.254."]) {
      fallback = value;
      break;
    }
    if (!fallback) fallback = value;
  }
  freeifaddrs(interfaces);
  return fallback ?: @"未连接";
}

static NSString *PhoneRegionForDigits(NSString *digits) {
  if (digits.length != 11 || ![digits hasPrefix:@"1"]) return nil;
  if (!query_phone_data) {
    NSString *path = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:
            @"Contents/Frameworks/rime-plugins/phone-region-phone.dat"];
    query_phone_data = [NSData dataWithContentsOfFile:path
        options:NSDataReadingMappedIfSafe error:nil];
  }
  const uint8_t *bytes = query_phone_data.bytes;
  NSUInteger size = query_phone_data.length;
  if (!bytes || size < 8) return nil;
  uint32_t indexStart = 0;
  memcpy(&indexStart, bytes + 4, sizeof(indexStart));
  indexStart = CFSwapInt32LittleToHost(indexStart);
  if (indexStart >= size || (size - indexStart) % 9 != 0) return nil;
  uint32_t key = (uint32_t)[[digits substringToIndex:7] integerValue];
  NSUInteger count = (size - indexStart) / 9;
  NSUInteger left = 0;
  NSUInteger right = count;
  while (left < right) {
    NSUInteger middle = left + (right - left) / 2;
    NSUInteger offset = indexStart + middle * 9;
    uint32_t current = 0;
    memcpy(&current, bytes + offset, sizeof(current));
    current = CFSwapInt32LittleToHost(current);
    if (current < key) left = middle + 1;
    else right = middle;
  }
  NSUInteger offset = indexStart + left * 9;
  if (offset + 9 > size) return nil;
  uint32_t current = 0, infoOffset = 0;
  memcpy(&current, bytes + offset, 4);
  memcpy(&infoOffset, bytes + offset + 4, 4);
  current = CFSwapInt32LittleToHost(current);
  infoOffset = CFSwapInt32LittleToHost(infoOffset);
  if (current != key || infoOffset >= size) return nil;
  const uint8_t *end = memchr(bytes + infoOffset, 0, size - infoOffset);
  if (!end) return nil;
  NSString *record = [[NSString alloc] initWithBytes:bytes + infoOffset
      length:(NSUInteger)(end - (bytes + infoOffset))
      encoding:NSUTF8StringEncoding];
  NSArray<NSString *> *fields = [record componentsSeparatedByString:@"|"];
  if (fields.count < 2) return nil;
  static NSArray<NSString *> *carriers;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    carriers = @[@"未知运营商", @"中国移动", @"中国联通", @"中国电信",
                 @"中国电信虚拟运营商", @"中国联通虚拟运营商",
                 @"中国移动虚拟运营商", @"中国广电"];
  });
  uint8_t carrier = bytes[offset + 8];
  NSString *carrierName = carrier < carriers.count ? carriers[carrier] : carriers[0];
  return [NSString stringWithFormat:@"%@ %@ · %@", fields[0], fields[1], carrierName];
}

static void ScheduleIPLookup(NSString *targetIP) {
  BOOL isPublicIPLookup = [query_text isEqualToString:@"ip"];
  BOOL isSpecificIPLookup = NO;
  if (!isPublicIPLookup) {
    BOOL complete = NO;
    NSString *ipInput = SpecificIPInput();
    isSpecificIPLookup = IPv4QueryStatus(ipInput, &complete) && complete &&
        [ipInput isEqualToString:targetIP];
  }
  if (!isPublicIPLookup && !isSpecificIPLookup) return;
  AdvanceQueryGeneration();
  NSUInteger generation = query_utility_generation;
  [query_ip_task cancel];
  query_ip_task = nil;
  query_ip_details = isPublicIPLookup ? @"正在查询公网 IP 和地区…" :
      @"正在查询 IP 地区和网络信息…";
  if (isPublicIPLookup) query_ip_public_ip = nil;
  NSString *queryAtSchedule = [query_text copy];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
    if (!query_active || generation != query_utility_generation ||
        ![query_text isEqualToString:queryAtSchedule]) return;
    NSURLComponents *components =
        [NSURLComponents componentsWithString:@"https://ipwho.is/"];
    if (isSpecificIPLookup) {
      components.path = [@"/" stringByAppendingString:targetIP];
    }
    components.queryItems = @[
      [NSURLQueryItem queryItemWithName:@"fields"
                                  value:@"success,ip,country,region,city,connection"],
      [NSURLQueryItem queryItemWithName:@"lang" value:@"zh-CN"]
    ];
    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:components.URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:5.0];
    request.HTTPMethod = @"GET";
    query_ip_task = [NSURLSession.sharedSession
        dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
      NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data
          options:NSJSONReadingFragmentsAllowed error:nil] : nil;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!query_active || generation != query_utility_generation ||
            ![query_text isEqualToString:queryAtSchedule]) return;
        if (error || http.statusCode < 200 || http.statusCode >= 300 ||
            ![json[@"success"] boolValue]) {
          query_ip_details = @"公网 IP 查询失败（网络不可用或服务限流）";
        } else {
          NSString *ip = [json[@"ip"] isKindOfClass:NSString.class] ? json[@"ip"] : @"";
          if (isPublicIPLookup) query_ip_public_ip = ip.length ? ip : nil;
          NSString *country = [json[@"country"] isKindOfClass:NSString.class] ?
              json[@"country"] : @"";
          NSString *region = [json[@"region"] isKindOfClass:NSString.class] ?
              json[@"region"] : @"";
          NSString *city = [json[@"city"] isKindOfClass:NSString.class] ?
              json[@"city"] : @"";
          NSDictionary *connection = [json[@"connection"] isKindOfClass:NSDictionary.class] ?
              json[@"connection"] : @{};
          NSString *isp = [connection[@"isp"] isKindOfClass:NSString.class] ?
              connection[@"isp"] : @"";
          NSMutableArray *place = [NSMutableArray array];
          if (country.length) [place addObject:country];
          if (region.length && ![region isEqualToString:country]) [place addObject:region];
          if (city.length && ![city isEqualToString:region]) [place addObject:city];
          NSString *location = [place componentsJoinedByString:@" "];
          NSArray<NSString *> *parts = [@[(isSpecificIPLookup ? targetIP : ip), location, isp] filteredArrayUsingPredicate:
              [NSPredicate predicateWithBlock:^BOOL(NSString *value, NSDictionary *bindings) {
                (void)bindings;
                return value.length > 0;
              }]];
          query_ip_details = [parts componentsJoinedByString:@" · "];
          if (!query_ip_details.length) query_ip_details = @"未返回 IP 地区信息";
        }
        ShowQueryContext();
      });
    }];
    [query_ip_task resume];
  });
}

static BOOL QueryUtilityMode(NSMutableArray<NSString *> *candidates,
                             NSMutableArray<NSString *> *comments,
                             NSString **input) {
  if (IsColorQuery()) {
    [candidates removeAllObjects];
    [comments removeAllObjects];
    *input = [@"u" stringByAppendingString:query_text];
    NSArray<NSArray<NSString *> *> *rows = nil;
    if (IsColorConversionQuery()) {
      rows = RowsForColorConversion();
    } else {
      NSArray<NSString *> *formats = ColorFormatNames();
      NSArray<NSString *> *values = ColorValuesForColor(query_color_sample);
      NSString *placeholder = query_color_sampler_started ?
          @"未选择颜色；按空格重新取色" : @"点击屏幕选择颜色";
      NSMutableArray *sampleRows = [NSMutableArray array];
      for (NSUInteger index = 0; index < formats.count; ++index) {
        NSString *result = values ? values[index] : placeholder;
        [sampleRows addObject:@[formats[index], result]];
      }
      rows = sampleRows;
    }
    for (NSArray<NSString *> *row in rows) {
      [candidates addObject:row[0]];
      [comments addObject:row[1]];
    }
    return YES;
  }
  if (IsTimeQuery() || IsDateQuery() || IsUnitQuery()) {
    [candidates removeAllObjects];
    [comments removeAllObjects];
    *input = [@"u" stringByAppendingString:query_text];
    NSArray<NSArray<NSString *> *> *rows = IsTimeQuery() ? RowsForTimeQuery() :
        (IsDateQuery() ? RowsForDateQuery() : RowsForUnitQuery());
    for (NSArray<NSString *> *row in rows) {
      [candidates addObject:row[0]];
      [comments addObject:row[1]];
    }
    return YES;
  }
  if ([query_text isEqualToString:@"ip"]) {
    [candidates removeAllObjects];
    [comments removeAllObjects];
    *input = [@"u" stringByAppendingString:query_text];
    [candidates addObjectsFromArray:@[@"本地 IP", @"公网 IP"]];
    [comments addObjectsFromArray:@[
      LocalIPAddress(),
      query_ip_details ?: @"输入停止后自动查询"
    ]];
    return YES;
  }
  BOOL isCompleteIP = NO;
  NSString *ipInput = SpecificIPInput();
  if (UtilityPayload(query_text, @"ip") != nil) {
    [candidates removeAllObjects];
    [comments removeAllObjects];
    *input = [@"u" stringByAppendingString:query_text];
    BOOL validIP = IPv4QueryStatus(ipInput, &isCompleteIP);
    [candidates addObject:validIP && isCompleteIP ? @"IP 地址查询" : @"输入 IPv4 地址"];
    NSString *detail = validIP && isCompleteIP ?
        (query_ip_details ?: @"输入停顿后自动查询") :
        @"输入完整地址 · 例如 uip8.8.8.8";
    [comments addObject:detail];
    return YES;
  }
  NSString *digits = PhoneDigits();
  if (UtilityPayload(query_text, @"phone") == nil) return NO;
  [candidates removeAllObjects];
  [comments removeAllObjects];
  *input = [@"u" stringByAppendingString:query_text];
  if (digits.length < 11) {
    [candidates addObject:@"手机号归属地"];
    [comments addObject:[NSString stringWithFormat:@"继续输入 · %lu/11",
        (unsigned long)digits.length]];
  } else {
    NSString *region = PhoneRegionForDigits(digits);
    [candidates addObject:region ? @"号段归属地" : @"未找到该号段"];
    [comments addObject:region ?: @"仅支持中国大陆手机号；号码不会发送到网络"];
  }
  return YES;
}

typedef NS_ENUM(NSInteger, STFocusedElementState) {
  STFocusedElementUnknown,
  STFocusedElementEditable,
  STFocusedElementNotEditable,
};

static CGFloat FontLineHeight(NSFont *font) {
  return ceil(font.ascender - font.descender + font.leading);
}

static CGFloat QueryPanelHorizontalPadding(void) { return 8; }
static CGFloat QueryPanelVerticalPadding(void) { return 7; }
static CGFloat QueryPreeditPadding(void) { return 9; }
static CGFloat QueryCandidateCommentTabWidth(NSFont *font) {
  NSDictionary *attributes = @{NSFontAttributeName:
      font ?: [NSFont userFontOfSize:16]};
  return 4 * [@" " sizeWithAttributes:attributes].width;
}
static CGFloat QueryCandidateRowPadding(void) { return 10; }

static STFocusedElementState FocusedElementState(void) {
  AXUIElementRef system = AXUIElementCreateSystemWide();
  if (!system) {
    query_last_focus_error = kAXErrorFailure;
    return STFocusedElementUnknown;
  }
  AXUIElementSetMessagingTimeout(system, 0.02);
  CFTypeRef focused = NULL;
  AXError error = AXUIElementCopyAttributeValue(
      system, kAXFocusedUIElementAttribute, &focused);
  CFRelease(system);
  // AX explicitly reporting no focused element means there is no active
  // editing target. This is common when clicking blank areas in Finder or
  // browser chrome, and should allow the query prefix. Transport failures
  // remain unknown so we never swallow input in an unverified text field.
  if (error == kAXErrorNoValue) {
    query_last_focus_error = error;
    return STFocusedElementNotEditable;
  }
  if (error != kAXErrorSuccess || !focused) {
    query_last_focus_error = error;
    return STFocusedElementUnknown;
  }
  AXUIElementRef element = (AXUIElementRef)focused;
  AXUIElementSetMessagingTimeout(element, 0.02);

  CFTypeRef role = NULL;
  error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute, &role);
  if (error != kAXErrorSuccess || !role) {
    query_last_focus_error = error;
    CFRelease(focused);
    return STFocusedElementUnknown;
  }
  query_last_focus_error = kAXErrorSuccess;
  BOOL editable = NO;
  if (role) {
    NSString *value = CFBridgingRelease(role);
    editable = [value isEqualToString:(NSString *)kAXTextFieldRole] ||
        [value isEqualToString:(NSString *)kAXTextAreaRole] ||
        [value isEqualToString:(NSString *)kAXComboBoxRole] ||
        [value isEqualToString:@"AXSearchField"] ||
        [value isEqualToString:@"AXSecureTextField"];
  }
  if (!editable) {
    CFTypeRef isEditable = NULL;
    if (AXUIElementCopyAttributeValue(element, CFSTR("AXEditable"),
                                      &isEditable) == kAXErrorSuccess &&
        isEditable) {
      editable = CFGetTypeID(isEditable) == CFBooleanGetTypeID() &&
          CFBooleanGetValue((CFBooleanRef)isEditable);
      CFRelease(isEditable);
    }
  }
  CFRelease(focused);
  return editable ? STFocusedElementEditable : STFocusedElementNotEditable;
}

@interface STQueryBridgeViewV4 : NSView
@property(nonatomic, copy) NSArray<NSString *> *candidates;
@property(nonatomic, copy) NSArray<NSString *> *comments;
@property(nonatomic, copy) NSString *input;
@property(nonatomic) NSInteger highlighted;
@property(nonatomic) CGFloat commentColumnX;
@property(nonatomic, copy) NSArray<NSNumber *> *rowHeights;
@property(nonatomic) NSRect helpIconRect;
@property(nonatomic, copy) NSString *helpPageIndicator;
@property(nonatomic, strong) NSFont *candidateFont;
@property(nonatomic, strong) NSFont *labelFont;
@property(nonatomic, strong) NSFont *commentFont;
@property(nonatomic, strong) NSFont *preeditFont;
@end

static NSColor *QueryHighlightFillColor(void) {
  return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
    BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameDarkAqua, NSAppearanceNameAqua]]
        isEqualToString:NSAppearanceNameDarkAqua];
    return dark ? [NSColor colorWithSRGBRed:0.17 green:0.30 blue:0.39 alpha:1.0] :
        [NSColor colorWithSRGBRed:0.88 green:0.94 blue:0.99 alpha:1.0];
  }];
}

static NSColor *QueryHighlightBorderColor(void) {
  return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
    BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameDarkAqua, NSAppearanceNameAqua]]
        isEqualToString:NSAppearanceNameDarkAqua];
    return dark ? [NSColor colorWithSRGBRed:0.34 green:0.50 blue:0.59 alpha:1.0] :
        [NSColor colorWithSRGBRed:0.67 green:0.79 blue:0.89 alpha:1.0];
  }];
}

static NSColor *QueryPanelBorderColor(void) {
  return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
    BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameDarkAqua, NSAppearanceNameAqua]]
        isEqualToString:NSAppearanceNameDarkAqua];
    return dark ? [NSColor colorWithSRGBRed:0.30 green:0.34 blue:0.39 alpha:1.0] :
        [NSColor colorWithSRGBRed:0.82 green:0.85 blue:0.89 alpha:1.0];
  }];
}

static NSColor *QueryPanelBackgroundColor(void) {
  return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
    BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameDarkAqua, NSAppearanceNameAqua]]
        isEqualToString:NSAppearanceNameDarkAqua];
    return dark ? [NSColor colorWithSRGBRed:0.10 green:0.11 blue:0.13 alpha:0.88] :
        [NSColor colorWithSRGBRed:0.99 green:0.995 blue:1.0 alpha:0.88];
  }];
}

static void DrawQueryTextCentered(NSString *text, NSFont *font, NSColor *color,
                                  NSRect row, CGFloat x, BOOL underline) {
  if (!text.length) return;
  CTFontRef ctFont = CTFontCreateWithName((__bridge CFStringRef)font.fontName,
                                         font.pointSize, NULL);
  NSMutableDictionary *attributes = [@{
    (__bridge id)kCTFontAttributeName: (__bridge id)ctFont,
    (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color.CGColor
  } mutableCopy];
  if (underline) {
    attributes[(__bridge id)kCTUnderlineStyleAttributeName] =
        @(kCTUnderlineStyleSingle);
    attributes[(__bridge id)kCTUnderlineColorAttributeName] =
        (__bridge id)color.CGColor;
  }
  NSAttributedString *attributed = [[NSAttributedString alloc]
      initWithString:text attributes:attributes];
  CTLineRef line = CTLineCreateWithAttributedString(
      (__bridge CFAttributedStringRef)attributed);
  CGRect bounds = CTLineGetImageBounds(line, NULL);
  CGFloat baseline = NSMidY(row) -
      (CGRectGetMinY(bounds) + CGRectGetMaxY(bounds)) / 2;
  CGContextRef context = NSGraphicsContext.currentContext.CGContext;
  CGContextSaveGState(context);
  CGContextSetTextMatrix(context, CGAffineTransformIdentity);
  CGContextSetTextPosition(context, x, baseline);
  CTLineDraw(line, context);
  CGContextRestoreGState(context);
  CFRelease(line);
  CFRelease(ctFont);
}

static void DrawQueryTextTruncated(NSString *text, NSFont *font, NSColor *color,
                                   NSRect row, CGFloat x, CGFloat maxWidth) {
  if (!text.length || maxWidth <= 0) return;
  CTFontRef ctFont = CTFontCreateWithName((__bridge CFStringRef)font.fontName,
                                         font.pointSize, NULL);
  NSDictionary *attributes = @{
    (__bridge id)kCTFontAttributeName: (__bridge id)ctFont,
    (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color.CGColor
  };
  NSAttributedString *attributed = [[NSAttributedString alloc]
      initWithString:text attributes:attributes];
  CTLineRef fullLine = CTLineCreateWithAttributedString(
      (__bridge CFAttributedStringRef)attributed);
  NSAttributedString *ellipsis = [[NSAttributedString alloc]
      initWithString:@"…" attributes:attributes];
  CTLineRef token = CTLineCreateWithAttributedString(
      (__bridge CFAttributedStringRef)ellipsis);
  CTLineRef line = CTLineCreateTruncatedLine(fullLine, maxWidth,
      kCTLineTruncationEnd, token);
  CGRect bounds = CTLineGetImageBounds(line ?: fullLine, NULL);
  CGFloat baseline = NSMidY(row) -
      (CGRectGetMinY(bounds) + CGRectGetMaxY(bounds)) / 2;
  CGContextRef context = NSGraphicsContext.currentContext.CGContext;
  CGContextSaveGState(context);
  CGContextSetTextMatrix(context, CGAffineTransformIdentity);
  CGContextSetTextPosition(context, x, baseline);
  CTLineDraw(line ?: fullLine, context);
  CGContextRestoreGState(context);
  if (line) CFRelease(line);
  CFRelease(token);
  CFRelease(fullLine);
  CFRelease(ctFont);
}

static CFIndex QueryNextLineLength(CTTypesetterRef typesetter, NSString *text,
                                   CFIndex start, CGFloat width) {
  CFIndex length = CTTypesetterSuggestLineBreak(typesetter, start, width);
  if (length > 0) return length;
  return (CFIndex)[text rangeOfComposedCharacterSequenceAtIndex:
      (NSUInteger)start].length;
}

static NSUInteger QueryWrappedLineCount(NSString *text, NSFont *font,
                                        CGFloat width) {
  if (!text.length || width <= 0) return 1;
  CTFontRef ctFont = CTFontCreateWithName((__bridge CFStringRef)font.fontName,
                                         font.pointSize, NULL);
  NSAttributedString *attributed = [[NSAttributedString alloc]
      initWithString:text attributes:@{
        (__bridge id)kCTFontAttributeName: (__bridge id)ctFont
      }];
  CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString(
      (__bridge CFAttributedStringRef)attributed);
  CFIndex start = 0;
  NSUInteger count = 0;
  while (start < (CFIndex)text.length && count < 100) {
    start += QueryNextLineLength(typesetter, text, start, width);
    ++count;
  }
  CFRelease(typesetter);
  CFRelease(ctFont);
  return MAX(1, count);
}

static void DrawQueryTextWrapped(NSString *text, NSFont *font, NSColor *color,
                                 NSRect row, CGFloat x, CGFloat width,
                                 NSUInteger maxLines) {
  if (!text.length || width <= 0) return;
  CTFontRef ctFont = CTFontCreateWithName((__bridge CFStringRef)font.fontName,
                                         font.pointSize, NULL);
  NSDictionary *attributes = @{
    (__bridge id)kCTFontAttributeName: (__bridge id)ctFont,
    (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color.CGColor
  };
  NSAttributedString *attributed = [[NSAttributedString alloc]
      initWithString:text attributes:attributes];
  CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString(
      (__bridge CFAttributedStringRef)attributed);
  CGContextRef context = NSGraphicsContext.currentContext.CGContext;
  CGContextSaveGState(context);
  CGContextClipToRect(context, CGRectMake(x, NSMinY(row) + 2,
                                          width, NSHeight(row) - 4));
  CGContextSetTextMatrix(context, CGAffineTransformIdentity);
  CGFloat lineHeight = FontLineHeight(font);
  CGFloat baseline = NSMidY(row) + (maxLines - 1) * lineHeight / 2 -
      (font.ascender + font.descender) / 2;
  CFIndex start = 0;
  for (NSUInteger index = 0; index < maxLines && start < (CFIndex)text.length;
       ++index) {
    CFIndex length = QueryNextLineLength(typesetter, text, start, width);
    BOOL overflow = index + 1 == maxLines && start + length < (CFIndex)text.length;
    CTLineRef line = CTTypesetterCreateLine(typesetter,
        CFRangeMake(start, overflow ? (CFIndex)text.length - start : length));
    if (overflow) {
      NSAttributedString *ellipsis = [[NSAttributedString alloc]
          initWithString:@"…" attributes:attributes];
      CTLineRef token = CTLineCreateWithAttributedString(
          (__bridge CFAttributedStringRef)ellipsis);
      CTLineRef truncated = CTLineCreateTruncatedLine(line, width,
          kCTLineTruncationEnd, token);
      if (truncated) {
        CFRelease(line);
        line = truncated;
      }
      CFRelease(token);
    }
    CGContextSetTextPosition(context, x, baseline - index * lineHeight);
    CTLineDraw(line, context);
    CFRelease(line);
    start += length;
  }
  CGContextRestoreGState(context);
  CFRelease(typesetter);
  CFRelease(ctFont);
}

@implementation STQueryBridgeViewV4
- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSBezierPath *panelPath = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                            xRadius:11 yRadius:11];
  [QueryPanelBackgroundColor() setFill];
  [panelPath fill];
  [QueryPanelBorderColor() setStroke];
  panelPath.lineWidth = 1;
  [panelPath stroke];

  NSDictionary *numberAttributes = @{
    NSFontAttributeName: self.labelFont ?: [NSFont systemFontOfSize:12],
    NSForegroundColorAttributeName: NSColor.secondaryLabelColor
  };
  NSDictionary *textAttributes = @{
    NSFontAttributeName: self.candidateFont ?: [NSFont userFontOfSize:16],
    NSForegroundColorAttributeName: NSColor.labelColor
  };
  NSDictionary *commentAttributes = @{
    NSFontAttributeName: self.commentFont ?: [NSFont userFontOfSize:16],
    NSForegroundColorAttributeName: NSColor.secondaryLabelColor
  };

  CGFloat baseRowHeight = MAX(FontLineHeight(self.candidateFont),
                             FontLineHeight(self.commentFont)) +
      QueryCandidateRowPadding();
  CGFloat inputPadding = QueryPreeditPadding();
  CGFloat inputHeight = ceil(self.preeditFont.ascender -
                             self.preeditFont.descender + inputPadding * 2);
  NSString *preedit = self.input ?: @"";
  NSFont *preeditFont = self.preeditFont ?: [NSFont userFontOfSize:16];
  CGFloat inputAreaBottom = self.bounds.size.height -
      QueryPanelVerticalPadding() - inputHeight;
  NSRect inputRow = NSMakeRect(0, inputAreaBottom, self.bounds.size.width,
                               inputHeight);
  DrawQueryTextCentered(preedit, preeditFont, NSColor.secondaryLabelColor,
      inputRow, QueryPanelHorizontalPadding() + 8, YES);
  CGFloat rowTop = inputAreaBottom;
  for (NSUInteger index = 0; index < self.candidates.count; ++index) {
    CGFloat rowHeight = index < self.rowHeights.count ?
        self.rowHeights[index].doubleValue : baseRowHeight;
    CGFloat horizontalPadding = QueryPanelHorizontalPadding();
    NSRect row = NSMakeRect(horizontalPadding,
                            rowTop - rowHeight,
                            self.bounds.size.width - horizontalPadding * 2,
                            rowHeight);
    rowTop -= rowHeight;
    BOOL highlighted = (NSInteger)index == self.highlighted;
    if (highlighted) {
      NSRect selectionRect = NSInsetRect(row, 2, 2);
      NSBezierPath *selection = [NSBezierPath bezierPathWithRoundedRect:selectionRect
                                                                 xRadius:9 yRadius:9];
      [[QueryHighlightFillColor() colorWithAlphaComponent:0.88] setFill];
      [selection fill];
      [QueryHighlightBorderColor() setStroke];
      selection.lineWidth = 1;
      [selection stroke];
    }
    NSString *number = [NSString stringWithFormat:@"%lu.", (unsigned long)index + 1];
    NSFont *numberFont = numberAttributes[NSFontAttributeName];
    DrawQueryTextCentered(number, numberFont, NSColor.secondaryLabelColor,
        row, row.origin.x + 8, NO);
    NSString *candidate = self.candidates[index] ?: @"";
    NSFont *candidateFont = textAttributes[NSFontAttributeName];
    CGFloat candidateX = row.origin.x + 27;
    CGFloat candidateWidth = MAX(0, self.commentColumnX - candidateX -
        QueryCandidateCommentTabWidth(candidateFont));
    DrawQueryTextTruncated(candidate, candidateFont, NSColor.labelColor,
        row, candidateX, candidateWidth);
    if (index < self.comments.count && self.comments[index].length) {
      NSFont *commentFont = commentAttributes[NSFontAttributeName];
      CGFloat commentX = self.commentColumnX;
      BOOL lastCandidate = index + 1 == self.candidates.count;
      CGFloat indicatorWidth = lastCandidate && self.helpPageIndicator.length ?
          [self.helpPageIndicator sizeWithAttributes:commentAttributes].width + 8 : 0;
      CGFloat trailingSpace = lastCandidate ? 40 + indicatorWidth : 8;
      CGFloat commentWidth = self.bounds.size.width - commentX - trailingSpace;
      NSUInteger maxLines = MAX(1, 1 + (NSUInteger)lround(
          (rowHeight - baseRowHeight) / FontLineHeight(commentFont)));
      DrawQueryTextWrapped(self.comments[index], commentFont,
          NSColor.secondaryLabelColor, row, commentX, commentWidth, maxLines);
      if (lastCandidate && self.helpPageIndicator.length) {
        CGFloat pageX = self.bounds.size.width - QueryPanelHorizontalPadding() -
            28 - indicatorWidth + 8;
        DrawQueryTextTruncated(self.helpPageIndicator, commentFont,
            NSColor.secondaryLabelColor, row, pageX, indicatorWidth - 8);
      }
    }
  }
  NSRect helpCircleRect = NSInsetRect(self.helpIconRect, 5, 5);
  NSBezierPath *helpCircle = [NSBezierPath bezierPathWithOvalInRect:helpCircleRect];
  [NSColor.secondaryLabelColor setStroke];
  helpCircle.lineWidth = 1.2;
  [helpCircle stroke];
  NSFont *helpFont = self.labelFont ?: [NSFont systemFontOfSize:12];
  CGFloat infoGlyphWidth = [@"i" sizeWithAttributes:
      @{NSFontAttributeName: helpFont}].width;
  CGFloat infoGlyphX = NSMidX(helpCircleRect) - infoGlyphWidth / 2;
  DrawQueryTextCentered(@"i", helpFont, NSColor.secondaryLabelColor,
      helpCircleRect, infoGlyphX, NO);
}
@end

static STQueryBridgeViewV4 *QueryView(void) {
  return (STQueryBridgeViewV4 *)query_panel.contentView;
}

static void ToggleQueryHelp(void) {
  if (!query_active || !query_panel) return;
  if (!query_help_visible && !query_panel_position_pinned && query_panel.visible) {
    NSRect frame = query_panel.frame;
    query_panel_pinned_top_left = NSMakePoint(NSMinX(frame), NSMaxY(frame));
    query_panel_position_pinned = YES;
  }
  query_help_visible = !query_help_visible;
  query_help_page = 0;
  ShowQueryContext();
}

static void CopySelectedQueryComment(void) {
  if (!query_active || !query_panel) return;
  STQueryBridgeViewV4 *view = QueryView();
  NSInteger selected = view.highlighted;
  if (selected < 0 || selected >= (NSInteger)view.comments.count) return;
  NSString *text = view.comments[(NSUInteger)selected];
  if (!text.length) return;
  NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
  [pasteboard clearContents];
  [pasteboard setString:text forType:NSPasteboardTypeString];
}

static void CopySelectedQueryCandidate(void) {
  if (!query_active || !query_panel) return;
  STQueryBridgeViewV4 *view = QueryView();
  NSInteger selected = view.highlighted;
  if (selected < 0 || selected >= (NSInteger)view.candidates.count) return;
  NSString *text = view.candidates[(NSUInteger)selected];
  if (!text.length) return;
  NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
  [pasteboard clearContents];
  [pasteboard setString:text forType:NSPasteboardTypeString];
}

static NSString *ConfigString(RimeConfig *config, const char *key) {
  const char *value = query_api->config_get_cstring(config, key);
  return value && *value ? [NSString stringWithUTF8String:value] : nil;
}

static NSArray<NSArray<NSString *> *> *QueryHelpEntries(void) {
  NSString *defaultEngine = SearchEngineDisplayName(NO);
  NSString *secondaryEngine = SearchEngineDisplayName(YES);
  return @[
    @[@"⌃T", @"开启或关闭候选翻译"],
    @[@"⌃P", @"朗读当前候选的译文"],
    @[@"⌃Y", @"上屏当前候选的译文"],
    @[@"⇧^", @"展开或收起当前候选的完整翻译"],
    @[@"⌃⇧P", @"开启或关闭音标显示"],
    @[@"⌃G", [NSString stringWithFormat:@"%@ 搜索当前候选", defaultEngine]],
    @[@"⌃B", [NSString stringWithFormat:@"%@ 搜索当前候选", secondaryEngine]],
    @[@"⌃N", @"打开新闻扩展并搜索当前候选"],
    @[@"⌘C", @"复制当前结果信息"],
    @[@"空格", @"复制当前候选词；取色时选定颜色或重新取色"],
    @[@"ucolorRRGGBB / rgb(...) ", @"支持省略 #；方向键选格式，⌘C复制颜色值"],
    @[@"utime时间戳／时区", @"查看本地、目标时区、UTC 与 Unix 秒／毫秒"],
    @[@"udate日期..日期", @"计算两个日期相差天数；只给一个日期则与今天比较"],
    @[@"uconv5 / uconv5mi", @"进入 conv 后输入数字看常用换算；加单位看完整换算"],
    @[@"颜色取色时 ←↑↓→", @"将采样点移动一个物理像素；按空格选色"],
    @[@"数字 1–9", @"默认选候选；进入工具关键字后输入数值"],
    @[@"↑ / ↓", @"在帮助视图中翻阅条目页"],
    @[@"PageUp / PageDown", @"翻阅快捷键帮助"],
    @[@"⌘,", @"关闭快捷键帮助"],
    @[@"u<引擎>1", @"设置 ⌃G 搜索引擎，例如 ugoogle1"],
    @[@"u<引擎>2", @"设置 ⌃B 搜索引擎，例如 ubing2"],
    @[@"Esc", @"返回原候选列表"],
    @[@"点击 ⓘ", @"打开或关闭本帮助"]
  ];
}

static CGFloat ConfigSize(RimeConfig *config, const char *key, CGFloat fallback) {
  double value = 0;
  return query_api->config_get_double(config, key, &value) && value > 0 ?
      (CGFloat)value : fallback;
}

static NSFont *ThemeFont(NSString *name, CGFloat size) {
  if (name.length == 0) return [NSFont userFontOfSize:size];
  return [NSFont fontWithName:name size:size] ?: [NSFont userFontOfSize:size];
}

static void LoadSquirrelFonts(STQueryBridgeViewV4 *view) {
  if (!query_api->config_open || !query_api->config_close ||
      !query_api->config_get_cstring || !query_api->config_get_double) return;
  RimeConfig config = {0};
  if (!query_api->config_open("squirrel", &config)) return;
  BOOL dark = [[NSApp.effectiveAppearance
      bestMatchFromAppearancesWithNames:@[NSAppearanceNameDarkAqua,
                                          NSAppearanceNameAqua]]
      isEqualToString:NSAppearanceNameDarkAqua];
  NSString *schemeKey = dark ? @"style/color_scheme_dark" : @"style/color_scheme";
  NSString *scheme = ConfigString(&config, schemeKey.UTF8String);
  NSString *prefix = scheme.length && ![scheme isEqualToString:@"native"] ?
      [NSString stringWithFormat:@"preset_color_schemes/%@", scheme] : nil;
  CGFloat candidateSize = ConfigSize(&config, "style/font_point", 16);
  CGFloat labelSize = ConfigSize(&config, "style/label_font_point", candidateSize * 0.72);
  CGFloat commentSize = ConfigSize(&config, "style/comment_font_point", candidateSize * 0.90);
  CGFloat preeditSize = ConfigSize(&config, "style/preedit_font_point", candidateSize * 0.90);
  NSString *candidateName = ConfigString(&config, "style/font_face");
  NSString *labelName = ConfigString(&config, "style/label_font_face") ?: candidateName;
  NSString *commentName = ConfigString(&config, "style/comment_font_face") ?: candidateName;
  NSString *preeditName = ConfigString(&config, "style/preedit_font_face") ?: candidateName;
  if (prefix) {
    CGFloat schemeSize = ConfigSize(&config,
        [[prefix stringByAppendingString:@"/font_point"] UTF8String], candidateSize);
    candidateSize = schemeSize;
    labelSize = ConfigSize(&config,
        [[prefix stringByAppendingString:@"/label_font_point"] UTF8String], labelSize);
    commentSize = ConfigSize(&config,
        [[prefix stringByAppendingString:@"/comment_font_point"] UTF8String], commentSize);
    preeditSize = ConfigSize(&config,
        [[prefix stringByAppendingString:@"/preedit_font_point"] UTF8String], preeditSize);
    candidateName = ConfigString(&config,
        [[prefix stringByAppendingString:@"/font_face"] UTF8String]) ?: candidateName;
    labelName = ConfigString(&config,
        [[prefix stringByAppendingString:@"/label_font_face"] UTF8String]) ?: labelName;
    commentName = ConfigString(&config,
        [[prefix stringByAppendingString:@"/comment_font_face"] UTF8String]) ?: commentName;
    preeditName = ConfigString(&config,
        [[prefix stringByAppendingString:@"/preedit_font_face"] UTF8String]) ?: preeditName;
  }
  view.candidateFont = ThemeFont(candidateName, candidateSize);
  view.labelFont = ThemeFont(labelName, labelSize);
  view.commentFont = ThemeFont(commentName, commentSize);
  view.preeditFont = ThemeFont(preeditName, preeditSize);
  query_api->config_close(&config);
}

static void HideQueryPanel(void) {
  BOOL was_active = query_active;
  query_active = NO;
  query_prefix_armed = YES;
  query_help_visible = NO;
  query_help_page = 0;
  query_help_page_count = 1;
  query_panel_position_pinned = NO;
  query_time_snapshot = nil;
  AdvanceQueryGeneration();
  [query_ip_task cancel];
  query_ip_task = nil;
  query_ip_details = nil;
  query_ip_public_ip = nil;
  query_utility_highlighted = 0;
  query_search_feedback = nil;
  ++query_color_session_generation;
  query_color_sampler = nil;
  query_color_sample = nil;
  query_color_sampling_active = NO;
  query_color_sampler_started = NO;
  query_color_confirmation_pending = NO;
  query_color_cancel_pending = NO;
  query_panel.level = CGShieldingWindowLevel();
  query_copy_keyup_pending = NO;
  if (query_refresh_source) {
    dispatch_source_cancel(query_refresh_source);
    query_refresh_source = nil;
  }
  if (query_api && query_session) {
    query_api->clear_composition(query_session);
  }
  if (was_active) SetCompositionVisible(NO);
  if (query_panel) [query_panel orderOut:nil];
}

static void DisableQueryBridge(const char *reason) {
  if (query_bridge_disarmed) return;
  query_bridge_disarmed = YES;
  HideQueryPanel();

  if (query_permission_watchdog) {
    dispatch_source_cancel(query_permission_watchdog);
    query_permission_watchdog = nil;
  }
  if (query_tap) CGEventTapEnable(query_tap, false);
  if (query_tap_source) {
    CFRunLoopRemoveSource(CFRunLoopGetMain(), query_tap_source,
                          kCFRunLoopCommonModes);
    CFRelease(query_tap_source);
    query_tap_source = NULL;
  }
  if (query_tap) {
    CFMachPortInvalidate(query_tap);
    CFRelease(query_tap);
    query_tap = NULL;
  }
  if (query_api && query_session) {
    query_api->destroy_session(query_session);
    query_session = 0;
  }
  query_panel = nil;
  query_installed = NO;
  SetQueryBridgeStatus([NSString stringWithFormat:@"disarmed: %s",
      reason ?: "unknown reason"]);
  fprintf(stderr, "squirrel-query-bridge: disarmed (%s); disabled until Squirrel restart\n",
          reason ?: "unknown reason");
}

static void StartQueryPermissionWatchdog(void) {
  if (query_permission_watchdog) return;
  query_permission_watchdog = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  if (!query_permission_watchdog) return;
  dispatch_source_set_timer(query_permission_watchdog,
      dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC,
      100 * NSEC_PER_MSEC);
  dispatch_source_set_event_handler(query_permission_watchdog, ^{
    if (!query_installed) return;
    if (!AXIsProcessTrusted())
      DisableQueryBridge("accessibility permission lost");
  });
  dispatch_resume(query_permission_watchdog);
}

static void ShowQueryContext(void) {
  if (!query_api || !query_session || !query_panel ||
      query_color_sampling_active) return;
  if (!IsTimeQuery()) query_time_snapshot = nil;
  if (!IsColorQuery() && !query_color_sampling_active) {
    query_color_sample = nil;
    query_color_sampler_started = NO;
  }
  RimeContext_stdbool context = {0};
  RIME_STRUCT_INIT(RimeContext_stdbool, context);
  if (!query_api->get_context(query_session, &context)) return;

  NSMutableArray<NSString *> *candidates = [NSMutableArray array];
  NSMutableArray<NSString *> *comments = [NSMutableArray array];
  NSString *input = context.composition.preedit ?
      [NSString stringWithUTF8String:context.composition.preedit] : @"";
  int count = MIN(context.menu.num_candidates, 9);
  for (int index = 0; index < count; ++index) {
    RimeCandidate *candidate = &context.menu.candidates[index];
    [candidates addObject:candidate->text ?
        [NSString stringWithUTF8String:candidate->text] : @""];
    [comments addObject:candidate->comment ?
        [NSString stringWithUTF8String:candidate->comment] : @""];
  }
  NSInteger highlighted = context.menu.highlighted_candidate_index;
  NSInteger pageSize = context.menu.page_size > 0 ?
      MIN(context.menu.page_size, 9) : 9;
  STQueryBridgeViewV4 *view = QueryView();
  query_api->free_context(&context);

  BOOL utilityMode = QueryUtilityMode(candidates, comments, &input);
  if (utilityMode) {
    NSString *keyword = ActiveUtilityKeyword();
    if (keyword) {
      const char *label = SquirrelQueryKeywordLabel(keyword.UTF8String);
      if (label) {
        [candidates addObject:[NSString stringWithUTF8String:label]];
        [comments addObject:keyword];
      }
    }
    highlighted = MIN(query_utility_highlighted,
                      (NSInteger)candidates.count - 1);
  } else if ([query_text rangeOfCharacterFromSet:
            NSCharacterSet.decimalDigitCharacterSet].location != NSNotFound ||
           [query_text rangeOfCharacterFromSet:
            [NSCharacterSet characterSetWithCharactersInString:@".-+"]].location !=
               NSNotFound)
    input = [@"u" stringByAppendingString:query_text];
  if (query_search_feedback) {
    candidates = [NSMutableArray arrayWithObject:query_search_feedback];
    comments = [NSMutableArray arrayWithObject:@"设置已保存"];
    input = @"搜索引擎设置";
    highlighted = 0;
  }
  if (!query_help_visible && !query_search_feedback && query_text.length > 0) {
    // Utility result rows keep their values untouched. Translate only the
    // final keyword row through the dedicated local keyword path.
    NSUInteger firstTranslationIndex = utilityMode ?
        (ActiveUtilityKeyword() ? candidates.count - 1 : candidates.count) : 0;
    for (NSUInteger index = firstTranslationIndex;
         index < candidates.count; ++index) {
      NSString *candidate = candidates[index];
      NSString *word = utilityMode ? ActiveUtilityKeyword() : candidate;
      NSString *target = utilityMode ? @"tool-keyword" :
          QueryTargetForCandidate(candidate);
      if (!target) continue;
      NSString *key = QueryTranslationKey(target, word);
      NSString *translation = query_public_translations[key];
      BOOL hasTranslation =
          [comments[index] rangeOfString:@"\t"].location != NSNotFound;
      if (translation.length) {
        if (!hasTranslation) {
          comments[index] = utilityMode ? translation :
              [comments[index] stringByAppendingFormat:@"\t%@", translation];
        }
        continue;
      }
      if (hasTranslation) continue;
      SquirrelQueryTranslationRequest(word.UTF8String, target.UTF8String,
          (uint64_t)query_utility_generation, QueryTranslationDidFinish, NULL);
    }
  }
  NSString *helpPageIndicator = nil;
  if (query_help_visible) {
    NSArray<NSArray<NSString *> *> *entries = QueryHelpEntries();
    query_help_page_count = MAX(1, (NSInteger)ceil((double)entries.count / pageSize));
    query_help_page = MIN(MAX(0, query_help_page), query_help_page_count - 1);
    NSUInteger first = (NSUInteger)query_help_page * (NSUInteger)pageSize;
    NSUInteger last = MIN(entries.count, first + (NSUInteger)pageSize);
    [candidates removeAllObjects];
    [comments removeAllObjects];
    for (NSUInteger index = first; index < last; ++index) {
      [candidates addObject:entries[index][0]];
      [comments addObject:entries[index][1]];
    }
    if (query_help_page_count > 1)
      helpPageIndicator = [NSString stringWithFormat:@"%ld/%ld",
          (long)query_help_page + 1, (long)query_help_page_count];
    highlighted = 0;
  } else {
    query_help_page_count = 1;
  }
  if (!candidates.count) {
    [candidates addObject:@"·"];
    [comments addObject:@""];
  }
  BOOL changed = ![view.input isEqualToString:input] ||
      ![view.candidates isEqualToArray:candidates] ||
      ![view.comments isEqualToArray:comments] ||
      view.highlighted != highlighted ||
      ![view.helpPageIndicator isEqualToString:helpPageIndicator];
  if (!changed && query_panel.visible) return;
  view.candidates = candidates;
  view.comments = comments;
  view.input = input;
  view.highlighted = highlighted;
  view.helpPageIndicator = helpPageIndicator;
  CGFloat rowHeight = MAX(FontLineHeight(view.candidateFont),
                         FontLineHeight(view.commentFont)) +
      QueryCandidateRowPadding();
  CGFloat inputHeight = ceil(view.preeditFont.ascender -
                             view.preeditFont.descender +
                             QueryPreeditPadding() * 2);
  NSDictionary *candidateAttributes = @{ NSFontAttributeName: view.candidateFont };
  NSDictionary *commentAttributes = @{ NSFontAttributeName: view.commentFont };
  CGFloat horizontalPadding = QueryPanelHorizontalPadding();
  CGFloat widestCandidate = 0;
  CGFloat widestComment = 0;
  for (NSUInteger index = 0; index < candidates.count; ++index) {
    widestCandidate = MAX(widestCandidate,
        [candidates[index] sizeWithAttributes:candidateAttributes].width);
    widestComment = MAX(widestComment,
        [comments[index] sizeWithAttributes:commentAttributes].width);
  }
  CGFloat commentColumnX = horizontalPadding + 27 + widestCandidate +
      QueryCandidateCommentTabWidth(view.candidateFont);
  CGFloat candidateContentWidth = 27 + widestCandidate +
      (widestComment > 0 ? QueryCandidateCommentTabWidth(view.candidateFont) +
          widestComment : 0);
  CGFloat inputContentWidth = 12 +
      [input sizeWithAttributes:@{NSFontAttributeName: view.preeditFont}].width;
  CGFloat indicatorWidth = helpPageIndicator.length ?
      [helpPageIndicator sizeWithAttributes:commentAttributes].width + 8 : 0;
  CGFloat desiredWidth = MAX(180, horizontalPadding * 2 +
      MAX(candidateContentWidth, inputContentWidth) + 30 + indicatorWidth);
  NSPoint point = NSEvent.mouseLocation;
  if (query_panel_position_pinned)
    point = NSMakePoint(query_panel_pinned_top_left.x + 1,
                        query_panel_pinned_top_left.y - 1);
  NSScreen *screen = [NSScreen mainScreen];
  for (NSScreen *candidateScreen in NSScreen.screens) {
    if (NSPointInRect(point, candidateScreen.frame)) {
      screen = candidateScreen;
      break;
    }
  }
  NSRect visible = screen ? screen.visibleFrame : NSMakeRect(0, 0, 800, 600);
  CGFloat maxWidth = query_panel_position_pinned ?
      NSMaxX(visible) - query_panel_pinned_top_left.x - 12 :
      visible.size.width - 24;
  CGFloat width = MIN(desiredWidth, MAX(1, maxWidth));
  if (widestComment > 0) {
    CGFloat minimumCommentWidth = MIN(140, width * 0.35);
    commentColumnX = MIN(commentColumnX,
        width - 40 - indicatorWidth - minimumCommentWidth);
  }
  view.commentColumnX = MAX(horizontalPadding + 27, commentColumnX);
  CGFloat commentLineHeight = FontLineHeight(view.commentFont);
  NSMutableArray<NSNumber *> *naturalLines = [NSMutableArray array];
  NSMutableArray<NSNumber *> *visibleLines = [NSMutableArray array];
  for (NSUInteger index = 0; index < candidates.count; ++index) {
    BOOL lastCandidate = index + 1 == candidates.count;
    CGFloat trailingSpace = lastCandidate ? 40 + indicatorWidth : 8;
    CGFloat commentWidth = width - view.commentColumnX - trailingSpace;
    NSUInteger lines = QueryWrappedLineCount(comments[index],
        view.commentFont, commentWidth);
    [naturalLines addObject:@(lines)];
    [visibleLines addObject:@1];
  }
  CGFloat availablePanelHeight = visible.size.height - 24;
  CGFloat availableRowsHeight = availablePanelHeight -
      QueryPanelVerticalPadding() * 2 - inputHeight;
  NSInteger extraLineBudget = MAX(0, (NSInteger)floor(
      (availableRowsHeight - rowHeight * candidates.count) / commentLineHeight));
  BOOL allocated = YES;
  while (extraLineBudget > 0 && allocated) {
    allocated = NO;
    for (NSUInteger index = 0; index < candidates.count && extraLineBudget > 0;
         ++index) {
      if (visibleLines[index].unsignedIntegerValue >=
          naturalLines[index].unsignedIntegerValue) continue;
      visibleLines[index] = @(visibleLines[index].unsignedIntegerValue + 1);
      --extraLineBudget;
      allocated = YES;
    }
  }
  NSMutableArray<NSNumber *> *rowHeights = [NSMutableArray array];
  CGFloat totalRowsHeight = 0;
  for (NSNumber *lines in visibleLines) {
    CGFloat measuredHeight = rowHeight +
        (lines.unsignedIntegerValue - 1) * commentLineHeight;
    [rowHeights addObject:@(measuredHeight)];
    totalRowsHeight += measuredHeight;
  }
  view.rowHeights = rowHeights;
  CGFloat height = QueryPanelVerticalPadding() * 2 + inputHeight +
      MAX(rowHeight, totalRowsHeight);
  CGFloat lastRowHeight = rowHeights.lastObject.doubleValue;
  view.helpIconRect = NSMakeRect(width - horizontalPadding - 28,
      QueryPanelVerticalPadding() + (lastRowHeight - 28) / 2,
      28, 28);
  [view setFrameSize:NSMakeSize(width, height)];
  [query_panel setContentSize:NSMakeSize(width, height)];
  CGFloat originX;
  CGFloat originY;
  if (query_panel_position_pinned) {
    originX = query_panel_pinned_top_left.x;
    originY = MAX(query_panel_pinned_top_left.y - height,
                  NSMinY(visible) + 12);
  } else {
    originX = MIN(MAX(point.x + 12, NSMinX(visible) + 12),
                  NSMaxX(visible) - width - 12);
    originY = MIN(MAX(point.y - height - 12, NSMinY(visible) + 12),
                  NSMaxY(visible) - height - 12);
  }
  [query_panel setFrameOrigin:NSMakePoint(originX, originY)];
  if (query_active && !query_panel_position_pinned) {
    NSRect frame = query_panel.frame;
    query_panel_pinned_top_left = NSMakePoint(NSMinX(frame), NSMaxY(frame));
    query_panel_position_pinned = YES;
  }
  [view setNeedsDisplay:YES];
  [query_panel orderFrontRegardless];
  if (IsBareColorQuery() && !query_color_sampler_started) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
      StartQueryColorSampling();
    });
  }
}

static BOOL ProcessQueryKey(int keycode) {
  if (!query_api || !query_session) return NO;
  BOOL handled = query_api->process_key(query_session, keycode, 0);
  ShowQueryContext();
  return handled;
}

static void ConfigureQuerySession(RimeSessionId session) {
  if (query_api->set_option)
    query_api->set_option(session, "ascii_mode", NO);
  query_api->set_property(session, "client_app",
                          "org.owllinker.SquirrelTranslate.InputBar");
  query_api->set_property(session, "_translation_query_all_candidates", "1");
  char generation[64];
  snprintf(generation, sizeof(generation), "%.6f", CFAbsoluteTimeGetCurrent());
  query_api->set_property(session, "_translation_cache_generation", generation);
}

static BOOL EnsureQuerySession(void) {
  if (!query_api || !query_api->create_session) return NO;
  if (query_session && RIME_PROVIDED(query_api, find_session) &&
      query_api->find_session(query_session))
    return YES;
  if (query_session && query_api->destroy_session)
    query_api->destroy_session(query_session);
  query_session = query_api->create_session();
  if (!query_session) return NO;
  ConfigureQuerySession(query_session);
  return YES;
}

static BOOL SetQueryInput(NSString *input) {
  return query_api && RIME_PROVIDED(query_api, set_input) && query_session &&
      query_api->set_input(query_session, input.UTF8String);
}

static BOOL FeedQueryInputByKeys(RimeSessionId session, NSString *input) {
  if (!query_api || !query_api->process_key) return NO;
  for (NSUInteger index = 0; index < input.length; ++index) {
    unichar character = [input characterAtIndex:index];
    if (character > 0x7f || !query_api->process_key(session, (int)character, 0))
      return NO;
  }
  return YES;
}

static BOOL RebuildQuerySession(void) {
  if (!query_api || !query_active) return NO;
  NSInteger selectedIndex = 0;
  RimeContext_stdbool previousContext = {0};
  RIME_STRUCT_INIT(RimeContext_stdbool, previousContext);
  if (query_api->get_context(query_session, &previousContext)) {
    selectedIndex = MAX(0, previousContext.menu.page_no) *
        MAX(1, previousContext.menu.page_size) +
        MAX(0, previousContext.menu.highlighted_candidate_index);
    query_api->free_context(&previousContext);
  }
  RimeSessionId replacement = query_api->create_session();
  if (!replacement) return NO;
  // Query sessions are independent of the user's active Rime context. Keep
  // this private surface in Chinese mode even if the saved default is ASCII.
  ConfigureQuerySession(replacement);
  RimeSessionId previous = query_session;
  query_session = replacement;
  // set_input avoids depending on a synthetic `u` key being accepted by the
  // schema's processor chain. The launch prefix is only a trigger; the query
  // composition itself contains the user's text, not that prefix.
  NSString *sessionInput = query_text.length ? query_text : @"u";
  BOOL inputSet = RIME_PROVIDED(query_api, set_input) &&
      query_api->set_input(query_session, sessionInput.UTF8String);
  if (!inputSet) {
    inputSet = query_api->process_key(query_session, 'u', 0) &&
        (!query_text.length || FeedQueryInputByKeys(query_session, query_text));
  }
  if (!inputSet) {
    query_api->destroy_session(query_session);
    query_session = previous;
    return NO;
  }
  if (query_api->highlight_candidate && selectedIndex > 0)
    query_api->highlight_candidate(query_session, (size_t)selectedIndex);
  query_api->destroy_session(previous);
  ShowQueryContext();
  return YES;
}

static void RemoveLastQueryCharacter(void) {
  if (query_text.length) {
    NSRange lastCharacter = [query_text
        rangeOfComposedCharacterSequenceAtIndex:query_text.length - 1];
    [query_text deleteCharactersInRange:lastCharacter];
  }
  if (!query_text.length) {
    // Keep the prefix panel available for another query after deleting the
    // final typed letter; Rime rebuild resets both its composition and Lua env.
  }
  AdvanceQueryGeneration();
  [query_ip_task cancel];
  query_ip_task = nil;
  query_ip_details = nil;
  query_ip_public_ip = nil;
  query_utility_highlighted = 0;
  BOOL completeIP = NO;
  if ([query_text isEqualToString:@"ip"]) ScheduleIPLookup(nil);
  else if (IPv4QueryStatus(SpecificIPInput(), &completeIP) && completeIP)
    ScheduleIPLookup(SpecificIPInput());
  RebuildQuerySession();
  ShowQueryContext();
}

static void PasteQueryText(void) {
  if (!query_active) return;
  NSString *pasted = [NSPasteboard.generalPasteboard
      stringForType:NSPasteboardTypeString];
  if (!pasted.length) return;
  NSMutableString *normalized = [NSMutableString string];
  for (NSUInteger index = 0; index < pasted.length; ++index) {
    unichar character = [pasted characterAtIndex:index];
    if (character == '\r' || character == '\n' || character == '\t')
      character = ' ';
    if ([[NSCharacterSet controlCharacterSet] characterIsMember:character])
      continue;
    [normalized appendFormat:@"%C", character];
  }
  if (!normalized.length) return;
  query_search_feedback = nil;
  [query_text appendString:normalized];
  query_utility_highlighted = 0;
  query_last_key_time = CFAbsoluteTimeGetCurrent();
  AdvanceQueryGeneration();
  [query_ip_task cancel];
  query_ip_task = nil;
  query_ip_details = nil;
  query_ip_public_ip = nil;
  if (RebuildQuerySession()) {
    NSString *feedback = ConfigureQuerySearchEngine(query_text);
    if (feedback) {
      query_text = [NSMutableString string];
      query_search_feedback = feedback;
      RebuildQuerySession();
    } else {
      BOOL completeIP = NO;
      if ([query_text isEqualToString:@"ip"]) ScheduleIPLookup(nil);
      else if (IPv4QueryStatus(SpecificIPInput(), &completeIP) && completeIP)
        ScheduleIPLookup(SpecificIPInput());
    }
    ShowQueryContext();
  }
}

static BOOL TranslationCacheChanged(void) {
  NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:
      @"Library/Rime/input_translation.cache.tsv"];
  struct stat info;
  if (stat(path.fileSystemRepresentation, &info) != 0) return NO;
  BOOL changed = info.st_size != query_cache_size ||
      info.st_mtimespec.tv_sec != query_cache_mtime.tv_sec ||
      info.st_mtimespec.tv_nsec != query_cache_mtime.tv_nsec;
  if (changed) {
    query_cache_size = info.st_size;
    query_cache_mtime = info.st_mtimespec;
  }
  return changed;
}

static void StartQueryRefresh(void) {
  if (query_refresh_source) return;
  query_refresh_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                 0, 0,
                                                 dispatch_get_main_queue());
  dispatch_source_set_timer(query_refresh_source,
      dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
      150 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
  dispatch_source_set_event_handler(query_refresh_source, ^{
    if (!query_active) return;
    if (TranslationCacheChanged() &&
        CFAbsoluteTimeGetCurrent() - query_last_key_time > 0.35) {
      RebuildQuerySession();
    } else {
      ShowQueryContext();
    }
  });
  dispatch_resume(query_refresh_source);
}

static BOOL StartQuery(void) {
  if (!EnsureQuerySession()) {
    SetQueryBridgeStatus(@"prefix rejected: Rime session unavailable");
    return NO;
  }
  query_text = [NSMutableString string];
  BOOL inputSet = RIME_PROVIDED(query_api, set_input) &&
      query_api->set_input(query_session, "u");
  if (!inputSet) inputSet = ProcessQueryKey('u');
  if (!inputSet) {
    SetQueryBridgeStatus(@"prefix rejected: Rime input APIs failed");
    return NO;
  }
  query_active = YES;
  SetCompositionVisible(YES);
  AdvanceQueryGeneration();
  query_color_sample = nil;
  query_color_sampler_started = NO;
  query_last_key_time = CFAbsoluteTimeGetCurrent();
  TranslationCacheChanged();
  StartQueryRefresh();
  ShowQueryContext();
  [query_panel orderFrontRegardless];
  SetQueryBridgeStatus(@"panel requested");
  return YES;
}

static CGEventRef QueryEventTap(CGEventTapProxy proxy, CGEventType type,
                                CGEventRef event, void *context) {
  (void)proxy; (void)context;
  if (type == kCGEventTapDisabledByTimeout ||
      type == kCGEventTapDisabledByUserInput) {
    // A timeout may be recovered only while permission is still granted.
    // A user-disabled tap, or any tap disabled after TCC revocation, is
    // fail-closed and requires a Squirrel restart after permission recovery.
    BOOL accessibilityTrusted = AXIsProcessTrusted();
    if (type == kCGEventTapDisabledByTimeout && accessibilityTrusted && query_tap) {
      CGEventTapEnable(query_tap, true);
    } else {
      dispatch_async(dispatch_get_main_queue(), ^{
        DisableQueryBridge(accessibilityTrusted ?
            "event tap disabled by system or user" :
            "accessibility permission lost");
      });
    }
    return event;
  }
  if (query_color_sampling_active &&
      (type == kCGEventKeyDown || type == kCGEventKeyUp)) {
    CGKeyCode keycode = (CGKeyCode)CGEventGetIntegerValueField(
        event, kCGKeyboardEventKeycode);
    NSUInteger flags = CGEventGetFlags(event);
    BOOL commandDown = (flags & kCGEventFlagMaskCommand) != 0;
    BOOL optionDown = (flags & kCGEventFlagMaskAlternate) != 0;
    BOOL controlDown = (flags & kCGEventFlagMaskControl) != 0;
    BOOL systemEscapeShortcut =
        (commandDown && (keycode == kVK_Tab || keycode == kVK_Space)) ||
        (commandDown && optionDown && keycode == kVK_Escape) ||
        (controlDown && (keycode == kVK_LeftArrow ||
                         keycode == kVK_RightArrow ||
                         keycode == kVK_UpArrow ||
                         keycode == kVK_DownArrow));
    if (systemEscapeShortcut) return event;
    BOOL plainArrow =
        (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                  kCGEventFlagMaskAlternate | kCGEventFlagMaskShift)) == 0;
    if (type == kCGEventKeyDown &&
        (keycode == kVK_Escape || keycode == kVK_Space) &&
        CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat))
      return NULL;
    if (keycode == kVK_Escape) {
      if (type == kCGEventKeyUp) {
        query_escape_keyup_pending = NO;
        return NULL;
      }
      if (type == kCGEventKeyDown && plainArrow) {
        query_escape_keyup_pending = YES;
        query_color_cancel_pending = YES;
        // Escape supersedes a pending Space confirmation if its click stalled.
        query_color_confirmation_pending = YES;
        NSUInteger session = query_color_session_generation;
        dispatch_async(dispatch_get_main_queue(), ^{
          if (session == query_color_session_generation)
            ConfirmColorSampleAtCursor();
        });
        return NULL;
      }
      return event;
    }
    if (keycode == kVK_Space) {
      if (type == kCGEventKeyUp) query_space_keyup_pending = NO;
      if (type == kCGEventKeyDown && plainArrow) {
        query_color_cancel_pending = NO;
        // Arrow keys only position the sampler; physical Space selects once.
        query_color_confirmation_pending = YES;
        query_space_keyup_pending = YES;
        NSUInteger session = query_color_session_generation;
        dispatch_async(dispatch_get_main_queue(), ^{
          if (session == query_color_session_generation)
            ConfirmColorSampleAtCursor();
        });
      }
      return NULL;
    }
    if (type == kCGEventKeyDown && plainArrow &&
        (keycode == kVK_LeftArrow || keycode == kVK_RightArrow ||
         keycode == kVK_UpArrow || keycode == kVK_DownArrow)) {
      CGPoint eventPosition = CGEventGetLocation(event);
      NSUInteger session = query_color_session_generation;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (session == query_color_session_generation &&
            query_color_sampling_active && !query_color_confirmation_pending)
          MoveColorSampleCursor(keycode, eventPosition);
      });
      return NULL;
    }
    // Keep ordinary keystrokes from leaking into the app underneath.
    return NULL;
  }
  if (type == kCGEventMouseMoved && query_color_sampling_active) {
    query_color_cursor_position = CGEventGetLocation(event);
    query_color_cursor_position_valid = YES;
    return event;
  }
  if (type == kCGEventKeyUp) {
    CGKeyCode released = (CGKeyCode)CGEventGetIntegerValueField(
        event, kCGKeyboardEventKeycode);
    if (released == kVK_ANSI_C && query_copy_keyup_pending) {
      query_copy_keyup_pending = NO;
      return NULL;
    }
    if (released == kVK_Space && query_space_keyup_pending) {
      query_space_keyup_pending = NO;
      return NULL;
    }
    if (released == kVK_ANSI_V && query_paste_keyup_pending) {
      query_paste_keyup_pending = NO;
      return NULL;
    }
    if (query_search_keyup_pending && released == query_search_keyup_pending) {
      query_search_keyup_pending = 0;
      return NULL;
    }
    if (released == kVK_Escape && query_escape_keyup_pending) {
      query_escape_keyup_pending = NO;
      return NULL;
    }
    if (released == kVK_ANSI_Comma && query_help_keyup_pending) {
      query_help_keyup_pending = NO;
      return NULL;
    }
    if (released < 64 &&
        (query_number_keyup_pending & (UINT64_C(1) << released))) {
      query_number_keyup_pending &= ~(UINT64_C(1) << released);
      return NULL;
    }
    if (query_active && query_help_visible) return NULL;
    return event;
  }
  if (type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown ||
      type == kCGEventOtherMouseDown) {
    if (query_color_sampling_active) {
      if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) !=
          kQueryColorSyntheticClickMarker)
        query_color_cancel_pending = NO;
      return event;
    }
    if (!query_active) query_prefix_armed = YES;
    if (type == kCGEventLeftMouseDown && query_active && query_panel &&
        query_panel.visible) {
      NSPoint screenPoint = NSEvent.mouseLocation;
        NSPoint localPoint = [query_panel convertPointFromScreen:screenPoint];
      if (NSPointInRect(localPoint, QueryView().helpIconRect)) {
        dispatch_async(dispatch_get_main_queue(), ^{
          ToggleQueryHelp();
        });
        return NULL;
      }
    }
    if (query_active && query_panel &&
        !NSPointInRect(NSEvent.mouseLocation, query_panel.frame)) {
      HideQueryPanel();
    }
    return event;
  }
  if (type != kCGEventKeyDown) return event;

  NSUInteger flags = CGEventGetFlags(event);
  CGKeyCode keycode = (CGKeyCode)CGEventGetIntegerValueField(
      event, kCGKeyboardEventKeycode);
  if (query_active && keycode == kVK_Space && query_space_keyup_pending &&
      CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat))
    return NULL;
  if (query_active && keycode == kVK_ANSI_Comma &&
      (flags & kCGEventFlagMaskCommand) &&
      !(flags & (kCGEventFlagMaskControl | kCGEventFlagMaskAlternate |
                 kCGEventFlagMaskShift))) {
    query_help_keyup_pending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
      ToggleQueryHelp();
    });
    return NULL;
  }
  if (query_active && keycode == kVK_ANSI_C &&
      (flags & kCGEventFlagMaskCommand) &&
      (flags & (kCGEventFlagMaskControl | kCGEventFlagMaskAlternate |
                kCGEventFlagMaskShift)) == 0) {
    query_copy_keyup_pending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ CopySelectedQueryComment(); });
    return NULL;
  }
  if (query_active && IsBareColorQuery() && keycode == kVK_Space &&
      (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                kCGEventFlagMaskAlternate | kCGEventFlagMaskShift)) == 0) {
    query_space_keyup_pending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
      query_color_sampler_started = NO;
      StartQueryColorSampling();
    });
    return NULL;
  }
  if (query_active && query_help_visible) {
    if (keycode == kVK_Escape &&
        (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                  kCGEventFlagMaskAlternate | kCGEventFlagMaskShift)) == 0) {
      query_escape_keyup_pending = YES;
      dispatch_async(dispatch_get_main_queue(), ^{ ToggleQueryHelp(); });
      return NULL;
    }
    BOOL plainNavigation =
        (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                  kCGEventFlagMaskAlternate | kCGEventFlagMaskShift)) == 0;
    if (plainNavigation &&
        (keycode == kVK_UpArrow || keycode == kVK_DownArrow ||
         keycode == kVK_PageUp || keycode == kVK_PageDown)) {
      NSInteger direction = (keycode == kVK_UpArrow || keycode == kVK_PageUp) ? -1 : 1;
      dispatch_async(dispatch_get_main_queue(), ^{
        query_help_page = MIN(MAX(0, query_help_page + direction),
                              query_help_page_count - 1);
        ShowQueryContext();
      });
      return NULL;
    }
    return NULL;
  }
  if (query_active && keycode == kVK_Space &&
      (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                kCGEventFlagMaskAlternate | kCGEventFlagMaskShift)) == 0) {
    query_space_keyup_pending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
      CopySelectedQueryCandidate();
    });
    return NULL;
  }
  if (query_active && keycode == kVK_ANSI_V &&
      (flags & kCGEventFlagMaskCommand) &&
      (flags & (kCGEventFlagMaskControl | kCGEventFlagMaskAlternate |
                kCGEventFlagMaskShift)) == 0) {
    query_paste_keyup_pending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ PasteQueryText(); });
    return NULL;
  }
  if (query_active && (keycode == kVK_ANSI_G || keycode == kVK_ANSI_B) &&
      (flags & kCGEventFlagMaskControl) &&
      !(flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate |
                 kCGEventFlagMaskShift))) {
    query_search_keyup_pending = keycode;
    dispatch_async(dispatch_get_main_queue(), ^{ OpenQuerySearch(keycode); });
    return NULL;
  }
  if (query_active && keycode == kVK_ANSI_N &&
      (flags & kCGEventFlagMaskControl) &&
      !(flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate |
                 kCGEventFlagMaskShift))) {
    query_search_keyup_pending = keycode;
    dispatch_async(dispatch_get_main_queue(), ^{ OpenQueryNews(); });
    return NULL;
  }
  if (query_active && keycode == kVK_Escape &&
      (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                kCGEventFlagMaskAlternate | kCGEventFlagMaskShift)) == 0) {
    query_escape_keyup_pending = YES;
    HideQueryPanel();
    return NULL;
  }
  if (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl)) return event;
  if (flags & kCGEventFlagMaskAlternate) {
    UniChar optionCharacters[4] = {0};
    UniCharCount optionLength = 0;
    CGEventKeyboardGetUnicodeString(event, 4, &optionLength, optionCharacters);
    if (!query_active || !IsKeywordInputMode() || optionLength != 1 ||
        optionCharacters[0] != 0x00b0) return event;
  }
  if (query_active && keycode == kVK_Delete) {
    dispatch_async(dispatch_get_main_queue(), ^{
      RemoveLastQueryCharacter();
      query_last_key_time = CFAbsoluteTimeGetCurrent();
    });
    return NULL;
  }
  if (query_active && keycode == kVK_ForwardDelete) {
    dispatch_async(dispatch_get_main_queue(), ^{
      RemoveLastQueryCharacter();
      query_last_key_time = CFAbsoluteTimeGetCurrent();
    });
    return NULL;
  }
  if (query_active) {
    NSInteger utilityCount = QueryUtilityCandidateCount();
    if (utilityCount > 0 &&
        (keycode == kVK_UpArrow || keycode == kVK_DownArrow)) {
      dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger step = keycode == kVK_DownArrow ? 1 : -1;
        query_utility_highlighted =
            (query_utility_highlighted + utilityCount + step) % utilityCount;
        ShowQueryContext();
      });
      return NULL;
    }
    int navigationKey = 0;
    switch (keycode) {
      case kVK_UpArrow: navigationKey = 0xff52; break;       // XK_Up
      case kVK_DownArrow: navigationKey = 0xff54; break;     // XK_Down
      case kVK_PageUp: navigationKey = 0xff55; break;        // XK_Page_Up
      case kVK_PageDown: navigationKey = 0xff56; break;      // XK_Page_Down
      case kVK_LeftArrow: navigationKey = 0xff51; break;     // XK_Left
      case kVK_RightArrow: navigationKey = 0xff53; break;    // XK_Right
      default: break;
    }
    if (navigationKey) {
      dispatch_async(dispatch_get_main_queue(), ^{
        ProcessQueryKey(navigationKey);
        query_last_key_time = CFAbsoluteTimeGetCurrent();
      });
      return NULL;
    }
  }
  UniChar characters[4] = {0};
  UniCharCount length = 0;
  CGEventKeyboardGetUnicodeString(event, 4, &length, characters);
  if (!length) return event;

  unichar character = characters[0];
  BOOL plainDigit = character >= '0' && character <= '9' &&
      !(flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                 kCGEventFlagMaskAlternate | kCGEventFlagMaskShift));
  if (query_active && plainDigit && !IsKeywordInputMode()) {
    if (keycode < 64)
      query_number_keyup_pending |= UINT64_C(1) << keycode;
    NSInteger rowIndex = (NSInteger)(character - '1');
    if (character != '0') {
      RimeContext_stdbool context = {0};
      RIME_STRUCT_INIT(RimeContext_stdbool, context);
      BOOL hasContext = query_api->get_context(query_session, &context);
      NSInteger rowCount = hasContext ? MIN(context.menu.num_candidates, 9) : 0;
      if (rowIndex < rowCount) {
        dispatch_async(dispatch_get_main_queue(), ^{
          RimeContext_stdbool current = {0};
          RIME_STRUCT_INIT(RimeContext_stdbool, current);
          if (query_api->get_context(query_session, &current)) {
            NSInteger pageSize = MAX(1, current.menu.page_size);
            NSInteger selectedIndex =
                MAX(0, current.menu.page_no) * pageSize + rowIndex;
            if (query_api->highlight_candidate)
              query_api->highlight_candidate(query_session,
                                              (size_t)selectedIndex);
            query_api->free_context(&current);
          }
          ShowQueryContext();
        });
      }
      if (hasContext) query_api->free_context(&context);
    }
    return NULL;
  }
  if (!query_active && character >= 0x20 && character != 0x7f) {
    if (character == 'u' && !query_prefix_armed) return event;
    query_prefix_armed = NO;
  }
  if (!query_active && character == 'u') {
    if (!IsSquirrelInputSource()) {
      dispatch_async(dispatch_get_main_queue(), ^{
        SetQueryBridgeStatus(@"u ignored: input source is not Squirrel");
      });
      return event;
    }
    STFocusedElementState focus = FocusedElementState();
    if (focus != STFocusedElementNotEditable) {
      NSString *state = focus == STFocusedElementEditable ?
          @"u ignored: editable focus" :
          [NSString stringWithFormat:@"u ignored: focus unknown (AXError %d)",
                                     (int)query_last_focus_error];
      dispatch_async(dispatch_get_main_queue(), ^{
        SetQueryBridgeStatus(state);
      });
      return event;
    }
    // Start synchronously in this main-run-loop tap callback: only consume the
    // physical `u` after Rime has accepted it. If the private session rejects
    // it, let the original event continue to Squirrel instead of swallowing it.
    return StartQuery() ? NULL : event;
  }
  if (!query_active) return event;
  BOOL keywordInput = IsKeywordInputMode();
  if ((character >= 'a' && character <= 'z') ||
      (keywordInput && ((character >= 0x21 && character <= 0x7e) ||
                        character == 0x00b0))) {
    if (character >= '0' && character <= '9') {
      if (keycode < 64)
        query_number_keyup_pending |= UINT64_C(1) << keycode;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      query_search_feedback = nil;
      [query_text appendFormat:@"%C", character];
      query_utility_highlighted = 0;
      query_last_key_time = CFAbsoluteTimeGetCurrent();
      AdvanceQueryGeneration();
      NSString *feedback = ConfigureQuerySearchEngine(query_text);
      if (feedback) {
        query_text = [NSMutableString string];
        query_search_feedback = feedback;
        RebuildQuerySession();
        ShowQueryContext();
        return;
      }
      BOOL inputSet = SetQueryInput(query_text);
      if (!inputSet) inputSet = ProcessQueryKey((int)character);
      if (!inputSet) {
        NSRange lastCharacter = [query_text
            rangeOfComposedCharacterSequenceAtIndex:query_text.length - 1];
        [query_text deleteCharactersInRange:lastCharacter];
        SetQueryBridgeStatus(@"query input rejected by Rime");
        return;
      }
      BOOL completeIP = NO;
      if ([query_text isEqualToString:@"ip"]) ScheduleIPLookup(nil);
      else if (IPv4QueryStatus(SpecificIPInput(), &completeIP) && completeIP)
        ScheduleIPLookup(SpecificIPInput());
      else {
        [query_ip_task cancel];
        query_ip_task = nil;
        query_ip_details = nil;
      }
      ShowQueryContext();
    });
    return NULL;
  }
  return event;
}

static void InstallQueryBridge(void);

static void RetryInstall(void) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{ InstallQueryBridge(); });
}

static void InstallQueryBridge(void) {
  if (query_installed || !QueryEnabled()) {
    if (!QueryEnabled()) SetQueryBridgeStatus(@"disabled: enable marker missing");
    return;
  }
  // The grant belongs to Squirrel, not the former standalone helper. Wait
  // before allocating a session/window so retries do not leak either one.
  if (!AXIsProcessTrusted()) {
    SetQueryBridgeStatus(@"waiting: Squirrel accessibility permission");
    RetryInstall();
    return;
  }
  query_api = rime_get_api_stdbool();
  if (!query_api || !query_api->create_session || !query_api->process_key) {
    SetQueryBridgeStatus(@"waiting: Rime API unavailable");
    RetryInstall();
    return;
  }
  STQueryBridgeViewV4 *view = [STQueryBridgeViewV4 new];
  LoadSquirrelFonts(view);
  query_panel = [[NSPanel alloc]
      initWithContentRect:NSMakeRect(0, 0, 560, 30)
      styleMask:NSWindowStyleMaskNonactivatingPanel
      backing:NSBackingStoreBuffered defer:NO];
  query_panel.opaque = NO;
  query_panel.backgroundColor = [NSColor clearColor];
  query_panel.level = CGShieldingWindowLevel();
  query_panel.hidesOnDeactivate = NO;
  query_panel.becomesKeyOnlyIfNeeded = YES;
  query_panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
      NSWindowCollectionBehaviorFullScreenAuxiliary;
  query_panel.ignoresMouseEvents = YES;
  query_panel.hasShadow = YES;
  query_panel.contentView = view;

  CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) |
      CGEventMaskBit(kCGEventKeyUp) |
      CGEventMaskBit(kCGEventMouseMoved) |
      CGEventMaskBit(kCGEventLeftMouseDown) |
      CGEventMaskBit(kCGEventRightMouseDown) |
      CGEventMaskBit(kCGEventOtherMouseDown);
  query_tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                               kCGEventTapOptionDefault, mask,
                               QueryEventTap, NULL);
  if (!query_tap) {
    SetQueryBridgeStatus(@"failed: event tap unavailable");
    fprintf(stderr, "squirrel-query-bridge: event_tap_unavailable\n");
    query_api->destroy_session(query_session);
    query_session = 0;
    query_panel = nil;
    RetryInstall();
    return;
  }
  query_tap_source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,
                                                   query_tap, 0);
  if (!query_tap_source) {
    CFMachPortInvalidate(query_tap);
    CFRelease(query_tap);
    query_tap = NULL;
    query_api->destroy_session(query_session);
    query_session = 0;
    query_panel = nil;
    SetQueryBridgeStatus(@"failed: event tap source unavailable");
    RetryInstall();
    return;
  }
  CFRunLoopAddSource(CFRunLoopGetMain(), query_tap_source,
                     kCFRunLoopCommonModes);
  CGEventTapEnable(query_tap, true);
  query_installed = YES;
  SetQueryBridgeStatus(@"installed: event tap active; waiting for u");
  StartQueryPermissionWatchdog();
  fprintf(stderr, "squirrel-query-bridge: installed\n");
}

__attribute__((constructor)) static void QueryBridgeConstructor(void) {
  if (!QueryEnabled()) {
    SetQueryBridgeStatus(@"disabled: enable marker missing");
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSApplication sharedApplication];
    InstallQueryBridge();
  });
}
