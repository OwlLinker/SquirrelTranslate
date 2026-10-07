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
static NSInteger query_help_selected;
static NSArray<NSDictionary *> *query_paging_bindings;
static NSMutableIndexSet *query_paging_keyup_pending;
static BOOL query_panel_position_pinned;
static NSPoint query_panel_pinned_top_left;
static CGKeyCode query_search_keyup_pending;
static NSMutableString *query_text;
static NSDate *query_time_snapshot;
static struct timespec query_cache_mtime;
static off_t query_cache_size = -1;
static BOOL query_cache_refresh_pending;
static CFAbsoluteTime query_last_key_time;
static BOOL query_prefix_armed = YES;
static CGFloat query_panel_max_width = 400;
static BOOL query_panel_max_width_loaded;
static NSString *query_ui_language;
static NSUInteger query_panel_width_command_generation;
static NSUInteger query_floor_height_command_generation;
static double query_floor_height = 3.0;
static BOOL query_floor_height_loaded;
static NSUInteger query_fire_pressure_command_generation;
static double query_fire_static_pressure_mpa[3] = {0.10, 0.07, 0.01};
static BOOL query_fire_static_pressure_loaded;
static NSString *query_ip_details;
static NSString *query_ip_public_ip;
static NSURLSessionDataTask *query_ip_task;
static NSURLSessionDataTask *query_currency_task;
static NSString *query_currency_payload;
static NSArray<NSArray<NSString *> *> *query_currency_rows;
static NSMutableDictionary<NSString *, NSDictionary *> *query_currency_rate_cache;
static NSUInteger query_utility_generation;
static NSData *query_phone_data;
static BOOL query_phone_prefix_active;
static NSInteger query_utility_highlighted;
static NSString *query_search_feedback;
static NSString *query_search_feedback_title;
static NSMutableDictionary<NSString *, NSString *> *query_public_translations;
static NSMutableDictionary<NSString *, NSString *> *query_public_translation_texts;
static NSMutableArray<NSString *> *query_public_translation_order;
static NSSpeechSynthesizer *query_speech_synthesizer;
static unichar query_repeat_action_character;
static NSUInteger query_repeat_action_count;
static NSString *query_repeat_action_base_text;
static NSString *query_repeat_action_candidate;
static CGKeyCode query_repeat_action_tail_keycode;
static CFAbsoluteTime query_repeat_action_tail_deadline;
typedef NS_ENUM(NSUInteger, STQueryTranslationAction) {
  STQueryTranslationActionNone,
  STQueryTranslationActionCopy,
  STQueryTranslationActionSpeak,
};
static STQueryTranslationAction query_pending_translation_action;
static NSString *query_pending_translation_candidate;
static NSUInteger query_pending_translation_generation;
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
static void HideQueryPanel(void);
static NSString *SelectedQueryCandidate(void);
static BOOL SetQueryInput(NSString *input);
static void ResetQueryRepeatAction(void);
static void PerformQueryTranslationAction(STQueryTranslationAction action,
                                         NSString *translation);

static void AdvanceQueryGeneration(void) {
  query_pending_translation_action = STQueryTranslationActionNone;
  query_pending_translation_candidate = nil;
  [query_currency_task cancel];
  query_currency_task = nil;
  query_currency_payload = nil;
  query_currency_rows = nil;
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
  NSString *translationText = [result copy];
  NSString *phoneticValue = phonetic && phonetic[0] ?
      [NSString stringWithUTF8String:phonetic] : nil;
  if (!wordValue.length || !targetValue.length || !result.length) return;
  if (phoneticValue.length) [result appendFormat:@"  /%@/", phoneticValue];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!query_active || generation != query_utility_generation) return;
    if (!query_public_translations) {
      query_public_translations = [NSMutableDictionary dictionary];
      query_public_translation_texts = [NSMutableDictionary dictionary];
      query_public_translation_order = [NSMutableArray array];
    }
    NSString *key = QueryTranslationKey(targetValue, wordValue);
    if (!query_public_translations[key])
      [query_public_translation_order addObject:key];
    query_public_translations[key] = result;
    query_public_translation_texts[key] = translationText;
    BOOL closeAfterPendingAction = NO;
    if (query_pending_translation_action != STQueryTranslationActionNone &&
        query_pending_translation_generation == generation &&
        [query_pending_translation_candidate isEqualToString:wordValue]) {
      STQueryTranslationAction action = query_pending_translation_action;
      query_pending_translation_action = STQueryTranslationActionNone;
      query_pending_translation_candidate = nil;
      PerformQueryTranslationAction(action, translationText);
      closeAfterPendingAction = YES;
    }
    while (query_public_translation_order.count > 400) {
      NSString *oldest = query_public_translation_order.firstObject;
      [query_public_translation_order removeObjectAtIndex:0];
      [query_public_translations removeObjectForKey:oldest];
      [query_public_translation_texts removeObjectForKey:oldest];
    }
    ShowQueryContext();
    if (closeAfterPendingAction) HideQueryPanel();
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

static NSString *QueryPanelWidthProfilePath(void) {
  return [@"~/Library/Rime/input_translation.query_panel_max_width"
      stringByExpandingTildeInPath];
}

static NSString *QueryFloorHeightProfilePath(void) {
  return [@"~/Library/Rime/input_translation.floor_height"
      stringByExpandingTildeInPath];
}

static NSString *QueryFireStaticPressureProfilePath(void) {
  return [@"~/Library/Rime/input_translation.fire_static_pressure"
      stringByExpandingTildeInPath];
}

static void LoadFireStaticPressureDefaults(void) {
  if (query_fire_static_pressure_loaded) return;
  query_fire_static_pressure_loaded = YES;
  NSString *stored = [NSString stringWithContentsOfFile:
      QueryFireStaticPressureProfilePath() encoding:NSUTF8StringEncoding error:nil];
  NSScanner *scanner = [NSScanner scannerWithString:
      [stored stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @""];
  double values[3];
  for (NSUInteger index = 0; index < 3; ++index) {
    if (![scanner scanDouble:&values[index]] || !isfinite(values[index]) ||
        values[index] <= 0 || values[index] > 2.4) return;
  }
  if (!scanner.isAtEnd) return;
  for (NSUInteger index = 0; index < 3; ++index)
    query_fire_static_pressure_mpa[index] = values[index];
}

static double QueryFireStaticPressureMPa(NSInteger category) {
  LoadFireStaticPressureDefaults();
  if (category < 1 || category > 3) return 0;
  return query_fire_static_pressure_mpa[category - 1];
}

static NSString *SaveFireStaticPressureDefault(NSInteger category,
                                                double pressureMPa) {
  if (category < 1 || category > 3 || !isfinite(pressureMPa) ||
      pressureMPa <= 0 || pressureMPa > 2.4)
    return @"请输入类别 1–3 和 0–2.4 MPa 内的正数";
  LoadFireStaticPressureDefaults();
  double updated[3];
  for (NSUInteger index = 0; index < 3; ++index)
    updated[index] = query_fire_static_pressure_mpa[index];
  updated[category - 1] = pressureMPa;
  NSString *contents = [NSString stringWithFormat:@"%.6g %.6g %.6g\n",
      updated[0], updated[1], updated[2]];
  NSString *path = QueryFireStaticPressureProfilePath();
  if (![[NSFileManager defaultManager] createDirectoryAtPath:
      path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
      attributes:nil error:nil] ||
      ![contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding
                       error:nil])
    return @"无法保存消防静压默认值";
  [[NSFileManager defaultManager] setAttributes:
      @{NSFilePosixPermissions: @0600} ofItemAtPath:path error:nil];
  for (NSUInteger index = 0; index < 3; ++index)
    query_fire_static_pressure_mpa[index] = updated[index];
  query_fire_static_pressure_loaded = YES;
  return [NSString stringWithFormat:@"类别 %ld 消防静压参考值已设为 %@ MPa",
      (long)category, [NSString stringWithFormat:@"%.3g", pressureMPa]];
}

static double QueryConfiguredFloorHeight(void) {
  if (!query_floor_height_loaded) {
    query_floor_height_loaded = YES;
    NSString *stored = [NSString stringWithContentsOfFile:QueryFloorHeightProfilePath()
        encoding:NSUTF8StringEncoding error:nil];
    NSScanner *scanner = [NSScanner scannerWithString:
        [stored stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @""];
    double value = 0;
    if ([scanner scanDouble:&value] && scanner.isAtEnd && isfinite(value) &&
        value >= 2.0 && value <= 12.0)
      query_floor_height = value;
  }
  return query_floor_height;
}

static NSString *QueryLanguageProfilePath(void) {
  return [@"~/Library/Rime/input_translation.ui_language"
      stringByExpandingTildeInPath];
}

static NSString *QueryUILanguage(void) {
  if (!query_ui_language) {
    NSString *stored = [[NSString stringWithContentsOfFile:QueryLanguageProfilePath()
        encoding:NSUTF8StringEncoding error:nil]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSSet<NSString *> *supported = [NSSet setWithArray:
        @[@"zh-Hans", @"zh-Hant", @"en", @"ko", @"ja"]];
    query_ui_language = [supported containsObject:stored ?: @""] ? stored : @"zh-Hans";
  }
  return query_ui_language;
}

static NSString *QueryLanguageSettingFeedback(NSString *language) {
  NSDictionary<NSString *, NSString *> *messages = @{
    @"zh-Hans": @"界面语言已设为简体中文",
    @"zh-Hant": @"介面語言已設為繁體中文",
    @"en": @"Interface language set to English",
    @"ko": @"인터페이스 언어가 한국어로 설정되었습니다",
    @"ja": @"表示言語を日本語に設定しました"
  };
  return messages[language];
}

static NSString *ConfigureQueryLanguage(NSString *command) {
  if (![command hasPrefix:@"lang"]) return nil;
  NSString *suffix = [command substringFromIndex:4];
  NSDictionary<NSString *, NSString *> *codes = @{
    @"zh": @"zh-Hans", @"tw": @"zh-Hant", @"en": @"en",
    @"ko": @"ko", @"ja": @"ja"
  };
  NSString *language = codes[suffix.lowercaseString];
  if (!language) return nil;
  NSString *path = QueryLanguageProfilePath();
  if (![[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
      withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
  NSString *contents = [language stringByAppendingString:@"\n"];
  if (![contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil])
    return nil;
  [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600}
      ofItemAtPath:path error:nil];
  query_ui_language = language;
  return QueryLanguageSettingFeedback(language);
}

static NSString *LocalizedQueryText(NSString *text) {
  if (!text.length) return text;
  NSString *language = QueryUILanguage();
  if ([language isEqualToString:@"zh-Hans"]) return text;
  if ([text isEqualToString:@"u<语言>"]) {
    NSDictionary<NSString *, NSString *> *labels = @{
      @"en": @"u<language>", @"ko": @"u<언어>", @"ja": @"u<言語>", @"zh-Hant": @"u<語言>"
    };
    return labels[language] ?: text;
  }
  if ([text containsString:@"u<语言>"]) {
    NSDictionary<NSString *, NSString *> *hints = @{
      @"en": @"Set interface language with u<language>: ulangen, ulangko, ulangja or ulangtw",
      @"ko": @"u<언어>로 인터페이스 언어 설정: ulangen, ulangko, ulangja 또는 ulangtw",
      @"ja": @"u<言語> で表示言語を設定: ulangen、ulangko、ulangja、ulangtw",
      @"zh-Hant": @"使用 u<語言> 設定介面語言：ulangen、ulangko、ulangja 或 ulangtw"
    };
    return hints[language] ?: text;
  }
  static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *tables;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    tables = @{
      @"en": @{
        @"最大面板宽度": @"Maximum panel width", @"宽度格式不正确": @"Invalid width",
        @"楼层估算": @"Floor estimate", @"大约几层": @"Approx. floors",
        @"水柱高度": @"Water head", @"层高设置": @"Floor height setting", @"设置": @"Settings",
        @"最不利点最低静压": @"Minimum static pressure at the most unfavorable point",
        @"扣除静压后理论楼层": @"Theoretical floors after static-pressure reserve",
        @"消防静压设置": @"Fire static-pressure settings", @"静压设置": @"Static-pressure settings",
        @"消防静压默认设置": @"Fire static-pressure defaults",
        @"ufloorheight3.2（3.2:层高；可设置范围2-12米；默认3米）": @"ufloorheight3.2 (3.2: floor height; range 2–12 m; default 3 m)",
        @"层高请输入 2–12 米，例如 ufloorheight3.2": @"Enter 2–12 m, e.g. ufloorheight3.2",
        @"输入 2–12 米，例如 ufloorheight3.2": @"Enter 2–12 m, e.g. ufloorheight3.2",
        @"本地 IP": @"Local IP", @"公网 IP": @"Public IP", @"IP 地址查询": @"IP lookup",
        @"输入 IPv4 地址": @"Enter an IPv4 address", @"号码归属地": @"Phone region",
        @"座机归属地": @"Landline region", @"号码格式不正确": @"Invalid phone number",
        @"未找到该号段": @"Prefix not found", @"地区未收录": @"Region unavailable",
        @"过去天数": @"Days ago", @"剩余天数": @"Days remaining", @"相差天数": @"Days apart",
        @"开始日期": @"Start date", @"结束日期": @"End date", @"今天": @"Today",
        @"点击屏幕选择颜色": @"Click to pick a color", @"不可用": @"Unavailable",
        @"当地时区时间": @"Local time zone", @"时区时间": @"Time zone", @"纽约时间": @"New York time", @"洛杉矶时间": @"Los Angeles time", @"旧金山时间": @"San Francisco time", @"芝加哥时间": @"Chicago time", @"伦敦时间": @"London time", @"巴黎时间": @"Paris time", @"东京时间": @"Tokyo time", @"首尔时间": @"Seoul time", @"新加坡时间": @"Singapore time", @"香港时间": @"Hong Kong time", @"台北时间": @"Taipei time", @"悉尼时间": @"Sydney time", @"奥克兰时间": @"Auckland time", @"北京时间": @"Beijing time", @"上海时间": @"Shanghai time", @"迪拜时间": @"Dubai time", @"Unix 秒": @"Unix seconds", @"Unix 毫秒": @"Unix milliseconds",
        @"日期格式": @"Date format", @"日期间隔": @"Date interval", @"时区或时间戳": @"Time zone or timestamp", @"时间戳超出范围": @"Timestamp out of range",
        @"utime时间戳": @"utime timestamp", @"转换 Unix 秒／毫秒；不带参数时显示输入时刻快照": @"Convert Unix seconds/milliseconds; without an argument, show the time captured when entered",
        @"utime时区／城市": @"utime time zone/city", @"支持城市拼音，例如：niuyue、dongjing": @"Use city pinyin, e.g. niuyue or dongjing",
        @"输入 Unix 秒／毫秒、时区名或城市拼音（如 niuyue）": @"Enter Unix seconds/milliseconds, a time-zone ID, or city pinyin (e.g. niuyue)",
        @"单位不支持": @"Unsupported unit", @"温度超出范围": @"Temperature out of range", @"数值超出范围": @"Value out of range",
        @"货币换算": @"Currency conversion", @"汇率查询失败": @"Exchange-rate lookup failed",
        @"英里": @"Mile", @"英尺": @"Foot", @"英寸": @"Inch", @"码": @"Yard", @"公里": @"Kilometer", @"米": @"Meter", @"厘米": @"Centimeter", @"毫米": @"Millimeter",
        @"磅": @"Pound", @"盎司": @"Ounce", @"千克": @"Kilogram", @"克": @"Gram", @"毫克": @"Milligram", @"美制加仑": @"US gallon", @"升": @"Liter", @"毫升": @"Milliliter",
        @"微伏": @"Microvolt", @"毫伏": @"Millivolt", @"伏特": @"Volt", @"千伏": @"Kilovolt", @"微安": @"Microamp", @"毫安": @"Milliamp", @"安培": @"Amp", @"千安": @"Kiloamp",
        @"毫瓦": @"Milliwatt", @"瓦特": @"Watt", @"千瓦": @"Kilowatt", @"兆瓦": @"Megawatt", @"毫欧": @"Milliohm", @"欧姆": @"Ohm", @"千欧": @"Kiloohm", @"兆欧": @"Megaohm",
        @"毫瓦时": @"Milliwatt-hour", @"瓦时": @"Watt-hour", @"千瓦时": @"Kilowatt-hour", @"兆瓦时": @"Megawatt-hour", @"皮法": @"Picofarad", @"纳法": @"Nanofarad", @"微法": @"Microfarad", @"毫法": @"Millifarad",
        @"微亨": @"Microhenry", @"毫亨": @"Millihenry", @"亨利": @"Henry", @"微库仑": @"Microcoulomb", @"毫库仑": @"Millicoulomb", @"库仑": @"Coulomb", @"赫兹": @"Hertz", @"千赫": @"Kilohertz", @"兆赫": @"Megahertz", @"吉赫": @"Gigahertz",
        @"公斤力/平方厘米": @"kgf/cm²", @"毫米汞柱": @"Millimeters of mercury", @"帕": @"Pascal", @"千帕": @"Kilopascal", @"兆帕": @"Megapascal",
        @"人民币": @"Chinese yuan", @"美元": @"US dollar", @"欧元": @"Euro", @"日元": @"Japanese yen", @"英镑": @"British pound", @"港币": @"Hong Kong dollar", @"新台币": @"Taiwan dollar", @"新加坡元": @"Singapore dollar", @"加拿大元": @"Canadian dollar", @"澳大利亚元": @"Australian dollar", @"韩元": @"South Korean won", @"瑞士法郎": @"Swiss franc", @"泰铢": @"Thai baht",
        @"颜色": @"Color", @"HEX（无 #）": @"HEX (no #)", @"HEX + Alpha": @"HEX + alpha", @"摄氏度": @"Celsius", @"华氏度": @"Fahrenheit", @"开尔文": @"Kelvin",
        @"输入停顿后自动查询": @"Lookup starts after you pause typing",
        @"输入完整地址 · 例如 uip8.8.8.8": @"Enter a full address, e.g. uip8.8.8.8",
        @"输入 200–2000 的整数，例如 umaxwidth600": @"Enter an integer from 200–2000, e.g. umaxwidth600",
        @"请输入 200–2000 的整数": @"Enter an integer from 200–2000",
        @"设置已保存": @"Settings saved", @"设置结果": @"Settings",
        @"搜索引擎设置": @"Search engine", @"面板宽度设置": @"Panel width",
        @"开启或关闭候选翻译": @"Toggle candidate translations", @"朗读当前候选的译文": @"Speak the selected translation",
        @"上屏当前候选的译文": @"Commit the selected translation", @"展开或收起当前候选的完整翻译": @"Expand or collapse the full translation",
        @"开启或关闭音标显示": @"Toggle phonetic display", @"用默认搜索引擎搜索当前候选": @"Search with the default engine",
        @"用第二搜索引擎搜索当前候选": @"Search with the second engine",
        @"搜索首候选（默认／第二引擎）": @"Search the first candidate (default/secondary engine)",
        @"复制首候选译文": @"Copy the first candidate's translation",
        @"朗读首候选译文": @"Speak the first candidate's translation",
        @"内部构建配置后用新闻扩展搜索首候选": @"Search the first candidate with the news extension when configured in an internal build",
        @"公开版不执行动作（触发按键会被吞掉）": @"No action in the public build (the trigger is consumed)",
        @"复制当前结果信息": @"Copy the selected result", @"复制当前候选词；取色时选定颜色或重新取色": @"Copy candidate; confirm or resume color sampling",
        @"关闭快捷键帮助": @"Close shortcut help", @"打开或关闭本帮助": @"Toggle this help",
        @"上一页／下一页；每页最多 9 条": @"Previous/next page; up to 9 rows per page",
        @"移动选择候选词或帮助条目；到页边缘自动跨页": @"Move through candidates or help; cross pages at the edges",
        @"数字和标点": @"Digits and punctuation", @"直接输入并显示；8 位日期自动进入日期换算": @"Type to enter; valid 8-digit dates open date conversion",
        @"按 u<语言> 设置界面语言，例如 ulangen / ulangko / ulangja / ulangtw": @"Set the UI with u<language>: ulangen, ulangko, ulangja or ulangtw",
        @"umaxwidth数字": @"umaxwidth<number>", @"设置 U 面板最大宽度（200–2000 pt，默认 400）": @"Set U panel width (200–2000 pt; default 400)",
        @"ufloorheight数字": @"ufloorheight<number>", @"设置楼层估算使用的层高（2–12 m，默认 3.0 m）": @"Set floor height (2–12 m; default 3.0 m)",
        @"uconv2.6mp1 / uconv2.6mpa1": @"uconv2.6mp1 / uconv2.6mpa1",
        @"末尾类别码：1一类高层公共建筑；2二类高层公共建筑／多层公共建筑；3其他": @"Suffix category: 1 class I high-rise public; 2 class II high-rise public/multistory public; 3 other",
        @"ufiredefault1-0.15 设置类别1静压MPa；类别2默认0.07；类别3默认0.01（用户参考值）": @"Set category 1 static pressure in MPa; category 2 defaults to 0.07; category 3 defaults to custom 0.01",
        @"u<引擎>1": @"u<engine>1", @"设置 ⌃G 搜索引擎，例如 ugoogle1": @"Set the ⌃G search engine, e.g. ugoogle1",
        @"设置 ⌃B 搜索引擎，例如 ubing2": @"Set the ⌃B search engine, e.g. ubing2",
        @"utime时间戳／时区": @"utime timestamp/time zone", @"查看本地、目标时区、UTC 与 Unix 秒／毫秒": @"Show local/target time, UTC and Unix seconds/milliseconds",
        @"udate日期": @"udate date", @"8 位日期可直接换算；双日期用 .、- 或空格分隔": @"Convert 8-digit dates; separate two dates with ., - or a space",
        @"uconv5 / uconv5mi / uconv100rmb": @"uconv5 / uconv5mi / uconv100rmb", @"支持压力、质量、电气及货币换算": @"Convert pressure, mass, electrical units and currencies",
        @"颜色取色时 ←↑↓→": @"Color sampling: ←↑↓→", @"将采样点移动一个物理像素；按空格选色": @"Move one physical pixel; press Space to select",
        @"方案翻页键": @"Schema paging keys", @"沿用鼠须管当前方案；不使用 -、= 翻页": @"Use Squirrel schema bindings except - and =",
        @"下一页／上一页，同左右方向键": @"Previous/next page, same as arrow keys",
        @"PageUp / PageDown": @"PageUp / PageDown", @"⌘C": @"⌘C", @"⌘,": @"⌘,", @"空格": @"Space", @"点击 ⓘ": @"Click ⓘ",
        @"语言": @"Language", @"简体中文": @"Simplified Chinese", @"繁體中文": @"Traditional Chinese",
        @"English": @"English", @"한국어": @"Korean", @"日本語": @"Japanese",
        @"设置界面语言，例如 ulangen、ulangko、ulangja、ulangtw": @"Set interface language: ulangen, ulangko, ulangja or ulangtw"
      },
      @"ko": @{
        @"最大面板宽度": @"패널 최대 너비", @"宽度格式不正确": @"너비 형식이 올바르지 않습니다",
        @"楼层估算": @"층수 추정", @"大约几层": @"대략 몇 층",
        @"水柱高度": @"수주 높이", @"层高设置": @"층고 설정", @"设置": @"설정",
        @"最不利点最低静压": @"최불리점 최소 정압",
        @"扣除静压后理论楼层": @"정압을 제외한 이론 층수",
        @"消防静压设置": @"소방 정압 설정", @"静压设置": @"정압 설정", @"消防静压默认设置": @"소방 정압 기본값",
        @"ufloorheight3.2（3.2:层高；可设置范围2-12米；默认3米）": @"ufloorheight3.2 (3.2: 층고; 범위 2–12m; 기본 3m)",
        @"本地 IP": @"로컬 IP", @"公网 IP": @"공인 IP", @"IP 地址查询": @"IP 조회",
        @"输入 IPv4 地址": @"IPv4 주소 입력", @"号码归属地": @"전화번호 지역", @"座机归属地": @"유선전화 지역",
        @"号码格式不正确": @"전화번호 형식이 올바르지 않습니다", @"未找到该号段": @"번호 대역을 찾을 수 없습니다",
        @"地区未收录": @"지역 정보 없음", @"过去天数": @"지난 일수", @"剩余天数": @"남은 일수", @"相差天数": @"날짜 차이",
        @"开始日期": @"시작 날짜", @"结束日期": @"종료 날짜", @"今天": @"오늘", @"点击屏幕选择颜色": @"화면을 클릭해 색상 선택",
        @"不可用": @"사용할 수 없음", @"颜色": @"색상", @"HEX（无 #）": @"HEX (# 없음)", @"HEX + Alpha": @"HEX + 알파", @"摄氏度": @"섭씨", @"华氏度": @"화씨", @"开尔文": @"켈빈",
        @"当地时区时间": @"현지 시간대 시간", @"时区时间": @"시간대 시간", @"纽约时间": @"뉴욕 시간", @"洛杉矶时间": @"로스앤젤레스 시간", @"旧金山时间": @"샌프란시스코 시간", @"芝加哥时间": @"시카고 시간", @"伦敦时间": @"런던 시간", @"巴黎时间": @"파리 시간", @"东京时间": @"도쿄 시간", @"首尔时间": @"서울 시간", @"新加坡时间": @"싱가포르 시간", @"香港时间": @"홍콩 시간", @"台北时间": @"타이베이 시간", @"悉尼时间": @"시드니 시간", @"奥克兰时间": @"오클랜드 시간", @"北京时区时间": @"베이징 시간", @"北京时间": @"베이징 시간", @"上海时间": @"상하이 시간", @"迪拜时间": @"두바이 시간", @"Unix 秒": @"Unix 초", @"Unix 毫秒": @"Unix 밀리초",
        @"日期格式": @"날짜 형식", @"日期间隔": @"날짜 간격", @"时区或时间戳": @"시간대 또는 타임스탬프", @"时间戳超出范围": @"타임스탬프 범위 초과",
        @"utime时间戳": @"utime 타임스탬프", @"转换 Unix 秒／毫秒；不带参数时显示输入时刻快照": @"Unix 초/밀리초 변환; 인수 없이 입력하면 입력 시점의 시간을 표시",
        @"utime时区／城市": @"utime 시간대/도시", @"支持城市拼音，例如：niuyue、dongjing": @"도시 병음을 입력하세요 (예: niuyue, dongjing)",
        @"输入 Unix 秒／毫秒、时区名或城市拼音（如 niuyue）": @"Unix 초/밀리초, 시간대 ID 또는 도시 병음을 입력하세요 (예: niuyue)",
        @"单位不支持": @"지원하지 않는 단위", @"温度超出范围": @"온도 범위 초과", @"数值超出范围": @"값 범위 초과",
        @"货币换算": @"통화 변환", @"汇率查询失败": @"환율 조회 실패",
        @"英里": @"마일", @"英尺": @"피트", @"英寸": @"인치", @"码": @"야드", @"公里": @"킬로미터", @"米": @"미터", @"厘米": @"센티미터", @"毫米": @"밀리미터",
        @"磅": @"파운드", @"盎司": @"온스", @"千克": @"킬로그램", @"克": @"그램", @"毫克": @"밀리그램", @"美制加仑": @"미국 갤런", @"升": @"리터", @"毫升": @"밀리리터",
        @"微伏": @"마이크로볼트", @"毫伏": @"밀리볼트", @"伏特": @"볼트", @"千伏": @"킬로볼트", @"微安": @"마이크로암페어", @"毫安": @"밀리암페어", @"安培": @"암페어", @"千安": @"킬로암페어",
        @"毫瓦": @"밀리와트", @"瓦特": @"와트", @"千瓦": @"킬로와트", @"兆瓦": @"메가와트", @"毫欧": @"밀리옴", @"欧姆": @"옴", @"千欧": @"킬로옴", @"兆欧": @"메가옴",
        @"毫瓦时": @"밀리와트시", @"瓦时": @"와트시", @"千瓦时": @"킬로와트시", @"兆瓦时": @"메가와트시", @"皮法": @"피코패럿", @"纳法": @"나노패럿", @"微法": @"마이크로패럿", @"毫法": @"밀리패럿",
        @"微亨": @"마이크로헨리", @"毫亨": @"밀리헨리", @"亨利": @"헨리", @"微库仑": @"마이크로쿨롱", @"毫库仑": @"밀리쿨롱", @"库仑": @"쿨롱", @"赫兹": @"헤르츠", @"千赫": @"킬로헤르츠", @"兆赫": @"메가헤르츠", @"吉赫": @"기가헤르츠",
        @"公斤力/平方厘米": @"kgf/cm²", @"毫米汞柱": @"수은주 밀리미터", @"帕": @"파스칼", @"千帕": @"킬로파스칼", @"兆帕": @"메가파스칼",
        @"人民币": @"중국 위안", @"美元": @"미국 달러", @"欧元": @"유로", @"日元": @"일본 엔", @"英镑": @"영국 파운드", @"港币": @"홍콩 달러", @"新台币": @"대만 달러", @"新加坡元": @"싱가포르 달러", @"加拿大元": @"캐나다 달러", @"澳大利亚元": @"호주 달러", @"韩元": @"한국 원", @"瑞士法郎": @"스위스 프랑", @"泰铢": @"태국 바트",
        @"输入停顿后自动查询": @"입력을 멈추면 자동 조회", @"输入完整地址 · 例如 uip8.8.8.8": @"전체 주소 입력 (예: uip8.8.8.8)",
        @"输入 200–2000 的整数，例如 umaxwidth600": @"200–2000 사이의 정수 입력 (예: umaxwidth600)", @"请输入 200–2000 的整数": @"200–2000 사이의 정수를 입력하세요",
        @"设置已保存": @"설정이 저장되었습니다", @"设置结果": @"설정", @"搜索引擎设置": @"검색 엔진", @"面板宽度设置": @"패널 너비",
        @"开启或关闭候选翻译": @"후보 번역 켜기/끄기", @"朗读当前候选的译文": @"선택한 번역 읽기", @"上屏当前候选的译文": @"선택한 번역 입력",
        @"展开或收起当前候选的完整翻译": @"전체 번역 펼치기/접기", @"开启或关闭音标显示": @"발음기호 표시 켜기/끄기",
        @"用默认搜索引擎搜索当前候选": @"기본 검색 엔진으로 검색", @"用第二搜索引擎搜索当前候选": @"두 번째 검색 엔진으로 검색",
        @"搜索首候选（默认／第二引擎）": @"첫 번째 후보 검색 (기본/보조 엔진)",
        @"复制首候选译文": @"첫 번째 후보 번역 복사", @"朗读首候选译文": @"첫 번째 후보 번역 읽기",
        @"内部构建配置后用新闻扩展搜索首候选": @"내부 버전에서 설정 후 뉴스 확장 프로그램으로 첫 번째 후보 검색", @"公开版不执行动作（触发按键会被吞掉）": @"공개 버전에서는 동작하지 않으며 입력을 소비합니다",
        @"复制当前结果信息": @"현재 결과 정보 복사",
        @"复制当前候选词；取色时选定颜色或重新取色": @"후보 복사; 색상 선택 또는 다시 샘플링", @"关闭快捷键帮助": @"단축키 도움말 닫기",
        @"打开或关闭本帮助": @"도움말 열기/닫기", @"上一页／下一页；每页最多 9 条": @"이전/다음 페이지 (최대 9개)",
        @"移动选择候选词或帮助条目；到页边缘自动跨页": @"후보/도움말 이동; 가장자리에서 페이지 전환", @"数字和标点": @"숫자와 문장 부호",
        @"直接输入并显示；8 位日期自动进入日期换算": @"직접 입력; 8자리 날짜 자동 변환",
        @"按 u<语言> 设置界面语言，例如 ulangen / ulangko / ulangja / ulangtw": @"u<언어>로 설정: ulangen, ulangko, ulangja 또는 ulangtw",
        @"umaxwidth数字": @"umaxwidth<숫자>", @"设置 U 面板最大宽度（200–2000 pt，默认 400）": @"U 패널 너비 설정 (200–2000pt, 기본 400)",
        @"ufloorheight数字": @"ufloorheight<숫자>", @"设置楼层估算使用的层高（2–12 m，默认 3.0 m）": @"층고 설정 (2–12m, 기본 3.0m)",
        @"uconv2.6mp1 / uconv2.6mpa1": @"uconv2.6mp1 / uconv2.6mpa1",
        @"末尾类别码：1一类高层公共建筑；2二类高层公共建筑／多层公共建筑；3其他": @"끝자리 분류 코드: 1 1급 고층 공공, 2 2급 고층 공공/중층 공공, 3 기타",
        @"ufiredefault1-0.15 设置类别1静压MPa；类别2默认0.07；类别3默认0.01（用户参考值）": @"ufiredefault1-0.15로 1번 정압(MPa) 설정; 2번 기본 0.07, 3번 사용자 참고값 0.01",
        @"u<引擎>1": @"u<엔진>1", @"设置 ⌃G 搜索引擎，例如 ugoogle1": @"⌃G 검색 엔진 설정 (예: ugoogle1)", @"设置 ⌃B 搜索引擎，例如 ubing2": @"⌃B 검색 엔진 설정 (예: ubing2)",
        @"utime时间戳／时区": @"utime 타임스탬프/시간대", @"查看本地、目标时区、UTC 与 Unix 秒／毫秒": @"현지/지정 시간대, UTC 및 Unix 초/밀리초 표시",
        @"udate日期": @"udate 날짜", @"8 位日期可直接换算；双日期用 .、- 或空格分隔": @"8자리 날짜 변환; 두 날짜는 ., - 또는 공백으로 구분",
        @"uconv5 / uconv5mi / uconv100rmb": @"uconv5 / uconv5mi / uconv100rmb", @"支持压力、质量、电气及货币换算": @"압력, 질량, 전기 단위 및 통화 변환",
        @"颜色取色时 ←↑↓→": @"색상 선택 ←↑↓→", @"将采样点移动一个物理像素；按空格选色": @"물리 픽셀 단위 이동; Space로 선택",
        @"方案翻页键": @"입력 스키마 페이지 키", @"沿用鼠须管当前方案；不使用 -、= 翻页": @"Squirrel 스키마 설정 사용; -와 = 제외",
        @"下一页／上一页，同左右方向键": @"이전/다음 페이지 (좌우 화살표와 동일)", @"PageUp / PageDown": @"PageUp / PageDown",
        @"⌘C": @"⌘C", @"⌘,": @"⌘,", @"空格": @"Space", @"点击 ⓘ": @"ⓘ 클릭",
        @"语言": @"언어", @"简体中文": @"중국어 간체", @"繁體中文": @"중국어 번체", @"English": @"영어", @"한국어": @"한국어", @"日本語": @"일본어",
        @"设置界面语言，例如 ulangen、ulangko、ulangja、ulangtw": @"인터페이스 언어: ulangen, ulangko, ulangja 또는 ulangtw"
      },
      @"ja": @{
        @"最大面板宽度": @"パネルの最大幅", @"宽度格式不正确": @"幅の形式が正しくありません",
        @"楼层估算": @"階数の目安", @"大约几层": @"およその階数",
        @"水柱高度": @"水柱の高さ", @"层高设置": @"階高設定", @"设置": @"設定", @"本地 IP": @"ローカル IP",
        @"最不利点最低静压": @"最不利点の最低静水圧",
        @"扣除静压后理论楼层": @"静水圧控除後の理論階数",
        @"消防静压设置": @"消防静水圧設定", @"静压设置": @"静水圧設定", @"消防静压默认设置": @"消防静水圧の既定値",
        @"ufloorheight3.2（3.2:层高；可设置范围2-12米；默认3米）": @"ufloorheight3.2（3.2:階高；範囲2～12m；既定3m）",
        @"公网 IP": @"パブリック IP", @"IP 地址查询": @"IP 検索", @"输入 IPv4 地址": @"IPv4 アドレスを入力",
        @"号码归属地": @"電話番号の地域", @"座机归属地": @"固定電話の地域", @"号码格式不正确": @"電話番号の形式が正しくありません",
        @"未找到该号段": @"番号帯が見つかりません", @"地区未收录": @"地域情報なし", @"过去天数": @"経過日数", @"剩余天数": @"残り日数",
        @"相差天数": @"日数差", @"开始日期": @"開始日", @"结束日期": @"終了日", @"今天": @"今日", @"点击屏幕选择颜色": @"クリックして色を選択",
        @"不可用": @"利用できません", @"颜色": @"色", @"HEX（无 #）": @"HEX（#なし）", @"HEX + Alpha": @"HEX + アルファ", @"摄氏度": @"摂氏", @"华氏度": @"華氏", @"开尔文": @"ケルビン",
        @"当地时区时间": @"現地のタイムゾーン時刻", @"时区时间": @"タイムゾーン時刻", @"纽约时间": @"ニューヨーク時間", @"洛杉矶时间": @"ロサンゼルス時間", @"旧金山时间": @"サンフランシスコ時間", @"芝加哥时间": @"シカゴ時間", @"伦敦时间": @"ロンドン時間", @"巴黎时间": @"パリ時間", @"东京时间": @"東京時間", @"首尔时间": @"ソウル時間", @"新加坡时间": @"シンガポール時間", @"香港时间": @"香港時間", @"台北时间": @"台北時間", @"悉尼时间": @"シドニー時間", @"奥克兰时间": @"オークランド時間", @"北京时区时间": @"北京時間", @"北京时间": @"北京時間", @"上海时间": @"上海時間", @"迪拜时间": @"ドバイ時間", @"Unix 秒": @"Unix 秒", @"Unix 毫秒": @"Unix ミリ秒",
        @"日期格式": @"日付形式", @"日期间隔": @"日付の間隔", @"时区或时间戳": @"タイムゾーンまたはタイムスタンプ", @"时间戳超出范围": @"タイムスタンプ範囲外",
        @"utime时间戳": @"utime タイムスタンプ", @"转换 Unix 秒／毫秒；不带参数时显示输入时刻快照": @"Unix 秒／ミリ秒を変換；引数なしでは入力時の時刻を表示",
        @"utime时区／城市": @"utime タイムゾーン／都市", @"支持城市拼音，例如：niuyue、dongjing": @"都市名のピンインを入力（例: niuyue、dongjing）",
        @"输入 Unix 秒／毫秒、时区名或城市拼音（如 niuyue）": @"Unix 秒／ミリ秒、タイムゾーン ID、都市名のピンインを入力（例: niuyue）",
        @"单位不支持": @"未対応の単位", @"温度超出范围": @"温度範囲外", @"数值超出范围": @"数値範囲外",
        @"货币换算": @"通貨換算", @"汇率查询失败": @"為替レートの取得に失敗",
        @"英里": @"マイル", @"英尺": @"フィート", @"英寸": @"インチ", @"码": @"ヤード", @"公里": @"キロメートル", @"米": @"メートル", @"厘米": @"センチメートル", @"毫米": @"ミリメートル",
        @"磅": @"ポンド", @"盎司": @"オンス", @"千克": @"キログラム", @"克": @"グラム", @"毫克": @"ミリグラム", @"美制加仑": @"米ガロン", @"升": @"リットル", @"毫升": @"ミリリットル",
        @"微伏": @"マイクロボルト", @"毫伏": @"ミリボルト", @"伏特": @"ボルト", @"千伏": @"キロボルト", @"微安": @"マイクロアンペア", @"毫安": @"ミリアンペア", @"安培": @"アンペア", @"千安": @"キロアンペア",
        @"毫瓦": @"ミリワット", @"瓦特": @"ワット", @"千瓦": @"キロワット", @"兆瓦": @"メガワット", @"毫欧": @"ミリオーム", @"欧姆": @"オーム", @"千欧": @"キロオーム", @"兆欧": @"メガオーム",
        @"毫瓦时": @"ミリワット時", @"瓦时": @"ワット時", @"千瓦时": @"キロワット時", @"兆瓦时": @"メガワット時", @"皮法": @"ピコファラド", @"纳法": @"ナノファラド", @"微法": @"マイクロファラド", @"毫法": @"ミリファラド",
        @"微亨": @"マイクロヘンリー", @"毫亨": @"ミリヘンリー", @"亨利": @"ヘンリー", @"微库仑": @"マイクロクーロン", @"毫库仑": @"ミリクーロン", @"库仑": @"クーロン", @"赫兹": @"ヘルツ", @"千赫": @"キロヘルツ", @"兆赫": @"メガヘルツ", @"吉赫": @"ギガヘルツ",
        @"公斤力/平方厘米": @"kgf/cm²", @"毫米汞柱": @"水銀柱ミリメートル", @"帕": @"パスカル", @"千帕": @"キロパスカル", @"兆帕": @"メガパスカル",
        @"人民币": @"中国人民元", @"美元": @"米ドル", @"欧元": @"ユーロ", @"日元": @"日本円", @"英镑": @"英ポンド", @"港币": @"香港ドル", @"新台币": @"台湾ドル", @"新加坡元": @"シンガポールドル", @"加拿大元": @"カナダドル", @"澳大利亚元": @"オーストラリアドル", @"韩元": @"韓国ウォン", @"瑞士法郎": @"スイスフラン", @"泰铢": @"タイバーツ",
        @"输入停顿后自动查询": @"入力停止後に自動検索", @"输入完整地址 · 例如 uip8.8.8.8": @"完全なアドレスを入力（例: uip8.8.8.8）",
        @"输入 200–2000 的整数，例如 umaxwidth600": @"200～2000 の整数を入力（例: umaxwidth600）", @"请输入 200–2000 的整数": @"200～2000 の整数を入力してください",
        @"设置已保存": @"設定を保存しました", @"设置结果": @"設定", @"搜索引擎设置": @"検索エンジン", @"面板宽度设置": @"パネル幅",
        @"开启或关闭候选翻译": @"候補翻訳の切り替え", @"朗读当前候选的译文": @"選択した訳を読み上げる", @"上屏当前候选的译文": @"選択した訳を入力",
        @"展开或收起当前候选的完整翻译": @"訳文全体の表示／折りたたみ", @"开启或关闭音标显示": @"発音記号表示の切り替え",
        @"用默认搜索引擎搜索当前候选": @"既定の検索エンジンで検索", @"用第二搜索引擎搜索当前候选": @"第2検索エンジンで検索",
        @"搜索首候选（默认／第二引擎）": @"第1候補を検索（既定／第2エンジン）",
        @"复制首候选译文": @"第1候補の訳をコピー", @"朗读首候选译文": @"第1候補の訳を読み上げ",
        @"内部构建配置后用新闻扩展搜索首候选": @"内部ビルドで設定後、ニュース拡張を使って先頭候補を検索", @"公开版不执行动作（触发按键会被吞掉）": @"公開版では動作せず、キー入力を消費します",
        @"复制当前结果信息": @"現在の結果をコピー",
        @"复制当前候选词；取色时选定颜色或重新取色": @"候補をコピー；色を確定／再サンプリング", @"关闭快捷键帮助": @"ショートカットヘルプを閉じる",
        @"打开或关闭本帮助": @"ヘルプの表示切り替え", @"上一页／下一页；每页最多 9 条": @"前／次のページ（最大9件）",
        @"移动选择候选词或帮助条目；到页边缘自动跨页": @"候補やヘルプ項目を移動；端でページ切り替え", @"数字和标点": @"数字と句読点",
        @"直接输入并显示；8 位日期自动进入日期换算": @"そのまま入力；8桁の日付は自動変換",
        @"按 u<语言> 设置界面语言，例如 ulangen / ulangko / ulangja / ulangtw": @"u<言語> で設定: ulangen、ulangko、ulangja、ulangtw",
        @"umaxwidth数字": @"umaxwidth<数値>", @"设置 U 面板最大宽度（200–2000 pt，默认 400）": @"U パネル幅を設定（200～2000 pt、既定400）",
        @"ufloorheight数字": @"ufloorheight<数値>", @"设置楼层估算使用的层高（2–12 m，默认 3.0 m）": @"階高を設定（2～12m、既定3.0m）",
        @"uconv2.6mp1 / uconv2.6mpa1": @"uconv2.6mp1 / uconv2.6mpa1",
        @"末尾类别码：1一类高层公共建筑；2二类高层公共建筑／多层公共建筑；3其他": @"末尾の分類コード: 1 一類高層公共、2 二類高層公共／多層公共、3 その他",
        @"ufiredefault1-0.15 设置类别1静压MPa；类别2默认0.07；类别3默认0.01（用户参考值）": @"ufiredefault1-0.15 で分類1の静圧(MPa)を設定。分類2は0.07、分類3は独自参考値0.01",
        @"u<引擎>1": @"u<エンジン>1", @"设置 ⌃G 搜索引擎，例如 ugoogle1": @"⌃G 検索エンジンを設定（例: ugoogle1）", @"设置 ⌃B 搜索引擎，例如 ubing2": @"⌃B 検索エンジンを設定（例: ubing2）",
        @"utime时间戳／时区": @"utime タイムスタンプ／タイムゾーン", @"查看本地、目标时区、UTC 与 Unix 秒／毫秒": @"現地・指定時刻、UTC、Unix秒／ミリ秒を表示",
        @"udate日期": @"udate 日付", @"8 位日期可直接换算；双日期用 .、- 或空格分隔": @"8桁の日付を変換；2つの日付は .、- または空白で区切る",
        @"uconv5 / uconv5mi / uconv100rmb": @"uconv5 / uconv5mi / uconv100rmb", @"支持压力、质量、电气及货币换算": @"圧力・質量・電気単位・通貨を換算",
        @"颜色取色时 ←↑↓→": @"色選択 ←↑↓→", @"将采样点移动一个物理像素；按空格选色": @"物理ピクセル単位で移動；Space で色を確定",
        @"方案翻页键": @"スキーマのページキー", @"沿用鼠须管当前方案；不使用 -、= 翻页": @"Squirrel の設定を使用；- と = は除外",
        @"下一页／上一页，同左右方向键": @"前／次ページ（左右キーと同じ）", @"PageUp / PageDown": @"PageUp / PageDown",
        @"⌘C": @"⌘C", @"⌘,": @"⌘,", @"空格": @"Space", @"点击 ⓘ": @"ⓘ をクリック",
        @"语言": @"言語", @"简体中文": @"簡体字中国語", @"繁體中文": @"繁体字中国語", @"English": @"英語", @"한국어": @"韓国語", @"日本語": @"日本語",
        @"设置界面语言，例如 ulangen、ulangko、ulangja、ulangtw": @"表示言語: ulangen、ulangko、ulangja、ulangtw"
      },
      @"zh-Hant": @{
        @"楼层估算": @"樓層估算", @"大约几层": @"大約幾層",
        @"水柱高度": @"水柱高度", @"层高设置": @"層高設定", @"设置": @"設定",
        @"最不利点最低静压": @"最不利點最低靜壓",
        @"扣除静压后理论楼层": @"扣除靜壓後理論樓層",
        @"消防静压设置": @"消防靜壓設定", @"静压设置": @"靜壓設定", @"消防静压默认设置": @"消防靜壓預設設定",
        @"ufloorheight3.2（3.2:层高；可设置范围2-12米；默认3米）": @"ufloorheight3.2（3.2:層高；可設定範圍2-12米；預設3米）",
        @"最大面板宽度": @"最大面板寬度", @"宽度格式不正确": @"寬度格式不正確", @"本地 IP": @"本機 IP", @"公网 IP": @"公網 IP",
        @"IP 地址查询": @"IP 位址查詢", @"输入 IPv4 地址": @"輸入 IPv4 位址", @"号码归属地": @"電話號碼歸屬地", @"座机归属地": @"市話歸屬地",
        @"号码格式不正确": @"號碼格式不正確", @"未找到该号段": @"找不到此號段", @"地区未收录": @"未收錄此地區",
        @"过去天数": @"已過天數", @"剩余天数": @"剩餘天數", @"相差天数": @"相差天數", @"开始日期": @"開始日期", @"结束日期": @"結束日期", @"今天": @"今天",
        @"点击屏幕选择颜色": @"點擊螢幕選取顏色", @"不可用": @"無法使用", @"颜色": @"顏色", @"HEX（无 #）": @"HEX（無 #）", @"HEX + Alpha": @"HEX + Alpha", @"摄氏度": @"攝氏度", @"华氏度": @"華氏度", @"开尔文": @"克耳文",
        @"当地时区时间": @"當地時區時間", @"时区时间": @"時區時間", @"纽约时间": @"紐約時間", @"洛杉矶时间": @"洛杉磯時間", @"旧金山时间": @"舊金山時間", @"芝加哥时间": @"芝加哥時間", @"伦敦时间": @"倫敦時間", @"巴黎时间": @"巴黎時間", @"东京时间": @"東京時間", @"首尔时间": @"首爾時間", @"新加坡时间": @"新加坡時間", @"香港时间": @"香港時間", @"台北时间": @"台北時間", @"悉尼时间": @"雪梨時間", @"奥克兰时间": @"奧克蘭時間", @"北京时区时间": @"北京時間", @"北京时间": @"北京時間", @"上海时间": @"上海時間", @"迪拜时间": @"杜拜時間", @"Unix 秒": @"Unix 秒", @"Unix 毫秒": @"Unix 毫秒",
        @"日期格式": @"日期格式", @"日期间隔": @"日期間隔", @"时区或时间戳": @"時區或時間戳", @"时间戳超出范围": @"時間戳超出範圍",
        @"单位不支持": @"不支援的單位", @"温度超出范围": @"溫度超出範圍", @"数值超出范围": @"數值超出範圍",
        @"货币换算": @"貨幣換算", @"汇率查询失败": @"匯率查詢失敗",
        @"设置已保存": @"設定已儲存", @"设置结果": @"設定結果", @"搜索引擎设置": @"搜尋引擎設定", @"面板宽度设置": @"面板寬度設定",
        @"开启或关闭候选翻译": @"開啟或關閉候選翻譯", @"朗读当前候选的译文": @"朗讀目前候選詞的譯文", @"上屏当前候选的译文": @"輸入目前候選詞的譯文",
        @"展开或收起当前候选的完整翻译": @"展開或收合目前候選詞的完整翻譯", @"开启或关闭音标显示": @"開啟或關閉音標顯示",
        @"用默认搜索引擎搜索当前候选": @"使用預設搜尋引擎搜尋目前候選詞", @"用第二搜索引擎搜索当前候选": @"使用第二搜尋引擎搜尋目前候選詞",
        @"搜索首候选（默认／第二引擎）": @"搜尋第一個候選詞（預設／第二搜尋引擎）",
        @"复制首候选译文": @"複製第一個候選詞的譯文", @"朗读首候选译文": @"朗讀第一個候選詞的譯文",
        @"内部构建配置后用新闻扩展搜索首候选": @"內部版本設定後使用新聞擴充功能搜尋第一筆候選", @"公开版不执行动作（触发按键会被吞掉）": @"公開版不執行動作（觸發按鍵會被攔截）",
        @"复制当前结果信息": @"複製目前結果資訊",
        @"复制当前候选词；取色时选定颜色或重新取色": @"複製目前候選詞；取色時確認或重新取色", @"关闭快捷键帮助": @"關閉快速鍵說明", @"打开或关闭本帮助": @"開啟或關閉本說明",
        @"umaxwidth数字": @"umaxwidth數字", @"ufloorheight数字": @"ufloorheight數字",
        @"设置楼层估算使用的层高（2–12 m，默认 3.0 m）": @"設定樓層估算層高（2–12 m，預設 3.0 m）",
        @"uconv2.6mp1 / uconv2.6mpa1": @"uconv2.6mp1 / uconv2.6mpa1",
        @"末尾类别码：1一类高层公共建筑；2二类高层公共建筑／多层公共建筑；3其他": @"末尾類別碼：1 一類高層公共建築；2 二類高層公共建築／多層公共建築；3 其他",
        @"ufiredefault1-0.15 设置类别1静压MPa；类别2默认0.07；类别3默认0.01（用户参考值）": @"ufiredefault1-0.15 設定類別1靜壓MPa；類別2預設0.07；類別3預設0.01（使用者參考值）",
        @"u<语言> 设置界面语言": @"使用 u<語言> 設定介面語言", @"语言": @"語言",
        @"utime时间戳": @"utime 時間戳", @"转换 Unix 秒／毫秒；不带参数时显示输入时刻快照": @"轉換 Unix 秒／毫秒；不帶參數時顯示輸入當下的時間快照",
        @"utime时区／城市": @"utime 時區／城市", @"支持城市拼音，例如：niuyue、dongjing": @"輸入城市拼音，例如：niuyue、dongjing",
        @"输入 Unix 秒／毫秒、时区名或城市拼音（如 niuyue）": @"輸入 Unix 秒／毫秒、時區名稱或城市拼音（例如 niuyue）",
        @"下一页／上一页，同左右方向键": @"上一頁／下一頁，同左右方向鍵", @"颜色格式": @"顏色格式",
        @"输入完整地址 · 例如 uip8.8.8.8": @"輸入完整位址，例如 uip8.8.8.8", @"输入停顿后自动查询": @"停止輸入後自動查詢",
        @"简体中文": @"簡體中文", @"繁體中文": @"繁體中文", @"English": @"英文", @"한국어": @"韓文", @"日本語": @"日文",
        @"设置界面语言，例如 ulangen、ulangko、ulangja、ulangtw": @"使用 ulangen、ulangko、ulangja、ulangtw 設定介面語言"
      }
    };
  });
  NSDictionary<NSString *, NSString *> *table = tables[language];
  static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *supplemental;
  static dispatch_once_t supplementalToken;
  dispatch_once(&supplementalToken, ^{
    supplemental = @{
      @"en": @{
        @"宽度请输入 200–2000 的整数": @"Enter an integer from 200–2000",
        @"宽度范围为 200–2000 pt": @"Width must be 200–2000 pt",
        @"无法保存面板宽度设置": @"Could not save panel width",
        @"请输入 200–2000 的整数": @"Enter an integer from 200–2000",
        @"请输入 2–12 米，例如 ufloorheight3.2": @"Enter 2–12 m, e.g. ufloorheight3.2",
        @"层高请输入 2–12 米，例如 ufloorheight3.2": @"Enter 2–12 m, e.g. ufloorheight3.2",
        @"无法保存层高设置": @"Could not save floor height",
        @"单位换算": @"Unit conversion", @"货币换算": @"Currency conversion",
        @"请输入类别 1–3 和 0–2.4 MPa 内的正数": @"Enter category 1–3 and a positive value up to 2.4 MPa",
        @"无法保存消防静压默认值": @"Could not save fire static-pressure defaults",
        @"数值超出范围": @"Value out of range", @"单位不支持": @"Unsupported unit",
        @"温度超出范围": @"Temperature out of range", @"日期格式": @"Date format",
        @"日期间隔": @"Date interval", @"时间戳超出范围": @"Timestamp out of range",
        @"时区或时间戳": @"Time zone or timestamp", @"本地 IP": @"Local IP",
        @"公网 IP": @"Public IP", @"IP 地址查询": @"IP lookup",
        @"号码格式不正确": @"Invalid phone number", @"号码归属地": @"Phone region",
        @"座机归属地": @"Landline region", @"号段归属地": @"Phone prefix region",
        @"未找到该号段": @"Prefix not found", @"地区未收录": @"Region unavailable",
        @"点击屏幕选择颜色": @"Click to pick a color", @"未选择颜色；按空格重新取色": @"No color selected; press Space to sample again",
        @"或输入 rgb(r, g, b) / rgba(r, g, b, a)": @"or enter rgb(r, g, b) / rgba(r, g, b, a)",
        @"输入 #RGB、#RGBA、#RRGGBB、#RRGGBBAA": @"Enter #RGB, #RGBA, #RRGGBB or #RRGGBBAA",
        @"仅支持公元 0001–9999 年": @"Supported years: 0001–9999",
        @"单日期 YYYYMMDD；双日期用单个 .、- 或空格分隔": @"Single date: YYYYMMDD; separate two dates with one ., - or space",
        @"双日期格式：YYYYMMDD.YYYYMMDD（分隔符用单个 .、- 或空格）": @"Two dates: YYYYMMDD.YYYYMMDD (separate with one ., - or space)",
        @"无效日期；双日期请用 YYYYMMDD.YYYYMMDD": @"Invalid date; use YYYYMMDD.YYYYMMDD for a date range",
        @"正在获取每日参考汇率…": @"Loading daily reference rates…",
        @"网络不可用或服务暂不可达": @"Network unavailable or service unreachable",
        @"暂无汇率数据": @"No exchange-rate data", @"该币种暂不受支持": @"This currency is not currently supported",
        @"请缩小输入金额": @"Try a smaller amount", @"请缩小输入数值": @"Try a smaller value",
        @"不能低于绝对零度 -273.15 °C": @"Cannot be below absolute zero (−273.15 °C)",
        @"格式：uconv数值单位，如 5kg、5MPa、100rmb": @"Format: uconv<number><unit>, e.g. 5kg, 5MPa or 100rmb",
        @"长度、质量、体积、温度、压力、电气或货币单位": @"Length, mass, volume, temperature, pressure, electrical or currency units",
        @"正在查询公网 IP 和地区…": @"Looking up public IP and location…",
        @"正在查询 IP 地区和网络信息…": @"Looking up IP location and network…",
        @"公网 IP 查询失败（网络不可用或服务限流）": @"Public IP lookup failed (network unavailable or rate limited)",
        @"未返回 IP 地区信息": @"No IP location data returned",
        @"输入停止后自动查询": @"Lookup starts after you pause typing",
        @"输入停顿后自动查询": @"Lookup starts after you pause typing",
        @"输入完整地址 · 例如 uip8.8.8.8": @"Enter a full address, e.g. uip8.8.8.8",
        @"本地号段库未收录该号码，或号码格式不正确": @"Number not found in the local prefix database, or invalid format",
        @"未知运营商": @"Unknown carrier", @"中国移动": @"China Mobile", @"中国联通": @"China Unicom",
        @"中国电信": @"China Telecom", @"中国电信虚拟运营商": @"China Telecom MVNO",
        @"中国联通虚拟运营商": @"China Unicom MVNO", @"中国移动虚拟运营商": @"China Mobile MVNO",
        @"中国广电": @"China Broadnet", @"区号": @"Area code", @"继续输入": @"Continue entering",
        @"继续输入本地号码": @"enter the local number to continue", @"参考汇率": @"reference rate",
        @"大约几层": @"Approx. floors", @"层高设置": @"Floor height setting",
        @"类别1": @"Category 1", @"类别2": @"Category 2", @"类别3": @"Category 3",
        @"公开结果暂不可用": @"Public lookup is temporarily unavailable", @"未连接": @"Not connected", @"不可用": @"Unavailable"
      },
      @"ko": @{
        @"宽度请输入 200–2000 的整数": @"200–2000 사이의 정수를 입력하세요",
        @"宽度范围为 200–2000 pt": @"너비는 200–2000pt여야 합니다",
        @"无法保存面板宽度设置": @"패널 너비를 저장할 수 없습니다",
        @"请输入 200–2000 的整数": @"200–2000 사이의 정수를 입력하세요",
        @"请输入 2–12 米，例如 ufloorheight3.2": @"2–12m를 입력하세요 (예: ufloorheight3.2)",
        @"层高请输入 2–12 米，例如 ufloorheight3.2": @"층고 2–12m를 입력하세요 (예: ufloorheight3.2)",
        @"无法保存层高设置": @"층고 설정을 저장할 수 없습니다",
        @"单位换算": @"단위 변환", @"货币换算": @"통화 변환", @"数值超出范围": @"값 범위 초과",
        @"请输入类别 1–3 和 0–2.4 MPa 内的正数": @"분류 1–3과 0–2.4MPa 범위의 양수를 입력하세요",
        @"无法保存消防静压默认值": @"소방 정압 기본값을 저장할 수 없습니다",
        @"单位不支持": @"지원하지 않는 단위", @"温度超出范围": @"온도 범위 초과",
        @"日期格式": @"날짜 형식", @"日期间隔": @"날짜 간격", @"时间戳超出范围": @"타임스탬프 범위 초과",
        @"时区或时间戳": @"시간대 또는 타임스탬프", @"本地 IP": @"로컬 IP", @"公网 IP": @"공인 IP",
        @"IP 地址查询": @"IP 조회", @"号码格式不正确": @"전화번호 형식이 올바르지 않습니다",
        @"号码归属地": @"전화번호 지역", @"座机归属地": @"유선전화 지역", @"号段归属地": @"전화번호 대역 지역",
        @"未找到该号段": @"번호 대역을 찾을 수 없습니다", @"地区未收录": @"지역 정보 없음",
        @"点击屏幕选择颜色": @"화면을 클릭해 색상 선택", @"未选择颜色；按空格重新取色": @"색상이 선택되지 않았습니다. Space를 눌러 다시 샘플링",
        @"或输入 rgb(r, g, b) / rgba(r, g, b, a)": @"또는 rgb(r, g, b) / rgba(r, g, b, a) 입력",
        @"输入 #RGB、#RGBA、#RRGGBB、#RRGGBBAA": @"#RGB, #RGBA, #RRGGBB 또는 #RRGGBBAA 입력",
        @"仅支持公元 0001–9999 年": @"지원 연도: 0001–9999",
        @"单日期 YYYYMMDD；双日期用单个 .、- 或空格分隔": @"단일 날짜: YYYYMMDD; 두 날짜는 ., - 또는 공백 하나로 구분",
        @"双日期格式：YYYYMMDD.YYYYMMDD（分隔符用单个 .、- 或空格）": @"두 날짜: YYYYMMDD.YYYYMMDD (., - 또는 공백 하나로 구분)",
        @"无效日期；双日期请用 YYYYMMDD.YYYYMMDD": @"잘못된 날짜입니다. 범위는 YYYYMMDD.YYYYMMDD 형식으로 입력하세요",
        @"正在获取每日参考汇率…": @"일일 참고 환율을 불러오는 중…", @"网络不可用或服务暂不可达": @"네트워크를 사용할 수 없거나 서비스에 연결할 수 없습니다",
        @"暂无汇率数据": @"환율 데이터 없음", @"该币种暂不受支持": @"현재 지원하지 않는 통화입니다",
        @"请缩小输入金额": @"더 작은 금액을 입력하세요", @"请缩小输入数值": @"더 작은 값을 입력하세요",
        @"不能低于绝对零度 -273.15 °C": @"절대 영도(−273.15 °C)보다 낮을 수 없습니다",
        @"格式：uconv数值单位，如 5kg、5MPa、100rmb": @"형식: uconv<값><단위> (예: 5kg, 5MPa, 100rmb)",
        @"长度、质量、体积、温度、压力、电气或货币单位": @"길이, 질량, 부피, 온도, 압력, 전기 또는 통화 단위",
        @"正在查询公网 IP 和地区…": @"공인 IP 및 위치 조회 중…", @"正在查询 IP 地区和网络信息…": @"IP 위치 및 네트워크 정보 조회 중…",
        @"公网 IP 查询失败（网络不可用或服务限流）": @"공인 IP 조회 실패 (네트워크 오류 또는 요청 제한)",
        @"未返回 IP 地区信息": @"IP 위치 정보가 반환되지 않았습니다", @"输入停止后自动查询": @"입력을 멈추면 자동 조회",
        @"输入停顿后自动查询": @"입력을 멈추면 자동 조회", @"输入完整地址 · 例如 uip8.8.8.8": @"전체 주소 입력 (예: uip8.8.8.8)",
        @"本地号段库未收录该号码，或号码格式不正确": @"로컬 번호 대역 데이터에 없거나 형식이 올바르지 않습니다",
        @"继续输入本地号码": @"현지 번호를 계속 입력하세요", @"未知运营商": @"알 수 없는 통신사",
        @"中国移动": @"China Mobile", @"中国联通": @"China Unicom", @"中国电信": @"China Telecom",
        @"中国电信虚拟运营商": @"China Telecom MVNO", @"中国联通虚拟运营商": @"China Unicom MVNO",
        @"中国移动虚拟运营商": @"China Mobile MVNO", @"中国广电": @"China Broadnet",
        @"区号": @"지역 번호", @"继续输入": @"계속 입력",
        @"参考汇率": @"참고 환율", @"大约几层": @"대략 몇 층", @"层高设置": @"층고 설정",
        @"类别1": @"분류 1", @"类别2": @"분류 2", @"类别3": @"분류 3",
        @"公开结果暂不可用": @"조회 결과를 사용할 수 없습니다", @"未连接": @"연결되지 않음", @"不可用": @"사용할 수 없음"
      },
      @"ja": @{
        @"宽度请输入 200–2000 的整数": @"幅は200～2000の整数で入力してください",
        @"宽度范围为 200–2000 pt": @"幅は200～2000 ptの範囲で指定してください",
        @"无法保存面板宽度设置": @"パネル幅を保存できません",
        @"请输入 200–2000 的整数": @"200～2000の整数を入力してください",
        @"请输入 2–12 米，例如 ufloorheight3.2": @"2～12 mで入力（例: ufloorheight3.2）",
        @"层高请输入 2–12 米，例如 ufloorheight3.2": @"階高は2～12 mで入力（例: ufloorheight3.2）",
        @"无法保存层高设置": @"階高設定を保存できません",
        @"单位换算": @"単位変換", @"货币换算": @"通貨換算", @"数值超出范围": @"数値範囲外",
        @"请输入类别 1–3 和 0–2.4 MPa 内的正数": @"分類1～3と0～2.4 MPaの正数を入力してください",
        @"无法保存消防静压默认值": @"消防静水圧の既定値を保存できません",
        @"单位不支持": @"未対応の単位", @"温度超出范围": @"温度範囲外", @"日期格式": @"日付形式",
        @"日期间隔": @"日付の間隔", @"时间戳超出范围": @"タイムスタンプ範囲外", @"时区或时间戳": @"タイムゾーンまたはタイムスタンプ",
        @"本地 IP": @"ローカル IP", @"公网 IP": @"パブリック IP", @"IP 地址查询": @"IP 検索",
        @"号码格式不正确": @"電話番号の形式が正しくありません", @"号码归属地": @"電話番号の地域",
        @"座机归属地": @"固定電話の地域", @"号段归属地": @"電話番号帯の地域", @"未找到该号段": @"番号帯が見つかりません",
        @"地区未收录": @"地域情報なし", @"点击屏幕选择颜色": @"画面をクリックして色を選択", @"未选择颜色；按空格重新取色": @"色が未選択です。Spaceで再サンプリング",
        @"或输入 rgb(r, g, b) / rgba(r, g, b, a)": @"または rgb(r, g, b) / rgba(r, g, b, a) を入力",
        @"输入 #RGB、#RGBA、#RRGGBB、#RRGGBBAA": @"#RGB、#RGBA、#RRGGBB、#RRGGBBAA を入力",
        @"仅支持公元 0001–9999 年": @"対応年: 0001～9999", @"单日期 YYYYMMDD；双日期用单个 .、- 或空格分隔": @"単日: YYYYMMDD、2つの日付は ., - または空白1つで区切る",
        @"双日期格式：YYYYMMDD.YYYYMMDD（分隔符用单个 .、- 或空格）": @"2日付: YYYYMMDD.YYYYMMDD（., - または空白1つで区切る）",
        @"无效日期；双日期请用 YYYYMMDD.YYYYMMDD": @"日付が無効です。範囲は YYYYMMDD.YYYYMMDD で入力してください",
        @"正在获取每日参考汇率…": @"日次参考為替レートを取得中…", @"网络不可用或服务暂不可达": @"ネットワークまたはサービスに接続できません",
        @"暂无汇率数据": @"為替レートデータがありません", @"该币种暂不受支持": @"この通貨は現在サポートされていません",
        @"请缩小输入金额": @"金額を小さくしてください", @"请缩小输入数值": @"値を小さくしてください",
        @"不能低于绝对零度 -273.15 °C": @"絶対零度（−273.15 °C）未満にはできません",
        @"格式：uconv数值单位，如 5kg、5MPa、100rmb": @"形式: uconv<数値><単位>（例: 5kg、5MPa、100rmb）",
        @"长度、质量、体积、温度、压力、电气或货币单位": @"長さ、質量、体積、温度、圧力、電気または通貨の単位",
        @"正在查询公网 IP 和地区…": @"パブリック IP と地域を検索中…", @"正在查询 IP 地区和网络信息…": @"IP の地域とネットワーク情報を検索中…",
        @"公网 IP 查询失败（网络不可用或服务限流）": @"パブリック IP の検索に失敗（ネットワークエラーまたは制限）",
        @"未返回 IP 地区信息": @"IP 地域情報がありません", @"输入停止后自动查询": @"入力停止後に自動検索",
        @"输入停顿后自动查询": @"入力停止後に自動検索", @"输入完整地址 · 例如 uip8.8.8.8": @"完全なアドレスを入力（例: uip8.8.8.8）",
        @"本地号段库未收录该号码，或号码格式不正确": @"ローカル番号帯データにないか、形式が正しくありません",
        @"继续输入本地号码": @"市内番号を続けて入力", @"未知运营商": @"不明な通信事業者",
        @"中国移动": @"China Mobile", @"中国联通": @"China Unicom", @"中国电信": @"China Telecom",
        @"中国电信虚拟运营商": @"China Telecom MVNO", @"中国联通虚拟运营商": @"China Unicom MVNO",
        @"中国移动虚拟运营商": @"China Mobile MVNO", @"中国广电": @"China Broadnet", @"区号": @"市外局番",
        @"继续输入": @"続けて入力", @"参考汇率": @"参考為替レート",
        @"大约几层": @"およその階数", @"层高设置": @"階高設定", @"类别1": @"分類1", @"类别2": @"分類2", @"类别3": @"分類3",
        @"公开结果暂不可用": @"検索結果を利用できません", @"未连接": @"未接続", @"不可用": @"利用できません"
      }
    };
  });
  NSString *localized = table[text] ?: supplemental[language][text];
  if (localized) return localized;
  static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *dynamicWords;
  static dispatch_once_t dynamicWordsToken;
  dispatch_once(&dynamicWordsToken, ^{
    dynamicWords = @{
      @"en": @{
        @"一类高层公共建筑": @"Class I high-rise public building", @"二类高层公共建筑／多层公共建筑": @"Class II high-rise/multistory public building",
        @"其他（用户参考值）": @"Other (user reference)", @"其他": @"Other",
        @"Google": @"Google", @"Bing": @"Bing", @"百度": @"Baidu", @"搜狗": @"Sogou",
        @"区号": @"area code", @"继续输入": @"continue entering", @"继续输入本地号码": @"enter the local number to continue",
        @"参考汇率": @"reference rate", @"未知运营商": @"Unknown carrier",
        @"芝加哥": @"Chicago", @"广州": @"Guangzhou", @"沈阳": @"Shenyang", @"南京": @"Nanjing", @"武汉": @"Wuhan",
        @"成都": @"Chengdu", @"西安": @"Xi'an", @"杭州": @"Hangzhou", @"深圳": @"Shenzhen", @"桂林": @"Guilin", @"昆明": @"Kunming",
        @"北京": @"Beijing", @"上海": @"Shanghai", @"天津": @"Tianjin", @"重庆": @"Chongqing",
        @"湖北": @"Hubei", @"湖南": @"Hunan", @"广东": @"Guangdong", @"广西": @"Guangxi", @"四川": @"Sichuan", @"浙江": @"Zhejiang", @"江苏": @"Jiangsu", @"山东": @"Shandong", @"河南": @"Henan", @"河北": @"Hebei", @"福建": @"Fujian", @"安徽": @"Anhui", @"江西": @"Jiangxi", @"辽宁": @"Liaoning", @"吉林": @"Jilin", @"黑龙江": @"Heilongjiang", @"云南": @"Yunnan", @"贵州": @"Guizhou", @"陕西": @"Shaanxi", @"甘肃": @"Gansu", @"青海": @"Qinghai", @"海南": @"Hainan", @"山西": @"Shanxi", @"内蒙古": @"Inner Mongolia", @"宁夏": @"Ningxia", @"新疆": @"Xinjiang", @"西藏": @"Tibet"
      },
      @"ko": @{
        @"一类高层公共建筑": @"1급 고층 공공 건축물", @"二类高层公共建筑／多层公共建筑": @"2급 고층/다층 공공 건축물",
        @"其他（用户参考值）": @"기타 (사용자 참고값)", @"其他": @"기타", @"百度": @"Baidu", @"搜狗": @"Sogou",
        @"区号": @"지역 번호", @"继续输入": @"계속 입력", @"继续输入本地号码": @"현지 번호를 계속 입력하세요",
        @"参考汇率": @"참고 환율", @"未知运营商": @"알 수 없는 통신사",
        @"北京": @"베이징", @"上海": @"상하이", @"天津": @"톈진", @"重庆": @"충칭", @"广州": @"광저우", @"沈阳": @"선양", @"南京": @"난징", @"武汉": @"우한", @"成都": @"청두", @"西安": @"시안", @"杭州": @"항저우", @"深圳": @"선전", @"桂林": @"구이린", @"昆明": @"쿤밍",
        @"湖北": @"후베이", @"湖南": @"후난", @"广东": @"광둥", @"广西": @"광시", @"四川": @"쓰촨", @"浙江": @"저장", @"江苏": @"장쑤", @"山东": @"산둥", @"河南": @"허난", @"河北": @"허베이", @"福建": @"푸젠", @"安徽": @"안후이", @"江西": @"장시", @"辽宁": @"랴오닝", @"吉林": @"지린", @"黑龙江": @"헤이룽장", @"云南": @"윈난", @"贵州": @"구이저우", @"陕西": @"산시", @"甘肃": @"간쑤", @"青海": @"칭하이", @"海南": @"하이난", @"山西": @"산시", @"内蒙古": @"내몽골", @"宁夏": @"닝샤", @"新疆": @"신장", @"西藏": @"티베트"
      },
      @"ja": @{
        @"一类高层公共建筑": @"一類高層公共建築", @"二类高层公共建筑／多层公共建筑": @"二類高層／多層公共建築",
        @"其他（用户参考值）": @"その他（ユーザー参考値）", @"其他": @"その他", @"百度": @"Baidu", @"搜狗": @"Sogou",
        @"区号": @"市外局番", @"继续输入": @"続けて入力", @"继续输入本地号码": @"市内番号を続けて入力",
        @"参考汇率": @"参考為替レート", @"未知运营商": @"不明な通信事業者",
        @"北京": @"北京", @"上海": @"上海", @"天津": @"天津", @"重庆": @"重慶", @"广州": @"広州", @"沈阳": @"瀋陽", @"南京": @"南京", @"武汉": @"武漢", @"成都": @"成都", @"西安": @"西安", @"杭州": @"杭州", @"深圳": @"深圳", @"桂林": @"桂林", @"昆明": @"昆明",
        @"湖北": @"湖北", @"湖南": @"湖南", @"广东": @"広東", @"广西": @"広西", @"四川": @"四川", @"浙江": @"浙江", @"江苏": @"江蘇", @"山东": @"山東", @"河南": @"河南", @"河北": @"河北", @"福建": @"福建", @"安徽": @"安徽", @"江西": @"江西", @"辽宁": @"遼寧", @"吉林": @"吉林", @"黑龙江": @"黒竜江", @"云南": @"雲南", @"贵州": @"貴州", @"陕西": @"陝西", @"甘肃": @"甘粛", @"青海": @"青海", @"海南": @"海南", @"山西": @"山西", @"内蒙古": @"内モンゴル", @"宁夏": @"寧夏", @"新疆": @"新疆", @"西藏": @"チベット"
      },
      @"zh-Hant": @{}
    };
  });
  NSDictionary<NSString *, NSString *> *words = dynamicWords[language];
  if ([text hasSuffix:@" 天"]) {
    NSString *count = [text substringToIndex:text.length - 2];
    NSScanner *scanner = [NSScanner scannerWithString:count];
    long long days = 0;
    if ([scanner scanLongLong:&days] && scanner.isAtEnd) {
      NSDictionary<NSString *, NSString *> *suffixes = @{
        @"en": (llabs(days) == 1 ? @" day" : @" days"),
        @"ko": @"일", @"ja": @"日", @"zh-Hant": @" 天"
      };
      return [count stringByAppendingString:suffixes[language] ?: @" 天"];
    }
  }
  NSString *searchSuffix = @" 搜索当前候选";
  if ([text hasSuffix:searchSuffix]) {
    NSString *engine = [text substringToIndex:text.length - searchSuffix.length];
    NSString *translatedEngine = words[engine] ?: table[engine] ?: engine;
    NSDictionary<NSString *, NSString *> *suffixes = @{
      @"en": @" search current candidate", @"ko": @" 현재 후보 검색",
      @"ja": @" 現在の候補を検索", @"zh-Hant": @" 搜尋目前候選詞"
    };
    return [translatedEngine stringByAppendingString:suffixes[language] ?: searchSuffix];
  }
  NSArray<NSString *> *wordKeys = [words.allKeys sortedArrayUsingComparator:
      ^NSComparisonResult(NSString *left, NSString *right) {
    return left.length > right.length ? NSOrderedAscending :
        (left.length < right.length ? NSOrderedDescending : NSOrderedSame);
  }];
  for (NSString *key in wordKeys)
    if ([text containsString:key])
      text = [text stringByReplacingOccurrencesOfString:key withString:words[key]];
  NSString *floorSavedPrefix = @"楼层估算层高已设为 ";
  if ([text hasPrefix:floorSavedPrefix]) {
    NSString *value = [text substringFromIndex:floorSavedPrefix.length];
    NSDictionary<NSString *, NSString *> *templates = @{
      @"en": @"Floor estimate height set to %@ m", @"ko": @"층수 추정 층고를 %@m로 설정했습니다",
      @"ja": @"階数推定の階高を%@ mに設定しました", @"zh-Hant": @"樓層估算層高已設為%@"
    };
    return [NSString stringWithFormat:templates[language] ?: text, value];
  }
  NSString *fireSavedPrefix = @"类别 ";
  NSString *fireSavedMiddle = @" 消防静压参考值已设为 ";
  NSRange fireSavedRange = [text rangeOfString:fireSavedMiddle];
  if ([text hasPrefix:fireSavedPrefix] && fireSavedRange.location != NSNotFound) {
    NSString *category = [text substringWithRange:NSMakeRange(
        fireSavedPrefix.length, fireSavedRange.location - fireSavedPrefix.length)];
    NSString *value = [text substringFromIndex:NSMaxRange(fireSavedRange)];
    NSDictionary<NSString *, NSString *> *templates = @{
      @"en": @"Category %@ fire static-pressure reference set to %@ MPa",
      @"ko": @"분류 %@ 소방 정압 참고값을 %@MPa로 설정했습니다",
      @"ja": @"分類%@の消防静水圧参考値を%@ MPaに設定しました",
      @"zh-Hant": @"類別%@消防靜壓參考值已設為%@ MPa"
    };
    return [NSString stringWithFormat:templates[language] ?: text, category, value];
  }
  if ([text containsString:@" · "] && [text containsString:@" MPa"] &&
      [text containsString:@"（建筑高度超过100米应按0.15 MPa）"]) {
    NSString *value = [[text componentsSeparatedByString:@" · "] lastObject];
    value = [value stringByReplacingOccurrencesOfString:@"（建筑高度超过100米应按0.15 MPa）" withString:@""];
    NSDictionary<NSString *, NSString *> *templates = @{
      @"en": @"Minimum static pressure at the most unfavorable point · %@ MPa (use 0.15 MPa for buildings over 100 m)",
      @"ko": @"최불리점 최소 정압 · %@MPa (높이 100m 초과 시 0.15MPa 적용)",
      @"ja": @"最不利点の最低静水圧 · %@ MPa（高さ100m超は0.15 MPa）",
      @"zh-Hant": @"最不利點最低靜壓 · %@ MPa（建築高度超過100米按0.15 MPa）"
    };
    return [NSString stringWithFormat:templates[language] ?: text, value];
  }
  if (words.count && [text hasPrefix:@"低于 "]) {
    NSString *value = [text substringFromIndex:3];
    if ([language isEqualToString:@"en"]) return [NSString stringWithFormat:@"Below %@ static-pressure reference", value];
    if ([language isEqualToString:@"ko"]) return [NSString stringWithFormat:@"%@ 정압 참고값 미만", value];
    if ([language isEqualToString:@"ja"]) return [NSString stringWithFormat:@"%@ 静水圧の参考値未満", value];
  }
  if (words.count && [text hasPrefix:@"当前 "] && [text containsString:@" m；"]) {
    NSString *value = [[text componentsSeparatedByString:@" m；"] firstObject];
    value = [value substringFromIndex:3];
    NSDictionary<NSString *, NSString *> *prefixes = @{
      @"en": @"Current floor height ", @"ko": @"현재 층고 ", @"ja": @"現在の階高 ",
      @"zh-Hant": @"目前層高 "
    };
    NSString *hint = LocalizedQueryText(
        @"ufloorheight3.2（3.2:层高；可设置范围2-12米；默认3米）");
    return [NSString stringWithFormat:@"%@%@ m; %@", prefixes[language] ?: @"当前 ", value,
        LocalizedQueryText(hint)];
  }
  NSRegularExpression *floorPressureExpression = [NSRegularExpression
      regularExpressionWithPattern:@"^(.+?)层（扣除(.+?) MPa静压；按层高(.+?)米；未计管网损失）$"
      options:0 error:nil];
  NSTextCheckingResult *floorPressureMatch = [floorPressureExpression
      firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
  if (floorPressureMatch.numberOfRanges == 4) {
    NSString *(^capture)(NSUInteger) = ^NSString *(NSUInteger index) {
      return [text substringWithRange:[floorPressureMatch rangeAtIndex:index]];
    };
    NSDictionary<NSString *, NSString *> *templates = @{
      @"en": @"%@ floors (after reserving %@ MPa static pressure; %@ m per floor; pipe losses excluded)",
      @"ko": @"%@층 (정압 %@MPa 제외, 층고 %@m 기준; 배관 손실 미포함)",
      @"ja": @"%@階（静水圧%@ MPa控除、階高%@ m、配管損失を含まない）",
      @"zh-Hant": @"%@層（扣除%@ MPa靜壓；按層高%@米；未計管網損失）"
    };
    return [NSString stringWithFormat:templates[language] ?: text,
        capture(1), capture(2), capture(3)];
  }
  NSString *floorSaveSuffix = @" m · 停止输入约 1 秒后保存";
  if ([text hasSuffix:floorSaveSuffix]) {
    NSString *height = [text substringToIndex:text.length - floorSaveSuffix.length];
    NSDictionary<NSString *, NSString *> *templates = @{
      @"en": @"%@ m · saved after a 1-second pause", @"ko": @"%@m · 입력을 1초 멈추면 저장",
      @"ja": @"%@ m · 1秒停止後に保存", @"zh-Hant": @"%@ m · 停止輸入約 1 秒後儲存"
    };
    return [NSString stringWithFormat:templates[language] ?: text, height];
  }
  if ([text hasPrefix:@"类别1："] && [text containsString:@"（自定义）"]) {
    NSRegularExpression *settingExpression = [NSRegularExpression
        regularExpressionWithPattern:@"类别1：(.+?) MPa（>100米按(.+?)）；类别2：(.+?) MPa；类别3：(.+?) MPa（自定义）"
        options:0 error:nil];
    NSTextCheckingResult *match = [settingExpression firstMatchInString:text
        options:0 range:NSMakeRange(0, text.length)];
    if (match.numberOfRanges == 5) {
      NSString *(^capture)(NSUInteger) = ^NSString *(NSUInteger index) {
        return [text substringWithRange:[match rangeAtIndex:index]];
      };
      NSDictionary<NSString *, NSString *> *templates = @{
        @"en": @"Category 1: %@ MPa (use %@ above 100 m); category 2: %@ MPa; category 3: %@ MPa (custom)",
        @"ko": @"분류 1: %@MPa (100m 초과 시 %@ 적용); 분류 2: %@MPa; 분류 3: %@MPa (사용자 지정)",
        @"ja": @"分類1: %@ MPa（高さ100m超は%@を適用）；分類2: %@ MPa；分類3: %@ MPa（カスタム）",
        @"zh-Hant": @"類別1：%@ MPa（>100米按%@）；類別2：%@ MPa；類別3：%@ MPa（自訂）"
      };
      return [NSString stringWithFormat:templates[language] ?: text,
          capture(1), capture(2), capture(3), capture(4)];
    }
  }
  if ([text hasPrefix:@"格式：ufiredefault1-0.15"] ) {
    NSDictionary<NSString *, NSString *> *formats = @{
      @"en": @"Format: ufiredefault1-0.15 (category-static pressure in MPa; value must be >0 and ≤2.4)",
      @"ko": @"형식: ufiredefault1-0.15 (분류-정압 MPa; 0 초과, 2.4 이하)",
      @"ja": @"形式: ufiredefault1-0.15（分類-静水圧 MPa；0超、2.4以下）",
      @"zh-Hant": @"格式：ufiredefault1-0.15（類別1-靜壓MPa；數值大於0且不超過2.4）"
    };
    return formats[language] ?: text;
  }
  if ([text hasPrefix:@"ufiredefault1-0.15（类别1-压力MPa"] ) {
    NSDictionary<NSString *, NSString *> *hints = @{
      @"en": @"ufiredefault1-0.15 (category-pressure in MPa; category 2 default 0.07; category 3 default 0.01)",
      @"ko": @"ufiredefault1-0.15 (분류-정압 MPa; 분류 2 기본 0.07; 분류 3 기본 0.01)",
      @"ja": @"ufiredefault1-0.15（分類-静水圧 MPa；分類2の既定0.07；分類3の既定0.01）",
      @"zh-Hant": @"ufiredefault1-0.15（類別1-壓力MPa；類別2預設0.07；類別3預設0.01）"
    };
    return hints[language] ?: text;
  }
  if ([text hasPrefix:@"类别 "] && [text containsString:@" 参考静压 "] &&
      [text containsString:@"停顿约 1 秒保存"]) {
    NSRegularExpression *expression = [NSRegularExpression
        regularExpressionWithPattern:@"类别 (\\d) 参考静压 (.+?) MPa · 停顿约 1 秒保存"
        options:0 error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:text options:0
        range:NSMakeRange(0, text.length)];
    if (match.numberOfRanges == 3) {
      NSString *category = [text substringWithRange:[match rangeAtIndex:1]];
      NSString *value = [text substringWithRange:[match rangeAtIndex:2]];
      NSDictionary<NSString *, NSString *> *templates = @{
        @"en": @"Category %@ reference static pressure: %@ MPa · saved after a 1-second pause",
        @"ko": @"분류 %@ 참고 정압: %@MPa · 1초 입력 중단 후 저장",
        @"ja": @"分類%@の参考静水圧: %@ MPa · 1秒停止後に保存",
        @"zh-Hant": @"類別%@參考靜壓：%@ MPa · 停頓約 1 秒後儲存"
      };
      return [NSString stringWithFormat:templates[language] ?: text, category, value];
    }
  }
  if (words.count && [text hasSuffix:@"搜索引擎"]) {
    NSRange range = [text rangeOfString:@"已设为"];
    if (range.location != NSNotFound) {
      NSString *engine = [text substringToIndex:range.location];
      NSString *shortcut = [[text substringFromIndex:range.location + range.length]
          stringByReplacingOccurrencesOfString:@"搜索引擎" withString:@""];
      NSDictionary<NSString *, NSString *> *templates = @{
        @"en": @"%@ is now the search engine for %@", @"ko": @"%@을(를) %@ 검색 엔진으로 설정했습니다",
        @"ja": @"%@を%@の検索エンジンに設定しました", @"zh-Hant": @"%@已設為%@搜尋引擎"
      };
      NSString *localizedEngine = words[engine] ?: engine;
      return [NSString stringWithFormat:templates[language] ?: @"%@已设为%@搜索引擎",
          localizedEngine, shortcut];
    }
  }
  NSString *timeZonePrefix = @"时区时间（";
  if ([text hasPrefix:timeZonePrefix] && [text hasSuffix:@"）"]) {
    NSString *zoneName = [text substringWithRange:NSMakeRange(
        timeZonePrefix.length, text.length - timeZonePrefix.length - 1)];
    NSString *localizedPrefix = table[@"时区时间"] ?: @"时区时间";
    return [NSString stringWithFormat:@"%@（%@）", localizedPrefix, zoneName];
  }
  NSRange unitSuffix = [text rangeOfString:@" ("];
  if (unitSuffix.location != NSNotFound && [text hasSuffix:@")"]) {
    NSString *unitName = [text substringToIndex:unitSuffix.location];
    NSString *symbol = [text substringWithRange:NSMakeRange(
        unitSuffix.location + 2, text.length - unitSuffix.location - 3)];
    NSString *translatedUnit = table[unitName];
    if (translatedUnit)
      return [NSString stringWithFormat:@"%@ (%@)", translatedUnit, symbol];
  }
  if ([text isEqualToString:@"语言设置"]) {
    NSDictionary<NSString *, NSString *> *titles = @{
      @"en": @"Language", @"ko": @"언어", @"ja": @"言語"
    };
    return titles[language] ?: text;
  }
  NSString *widthPrefix = @"U 面板最大宽度已设为 ";
  if ([text hasPrefix:widthPrefix]) {
    NSString *width = [text substringFromIndex:widthPrefix.length];
    NSDictionary<NSString *, NSString *> *prefixes = @{
      @"en": @"U panel max width set to ", @"ko": @"U 패널 최대 너비: ",
      @"ja": @"U パネル最大幅: ", @"zh-Hant": @"U 面板最大寬度已設為 "
    };
    if (prefixes[language]) return [prefixes[language] stringByAppendingString:width];
  }
  NSDictionary<NSString *, NSString *> *widthHints = @{
    @"en": @" pt · Saved after a 1-second pause (200–2000)",
    @"ko": @" pt · 입력을 1초 멈추면 저장 (200–2000)",
    @"ja": @" pt · 1秒停止後に保存（200～2000）",
    @"zh-Hant": @" pt · 停止輸入約 1 秒後儲存（200–2000）"
  };
  NSString *widthHint = @" pt · 停止输入约 1 秒后保存（200–2000）";
  if ([text containsString:widthHint])
    text = [text stringByReplacingOccurrencesOfString:widthHint
        withString:widthHints[language] ?: widthHint];
  if ([language isEqualToString:@"zh-Hant"]) {
    NSMutableString *traditional = [text mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)traditional, NULL,
        CFSTR("Hans-Hant"), false);
    return traditional;
  }
  NSString *hint = table[@"输入停顿后自动查询"];
  if (hint && [text containsString:@"输入停顿后自动查询"])
    text = [text stringByReplacingOccurrencesOfString:@"输入停顿后自动查询" withString:hint];
  return text;
}

static CGFloat QueryConfiguredPanelMaxWidth(void) {
  if (!query_panel_max_width_loaded) {
    query_panel_max_width_loaded = YES;
    NSString *stored = [NSString stringWithContentsOfFile:
        QueryPanelWidthProfilePath() encoding:NSUTF8StringEncoding error:nil];
    NSString *trimmed = [stored stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSScanner *scanner = [NSScanner scannerWithString:trimmed ?: @""];
    NSInteger value = 0;
    if ([scanner scanInteger:&value] && scanner.isAtEnd &&
        value >= 200 && value <= 2000)
      query_panel_max_width = value;
  }
  return query_panel_max_width;
}

static NSString *SaveQueryPanelMaxWidth(NSString *payload) {
  if (!payload.length) return nil;
  if ([payload rangeOfCharacterFromSet:
      [NSCharacterSet characterSetWithCharactersInString:@"0123456789"]
          .invertedSet].location != NSNotFound)
    return @"宽度请输入 200–2000 的整数";
  NSInteger value = payload.integerValue;
  if (value < 200 || value > 2000)
    return @"宽度范围为 200–2000 pt";

  NSString *path = QueryPanelWidthProfilePath();
  if (![[NSFileManager defaultManager] createDirectoryAtPath:
      path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
      attributes:nil error:nil])
    return @"无法保存面板宽度设置";
  NSString *contents = [NSString stringWithFormat:@"%ld\n", (long)value];
  if (![contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding
                       error:nil])
    return @"无法保存面板宽度设置";
  [[NSFileManager defaultManager] setAttributes:
      @{NSFilePosixPermissions: @0600} ofItemAtPath:path error:nil];
  query_panel_max_width = value;
  query_panel_max_width_loaded = YES;
  return [NSString stringWithFormat:@"U 面板最大宽度已设为 %ld pt", (long)value];
}

static BOOL ParseFloorHeight(NSString *payload, double *height) {
  NSScanner *scanner = [NSScanner scannerWithString:payload ?: @""];
  scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  double value = 0;
  if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value) ||
      value < 2.0 || value > 12.0) return NO;
  if (height) *height = value;
  return YES;
}

static NSString *SaveQueryFloorHeight(NSString *payload) {
  double value = 0;
  if (!ParseFloorHeight(payload, &value))
    return @"层高请输入 2–12 米，例如 ufloorheight3.2";
  NSString *path = QueryFloorHeightProfilePath();
  if (![[NSFileManager defaultManager] createDirectoryAtPath:
      path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
      attributes:nil error:nil]) return @"无法保存层高设置";
  NSString *contents = [NSString stringWithFormat:@"%.3g\n", value];
  if (![contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding
                       error:nil]) return @"无法保存层高设置";
  [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600}
      ofItemAtPath:path error:nil];
  query_floor_height = value;
  query_floor_height_loaded = YES;
  return [NSString stringWithFormat:@"楼层估算层高已设为 %.3g 米", value];
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

static BOOL OpenQuerySearchForCandidate(CGKeyCode keycode, NSString *candidate) {
  if (!candidate.length) return NO;

  NSString *template = CurrentSearchEngineURL(keycode != kVK_ANSI_G);
  NSString *urlString = [template stringByReplacingOccurrencesOfString:@"{query}"
                                                              withString:QueryURLEncode(candidate)];
  NSURL *url = [NSURL URLWithString:urlString];
  return url && [[NSWorkspace sharedWorkspace] openURL:url];
}

static NSString *EscapeAppleScriptString(NSString *value) {
  return [[value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
      stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

static BOOL OpenInternalNewsExtensionForCandidate(NSString *candidate) {
#if defined(SQUIRREL_ENABLE_INTERNAL_NEWS_EXTENSION_ACTION)
  if (!candidate.length) return NO;
  NSString *templatePath =
      [@"~/Library/Rime/input_translation.news-url-template"
          stringByExpandingTildeInPath];
  NSDictionary *attributes = [[NSFileManager defaultManager]
      attributesOfItemAtPath:templatePath error:nil];
  if ([attributes fileSize] > 8192) return NO;
  NSString *urlTemplate = [NSString stringWithContentsOfFile:templatePath
      encoding:NSUTF8StringEncoding error:nil];
  urlTemplate = [urlTemplate stringByTrimmingCharactersInSet:
      NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!urlTemplate.length ||
      [urlTemplate rangeOfString:@"{query}"].location == NSNotFound) return NO;
  NSString *urlString = [urlTemplate stringByReplacingOccurrencesOfString:
      @"{query}" withString:QueryURLEncode(candidate)];
  NSURLComponents *components = [NSURLComponents
      componentsWithString:urlString];
  if (![components.scheme.lowercaseString isEqualToString:@"chrome-extension"] ||
      !components.host.length) return NO;

  NSURL *browserAppURL = [[NSWorkspace sharedWorkspace]
      URLForApplicationToOpenURL:[NSURL URLWithString:@"https://example.com"]];
  NSString *bundleID = [NSBundle bundleWithURL:browserAppURL].bundleIdentifier;
  if (!bundleID.length) return NO;
  NSString *scriptSource = [NSString stringWithFormat:
      @"tell application id \"%@\" to open location \"%@\"",
      EscapeAppleScriptString(bundleID), EscapeAppleScriptString(urlString)];
  NSAppleScript *script = [[NSAppleScript alloc]
      initWithSource:scriptSource];
  return [script executeAndReturnError:nil] != nil;
#else
  // The public build always consumes nnn but deliberately performs no action,
  // even when the user happens to have the unpublished extension installed.
  (void)candidate;
  return NO;
#endif
}

static void OpenQuerySearch(CGKeyCode keycode) {
  ResetQueryRepeatAction();
  OpenQuerySearchForCandidate(keycode, SelectedQueryCandidate());
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

static BOOL EnsurePhoneData(void) {
  if (!query_phone_data) {
    NSString *path = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:
            @"Contents/Frameworks/rime-plugins/phone-region-phone.dat"];
    query_phone_data = [NSData dataWithContentsOfFile:path
        options:NSDataReadingMappedIfSafe error:nil];
  }
  if (query_phone_data.length < 8) return NO;
  uint32_t indexStart = 0;
  memcpy(&indexStart, query_phone_data.bytes + 4, sizeof(indexStart));
  indexStart = CFSwapInt32LittleToHost(indexStart);
  return indexStart < query_phone_data.length &&
      (query_phone_data.length - indexStart) % 9 == 0;
}

static BOOL IsKnownPhonePrefix(NSString *prefix) {
  if (prefix.length != 3 || ![prefix hasPrefix:@"1"] || !EnsurePhoneData())
    return NO;
  uint32_t indexStart = 0;
  memcpy(&indexStart, query_phone_data.bytes + 4, sizeof(indexStart));
  indexStart = CFSwapInt32LittleToHost(indexStart);
  NSUInteger count = (query_phone_data.length - indexStart) / 9;
  uint32_t lowerBound = (uint32_t)(prefix.intValue * 10000);
  uint32_t upperBound = lowerBound + 10000;
  NSUInteger left = 0, right = count;
  const uint8_t *bytes = query_phone_data.bytes;
  while (left < right) {
    NSUInteger middle = left + (right - left) / 2;
    uint32_t current = 0;
    memcpy(&current, bytes + indexStart + middle * 9, sizeof(current));
    current = CFSwapInt32LittleToHost(current);
    if (current < lowerBound) left = middle + 1;
    else right = middle;
  }
  if (left >= count) return NO;
  uint32_t current = 0;
  memcpy(&current, bytes + indexStart + left * 9, sizeof(current));
  current = CFSwapInt32LittleToHost(current);
  return current < upperBound;
}

typedef NS_ENUM(NSInteger, PhoneInputStatus) {
  PhoneInputInvalid,
  PhoneInputIncomplete,
  PhoneInputComplete,
};

static BOOL IsDirectPhoneQueryText(NSString *text) {
  if ([text hasPrefix:@"+"] || [text hasPrefix:@"("] ||
      [text hasPrefix:@"（"]) return YES;
  if (text.length < 3) return NO;
  if (text.length >= 3 && IsKnownPhonePrefix([text substringToIndex:3]))
    return YES;
  for (NSString *code in @[@"010", @"020", @"021", @"022", @"023",
                            @"024", @"025", @"027", @"028", @"029",
                            @"0571", @"0755", @"0773", @"0871"]) {
    if ([code hasPrefix:text] || [text hasPrefix:code]) return YES;
  }
  return NO;
}

static NSArray<NSString *> *KnownLandlineAreaCodes(void) {
  static NSArray<NSString *> *codes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    codes = @[@"0571", @"0755", @"0773", @"0871", @"010", @"021",
              @"022", @"023", @"020", @"024", @"025", @"027",
              @"028", @"029"];
  });
  return codes;
}

static NSString *LandlineRegionForAreaCode(NSString *code) {
  static NSDictionary<NSString *, NSString *> *regions;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    regions = @{
      @"010": @"北京", @"021": @"上海", @"022": @"天津",
      @"023": @"重庆", @"020": @"广州", @"024": @"沈阳",
      @"025": @"南京", @"027": @"武汉", @"028": @"成都",
      @"029": @"西安", @"0571": @"杭州", @"0755": @"深圳",
      @"0773": @"桂林", @"0871": @"昆明",
    };
  });
  return regions[code];
}

static PhoneInputStatus ValidatePhoneInput(NSString **normalizedDigits,
                                           NSString **landlineAreaCode) {
  if (landlineAreaCode) *landlineAreaCode = nil;
  NSString *payload = query_phone_prefix_active ? query_text :
      UtilityPayload(query_text, @"phone");
  if (!payload) return PhoneInputInvalid;
  payload = [[[[payload stringByReplacingOccurrencesOfString:@"（" withString:@"("]
      stringByReplacingOccurrencesOfString:@"）" withString:@")"]
      stringByReplacingOccurrencesOfString:@"\u00a0" withString:@" "]
      stringByReplacingOccurrencesOfString:@"\u202f" withString:@" "];
  NSCharacterSet *allowed = [NSCharacterSet
      characterSetWithCharactersInString:@"0123456789+ ()-"];
  if ([payload rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound)
    return PhoneInputInvalid;

  NSUInteger opening = 0, closing = 0;
  for (NSUInteger index = 0; index < payload.length; ++index) {
    unichar character = [payload characterAtIndex:index];
    if (character == '(') ++opening;
    else if (character == ')') ++closing;
  }
  if (opening != closing || opening > 1) return PhoneInputInvalid;

  NSString *parenthesizedArea = nil;
  NSRange leftParen = [payload rangeOfString:@"("];
  if (leftParen.location != NSNotFound) {
    NSRange rightParen = [payload rangeOfString:@")"];
    if (rightParen.location <= leftParen.location + 1) return PhoneInputInvalid;
    parenthesizedArea = [payload substringWithRange:NSMakeRange(
        leftParen.location + 1, rightParen.location - leftParen.location - 1)];
    if ([parenthesizedArea rangeOfCharacterFromSet:
        NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound)
      return PhoneInputInvalid;
  }

  NSString *compact = [[payload componentsSeparatedByCharactersInSet:
      [NSCharacterSet characterSetWithCharactersInString:@" ()-"]]
      componentsJoinedByString:@""];
  BOOL hasPlus = [compact hasPrefix:@"+"];
  if ([compact containsString:@"+"] &&
      (!hasPlus || [compact rangeOfString:@"+" options:0
          range:NSMakeRange(1, compact.length - 1)].location != NSNotFound))
    return PhoneInputInvalid;
  NSString *digits = hasPlus ? [compact substringFromIndex:1] : compact;

  BOOL hasCountryCode = NO;
  if (hasPlus) {
    if (![digits hasPrefix:@"86"]) {
      if (digits.length == 0 || (digits.length == 1 && [digits isEqualToString:@"8"])) {
        if (normalizedDigits) *normalizedDigits = @"";
        return PhoneInputIncomplete;
      }
      return PhoneInputInvalid;
    }
    digits = [digits substringFromIndex:2];
    hasCountryCode = YES;
  } else if ([digits hasPrefix:@"86"] && digits.length == 13) {
    digits = [digits substringFromIndex:2];
    hasCountryCode = YES;
  } else if ([digits hasPrefix:@"86"] && digits.length > 11) {
    NSString *partial = [digits substringFromIndex:2];
    if (![partial hasPrefix:@"1"] && partial.length > 0)
      return PhoneInputInvalid;
    if (normalizedDigits) *normalizedDigits = partial;
    return PhoneInputIncomplete;
  }

  if (digits.length == 0) {
    if (normalizedDigits) *normalizedDigits = @"";
    return PhoneInputIncomplete;
  }
  if (![digits hasPrefix:@"1"]) {
    NSString *area = nil;
    if (parenthesizedArea.length) {
      area = [parenthesizedArea hasPrefix:@"0"] ? parenthesizedArea :
          [@"0" stringByAppendingString:parenthesizedArea];
      NSString *prefix = parenthesizedArea;
      if (![digits hasPrefix:prefix]) return PhoneInputInvalid;
      digits = [digits substringFromIndex:prefix.length];
    } else {
      for (NSString *candidate in KnownLandlineAreaCodes()) {
        NSString *withoutTrunkZero = [candidate substringFromIndex:1];
        BOOL hasTrunkPrefix = [digits hasPrefix:candidate];
        BOOL hasInternationalPrefix = hasCountryCode &&
            [digits hasPrefix:withoutTrunkZero];
        if (hasTrunkPrefix || hasInternationalPrefix) {
          area = candidate;
          NSUInteger prefixLength = hasTrunkPrefix ? candidate.length :
              withoutTrunkZero.length;
          digits = [digits substringFromIndex:prefixLength];
          break;
        }
      }
    }
    if (!area || area.length < 3 || area.length > 4 || digits.length > 8)
      return PhoneInputInvalid;
    if (landlineAreaCode) *landlineAreaCode = area;
    if (normalizedDigits) *normalizedDigits = digits;
    return digits.length >= 7 ? PhoneInputComplete : PhoneInputIncomplete;
  }
  if (parenthesizedArea.length) return PhoneInputInvalid;
  if (digits.length >= 2) {
    unichar second = [digits characterAtIndex:1];
    if (second < '3' || second > '9') return PhoneInputInvalid;
  }
  if (digits.length >= 3 && !IsKnownPhonePrefix([digits substringToIndex:3]))
    return PhoneInputInvalid;
  if (digits.length > 11) return PhoneInputInvalid;
  if (normalizedDigits) *normalizedDigits = digits;
  return digits.length == 11 ? PhoneInputComplete : PhoneInputIncomplete;
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

static BOOL IsBareDateQuery(void);

static BOOL IsDateQuery(void) {
  return UtilityPayload(query_text, @"date") != nil || IsBareDateQuery();
}

static BOOL IsUnitQuery(void) {
  return UtilityPayload(query_text, @"conv") != nil;
}

static BOOL IsKeywordInputMode(void) {
  return IsColorQuery() || IsTimeQuery() || IsDateQuery() || IsUnitQuery() ||
      UtilityPayload(query_text, @"maxwidth") != nil ||
      UtilityPayload(query_text, @"floorheight") != nil ||
      UtilityPayload(query_text, @"firedefault") != nil ||
      UtilityPayload(query_text, @"lang") != nil ||
      UtilityPayload(query_text, @"ip") != nil ||
      UtilityPayload(query_text, @"phone") != nil || query_phone_prefix_active ||
      QuerySearchEngineURL(query_text) != nil;
}

static NSString *ActiveUtilityKeyword(void) {
  // yanse is an alias for the color tool; show the English word whose
  // pronunciation appears in the result column.
  if (UtilityPayload(query_text, @"yanse") != nil) return @"color";
  if (query_phone_prefix_active) return @"phone";
  for (NSString *keyword in @[@"color", @"time", @"date", @"conv", @"lang",
                             @"ip", @"phone", @"firedefault"]) {
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
  NSString *normalized = value;
  if (value.length == 8) {
    BOOL digitsOnly = YES;
    for (NSUInteger index = 0; index < value.length; ++index) {
      unichar character = [value characterAtIndex:index];
      if (character < '0' || character > '9') { digitsOnly = NO; break; }
    }
    if (!digitsOnly) return nil;
    formatter.dateFormat = @"yyyyMMdd";
    NSDate *compactDate = [formatter dateFromString:value];
    if (!compactDate || ![[formatter stringFromDate:compactDate]
                          isEqualToString:value]) return nil;
    formatter.dateFormat = @"yyyy-MM-dd";
    return compactDate;
  }
  formatter.dateFormat = @"yyyy-MM-dd";
  NSDate *date = [formatter dateFromString:normalized];
  return date && [[formatter stringFromDate:date] isEqualToString:normalized] ? date : nil;
}

static NSArray<NSString *> *SplitCompactDateRange(NSString *value) {
  if (value.length != 17) return nil;
  unichar separator = [value characterAtIndex:8];
  if (separator != '.' && separator != '-' && separator != ' ') return nil;
  NSString *first = [value substringToIndex:8];
  NSString *second = [value substringFromIndex:9];
  return DateFromISO8601Day(first) && DateFromISO8601Day(second) ?
      @[first, second] : nil;
}

static BOOL IsASCIIDigitString(NSString *value) {
  if (!value.length) return NO;
  for (NSUInteger index = 0; index < value.length; ++index) {
    unichar character = [value characterAtIndex:index];
    if (character < '0' || character > '9') return NO;
  }
  return YES;
}

static BOOL IsBareDateQuery(void) {
  NSString *value = query_text;
  if (value.length == 8) return IsASCIIDigitString(value);
  if (value.length < 9 || value.length > 17 ||
      !IsASCIIDigitString([value substringToIndex:8])) return NO;
  unichar separator = [value characterAtIndex:8];
  if (separator != '.' && separator != '-' && separator != ' ') return NO;
  NSString *end = [value substringFromIndex:9];
  if (end.length > 8) return NO;
  for (NSUInteger index = 0; index < end.length; ++index) {
    unichar character = [end characterAtIndex:index];
    if (character < '0' || character > '9') return NO;
  }
  return YES;
}

static NSString *DateQueryPayload(void) {
  NSString *payload = UtilityPayload(query_text, @"date");
  return payload ?: (IsBareDateQuery() ? query_text : nil);
}

static NSString *UtilityNumber(double value) {
  char buffer[64];
  snprintf(buffer, sizeof(buffer), "%.7g", value);
  return [NSString stringWithUTF8String:buffer];
}

static NSString *FloorEstimateResult(double floors, double floorHeight) {
  NSString *count = [NSString stringWithFormat:@"%.1f", floors];
  NSString *height = UtilityNumber(floorHeight);
  NSString *language = QueryUILanguage();
  if ([language isEqualToString:@"en"])
    return [NSString stringWithFormat:@"%@ floors (%@ m/floor; theoretical)", count, height];
  if ([language isEqualToString:@"ko"])
    return [NSString stringWithFormat:@"%@층 (층고 %@ m 기준, 이론값)", count, height];
  if ([language isEqualToString:@"ja"])
    return [NSString stringWithFormat:@"%@階（階高 %@ m の理論値）", count, height];
  if ([language isEqualToString:@"zh-Hant"])
    return [NSString stringWithFormat:@"%@ 層（按層高%@米估算約在%@層）", count, height, count];
  return [NSString stringWithFormat:@"%@层（按层高%@米估算约在%@层）", count, height, count];
}

static NSString *PressureFloorEstimateResult(double floors, double floorHeight,
                                              NSInteger category,
                                              BOOL showCategory) {
  NSString *count = [NSString stringWithFormat:@"%.1f", floors];
  NSString *height = UtilityNumber(floorHeight);
  if (!showCategory) {
    if ([QueryUILanguage() isEqualToString:@"en"])
      return [NSString stringWithFormat:@"%@ floors (at %@ m/floor)", count, height];
    if ([QueryUILanguage() isEqualToString:@"ko"])
      return [NSString stringWithFormat:@"%@층 (층고 %@m 기준)", count, height];
    if ([QueryUILanguage() isEqualToString:@"ja"])
      return [NSString stringWithFormat:@"%@階（階高%@ mで換算）", count, height];
    if ([QueryUILanguage() isEqualToString:@"zh-Hant"])
      return [NSString stringWithFormat:@"%@層（按層高%@米估算）", count, height];
    return [NSString stringWithFormat:@"%@层（按层高%@米估算）", count, height];
  }
  NSString *localizedCategory = nil;
  NSString *language = QueryUILanguage();
  if (category == 1) {
    NSDictionary *names = @{@"zh-Hans": @"一类高层", @"zh-Hant": @"一類高層",
        @"en": @"Class I high-rise", @"ko": @"1급 고층", @"ja": @"一類高層"};
    localizedCategory = names[language];
  } else if (category == 2) {
    NSDictionary *names = @{@"zh-Hans": @"二类高层", @"zh-Hant": @"二類高層",
        @"en": @"Class II high-rise/multistory", @"ko": @"2급 고층/다층", @"ja": @"二類高層／多層"};
    localizedCategory = names[language];
  } else {
    NSDictionary *names = @{@"zh-Hans": @"其它建筑", @"zh-Hant": @"其他建築",
        @"en": @"Other buildings", @"ko": @"기타 건축물", @"ja": @"その他の建築物"};
    localizedCategory = names[language];
  }
  if ([language isEqualToString:@"en"])
    return [NSString stringWithFormat:@"%@ floors (at %@ m/floor; %@ static-pressure estimate)", count, height, localizedCategory];
  if ([language isEqualToString:@"ko"])
    return [NSString stringWithFormat:@"%@층 (층고 %@m, %@ 정압 추정)", count, height, localizedCategory];
  if ([language isEqualToString:@"ja"])
    return [NSString stringWithFormat:@"%@階（階高%@ m、%@の静水圧による推定）", count, height, localizedCategory];
  if ([language isEqualToString:@"zh-Hant"])
    return [NSString stringWithFormat:@"%@層（按層高%@米、%@靜壓估算）", count, height, localizedCategory];
  return [NSString stringWithFormat:@"%@层（按层高%@米、%@静压估算）", count, height, localizedCategory];
}

static NSString *FloorHeightSettingHint(void) {
  NSString *language = QueryUILanguage();
  if ([language isEqualToString:@"en"])
    return @"ufloorheight3.2 (3.2: floor height; range 2–12 m; default 3 m)";
  if ([language isEqualToString:@"ko"])
    return @"ufloorheight3.2 (3.2: 층고; 범위 2–12m; 기본 3m)";
  if ([language isEqualToString:@"ja"])
    return @"ufloorheight3.2（3.2:階高；範囲2～12m；既定3m）";
  if ([language isEqualToString:@"zh-Hant"])
    return @"ufloorheight3.2（3.2：層高；可設定範圍2-12米；預設3米）";
  return @"ufloorheight3.2（3.2：层高；可设置范围2-12米；默认3米）";
}

static NSString *FireStaticPressureSettingHint(void) {
  NSString *class1 = UtilityNumber(QueryFireStaticPressureMPa(1));
  NSString *class2 = UtilityNumber(QueryFireStaticPressureMPa(2));
  NSString *other = UtilityNumber(QueryFireStaticPressureMPa(3));
  NSString *language = QueryUILanguage();
  if ([language isEqualToString:@"en"])
    return [NSString stringWithFormat:@"ufiredefault1-0.15 (Class I: %@ MPa; Class II: %@ MPa; other buildings: %@ MPa; default: 0.01 MPa)", class1, class2, other];
  if ([language isEqualToString:@"ko"])
    return [NSString stringWithFormat:@"ufiredefault1-0.15 (1급 고층: %@MPa; 2급/다층: %@MPa; 기타 건축물: %@MPa; 기본값: 0.01MPa)", class1, class2, other];
  if ([language isEqualToString:@"ja"])
    return [NSString stringWithFormat:@"ufiredefault1-0.15（一類高層: %@ MPa；二類高層: %@ MPa；その他の建築物: %@ MPa；既定値: 0.01 MPa）", class1, class2, other];
  if ([language isEqualToString:@"zh-Hant"])
    return [NSString stringWithFormat:@"ufiredefault1-0.15（一類高層：%@MPa；二類高層：%@MPa；其他建築：%@MPa；預設0.01MPa）", class1, class2, other];
  return [NSString stringWithFormat:@"ufiredefault1-0.15（一类高层：%@MPa；二类高层：%@MPa；其它建筑：%@MPa；默认0.01MPa）", class1, class2, other];
}

static BOOL ParseFireStaticPressureDefault(NSString *payload,
                                           NSInteger *category,
                                           double *pressureMPa) {
  if (payload.length < 3) return NO;
  unichar categoryCharacter = [payload characterAtIndex:0];
  if (categoryCharacter < '1' || categoryCharacter > '3' ||
      [payload characterAtIndex:1] != '-') return NO;
  NSString *valueString = [payload substringFromIndex:2];
  NSScanner *scanner = [NSScanner scannerWithString:valueString];
  scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  double value = 0;
  if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value) ||
      value <= 0 || value > 2.4) return NO;
  if (category) *category = categoryCharacter - '0';
  if (pressureMPa) *pressureMPa = value;
  return YES;
}

static NSString * __attribute__((unused)) TimeZoneCityLabel(NSTimeZone *zone) {
  static NSDictionary<NSString *, NSString *> *labels;
  static dispatch_once_t token;
  dispatch_once(&token, ^{
    labels = @{
      @"America/New_York": @"纽约时间", @"America/Los_Angeles": @"洛杉矶时间",
      @"America/Chicago": @"芝加哥时间", @"Europe/London": @"伦敦时间",
      @"Europe/Paris": @"巴黎时间", @"Asia/Tokyo": @"东京时间",
      @"Asia/Seoul": @"首尔时间", @"Asia/Singapore": @"新加坡时间",
      @"Asia/Hong_Kong": @"香港时间", @"Asia/Taipei": @"台北时间",
      @"Australia/Sydney": @"悉尼时间", @"Pacific/Auckland": @"奥克兰时间",
      @"Asia/Shanghai": @"北京时间", @"Asia/Dubai": @"迪拜时间"
    };
  });
  return labels[zone.name] ?: [NSString stringWithFormat:@"时区时间（%@）", zone.name];
}

static NSArray<NSArray<NSString *> *> *RowsForTimeQuery(void) {
  NSString *payload = UtilityPayload(query_text, @"time");
  NSString *value = [payload stringByTrimmingCharactersInSet:
      NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!query_time_snapshot) query_time_snapshot = [NSDate date];
  NSDate *date = query_time_snapshot;
  NSTimeZone *displayZone = NSTimeZone.localTimeZone;
  NSString *timeZoneLabel = nil;
  BOOL hasExplicitTimeZone = NO;
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
      static NSDictionary<NSString *, NSString *> *aliases;
      static NSDictionary<NSString *, NSString *> *cityLabels;
      static NSDictionary<NSString *, NSString *> *aliasLabels;
      static dispatch_once_t aliasToken;
      dispatch_once(&aliasToken, ^{
        aliases = @{
          @"niuyue": @"America/New_York", @"luoshanji": @"America/Los_Angeles",
          @"jiujinshan": @"America/Los_Angeles", @"zhijiage": @"America/Chicago",
          @"lundun": @"Europe/London", @"bali": @"Europe/Paris",
          @"dongjing": @"Asia/Tokyo", @"shouer": @"Asia/Seoul",
          @"xinjiapo": @"Asia/Singapore", @"xianggang": @"Asia/Hong_Kong",
          @"taibei": @"Asia/Taipei", @"xini": @"Australia/Sydney",
          @"aokelan": @"Pacific/Auckland", @"beijing": @"Asia/Shanghai",
          @"shanghai": @"Asia/Shanghai", @"dibai": @"Asia/Dubai"
        };
        cityLabels = @{
          @"America/New_York": @"纽约时间", @"America/Los_Angeles": @"洛杉矶时间",
          @"America/Chicago": @"芝加哥时间", @"Europe/London": @"伦敦时间",
          @"Europe/Paris": @"巴黎时间", @"Asia/Tokyo": @"东京时间",
          @"Asia/Seoul": @"首尔时间", @"Asia/Singapore": @"新加坡时间",
          @"Asia/Hong_Kong": @"香港时间", @"Asia/Taipei": @"台北时间",
          @"Australia/Sydney": @"悉尼时间", @"Pacific/Auckland": @"奥克兰时间",
          @"Asia/Shanghai": @"北京时间", @"Asia/Dubai": @"迪拜时间"
        };
        aliasLabels = @{
          @"jiujinshan": @"旧金山时间", @"beijing": @"北京时间",
          @"shanghai": @"上海时间"
        };
      });
      NSString *zoneName = aliases[value.lowercaseString] ?: value;
      NSTimeZone *zone = [NSTimeZone timeZoneWithName:zoneName];
      if (!zone) return @[
        @[@"时区或时间戳", @"输入 Unix 秒／毫秒、时区名或城市拼音（如 niuyue）"]
      ];
      displayZone = zone;
      timeZoneLabel = aliasLabels[value.lowercaseString] ?: cityLabels[zone.name];
      hasExplicitTimeZone = YES;
    }
  }
  int64_t seconds = (int64_t)floor(date.timeIntervalSince1970);
  NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray arrayWithArray:@[
    @[TimeZoneCityLabel(NSTimeZone.localTimeZone), FormatDateForZone(date, NSTimeZone.localTimeZone)],
  ]];
  if (hasExplicitTimeZone) {
    NSString *label = timeZoneLabel ?: [NSString stringWithFormat:@"时区时间（%@）", displayZone.name];
    [rows addObject:@[label, FormatDateForZone(date, displayZone)]];
  }
  [rows addObjectsFromArray:@[
    @[@"UTC", FormatDateForZone(date, [NSTimeZone timeZoneForSecondsFromGMT:0])],
    @[@"Unix 秒", [NSString stringWithFormat:@"%lld", (long long)seconds]],
    @[@"Unix 毫秒", [NSString stringWithFormat:@"%lld", (long long)llround(date.timeIntervalSince1970 * 1000.0)]]
  ]];
  return rows;
}

static NSArray<NSArray<NSString *> *> *RowsForDateQuery(void) {
  NSString *payload = DateQueryPayload();
  NSString *value = [payload stringByTrimmingCharactersInSet:
      NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSArray<NSString *> *dates = [value componentsSeparatedByString:@".."];
  if (dates.count == 1) {
    NSArray<NSString *> *compactRange = SplitCompactDateRange(value);
    if (compactRange) dates = compactRange;
  }
  if (dates.count == 1 && value.length) {
    NSDateFormatter *todayFormatter = [[NSDateFormatter alloc] init];
    todayFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    todayFormatter.timeZone = NSTimeZone.localTimeZone;
    todayFormatter.dateFormat = @"yyyy-MM-dd";
    NSDate *date = DateFromISO8601Day(value);
    if (!date) return @[
      @[@"日期格式", @"单日期 YYYYMMDD；双日期用单个 .、- 或空格分隔"]
    ];
    NSString *todayString = [todayFormatter stringFromDate:[NSDate date]];
    NSDate *today = DateFromISO8601Day(todayString);
    int64_t days = (int64_t)llround([date timeIntervalSinceDate:today] / 86400.0);
    NSString *label = days < 0 ? @"过去天数" :
        (days > 0 ? @"剩余天数" : @"今天");
    NSDateFormatter *displayFormatter = [[NSDateFormatter alloc] init];
    displayFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    displayFormatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    displayFormatter.dateFormat = @"yyyy-MM-dd";
    NSString *targetString = [displayFormatter stringFromDate:date];
    NSString *startDate = days < 0 ? targetString : todayString;
    NSString *endDate = days < 0 ? todayString : targetString;
    return @[
      @[label, [NSString stringWithFormat:@"%lld 天", (long long)llabs(days)]],
      @[@"开始日期", startDate],
      @[@"结束日期", endDate],
    ];
  }
  if (dates.count != 2) return @[
    @[@"日期间隔", @"双日期格式：YYYYMMDD.YYYYMMDD（分隔符用单个 .、- 或空格）"]
  ];
  NSDate *start = DateFromISO8601Day(dates[0]);
  NSDate *end = DateFromISO8601Day(dates[1]);
  if (!start || !end) return @[
    @[@"日期格式", @"无效日期；双日期请用 YYYYMMDD.YYYYMMDD"]
  ];
  int64_t days = (int64_t)llround([end timeIntervalSinceDate:start] / 86400.0);
  return @[
    @[@"相差天数", [NSString stringWithFormat:@"%lld 天", (long long)labs(days)]],
    @[@"开始日期", dates[0]],
    @[@"结束日期", dates[1]],
  ];
}

typedef NS_ENUM(NSInteger, STUnitDimension) {
  STUnitLength, STUnitMass, STUnitVolume, STUnitTemperature,
  STUnitPressure, STUnitVoltage, STUnitCurrent, STUnitPower,
  STUnitResistance, STUnitEnergy, STUnitFrequency, STUnitCapacitance,
  STUnitInductance, STUnitCharge
};

typedef struct {
  __unsafe_unretained NSString *key;
  __unsafe_unretained NSString *symbol;
  __unsafe_unretained NSString *name;
  double factor;
} STUnitDefinition;

static const STUnitDefinition pressure[] = {
  {@"pa", @"Pa", @"帕", 1.0}, {@"kpa", @"kPa", @"千帕", 1000.0},
  {@"mpa", @"MPa", @"兆帕", 1000000.0},
  // NIST SP 811: conventional mmHg, not mass or an assumed piston area.
  {@"kgf/cm²", @"kgf/cm²", @"公斤压力", 98066.5},
  {@"mmhg", @"mmHg", @"毫米汞柱", 133.3224},
  {@"mh2o", @"mH₂O", @"水柱高度", 9806.65}
};

typedef struct {
  __unsafe_unretained NSString *code;
  __unsafe_unretained NSString *name;
} STCurrencyDefinition;

static const STCurrencyDefinition kCommonCurrencies[] = {
  {@"CNY", @"人民币"}, {@"USD", @"美元"}, {@"EUR", @"欧元"},
  {@"JPY", @"日元"}, {@"GBP", @"英镑"}, {@"HKD", @"港币"},
  {@"TWD", @"新台币"}, {@"SGD", @"新加坡元"},
  {@"CAD", @"加拿大元"}, {@"AUD", @"澳大利亚元"},
  {@"KRW", @"韩元"}, {@"CHF", @"瑞士法郎"}, {@"THB", @"泰铢"}
};

static NSString *CurrencyCodeForUnit(NSString *unit) {
  static NSDictionary<NSString *, NSString *> *aliases;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    aliases = @{
      @"rmb": @"CNY", @"cny": @"CNY", @"cn": @"CNY", @"china": @"CNY",
      @"rmb(cn)": @"CNY", @"rmb（cn）": @"CNY",
      @"usa": @"USD", @"us": @"USD", @"usd": @"USD",
      @"usa(us)": @"USD", @"usa（us）": @"USD",
      @"euro": @"EUR", @"eu": @"EUR", @"eur": @"EUR",
      @"jp": @"JPY", @"jpy": @"JPY", @"japan": @"JPY",
      @"jp(jpy)": @"JPY", @"jp（jpy）": @"JPY",
      @"uk": @"GBP", @"gb": @"GBP", @"gbp": @"GBP",
      @"uk(gbp)": @"GBP", @"uk（gbp）": @"GBP",
      @"hk": @"HKD", @"hkd": @"HKD", @"tw": @"TWD", @"twd": @"TWD",
      @"ntd": @"TWD", @"sg": @"SGD", @"sgd": @"SGD",
      @"ca": @"CAD", @"cad": @"CAD", @"au": @"AUD", @"aud": @"AUD",
      @"kr": @"KRW", @"krw": @"KRW", @"ch": @"CHF", @"chf": @"CHF",
      @"th": @"THB", @"thb": @"THB"
    };
  });
  return aliases[unit.lowercaseString];
}

static NSArray<NSArray<NSString *> *> *CurrencyRowsForRates(
    double amount, NSString *baseCode, NSDictionary *cachedRates) {
  NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray array];
  NSString *baseName = baseCode;
  for (size_t index = 0;
       index < sizeof(kCommonCurrencies) / sizeof(kCommonCurrencies[0]); ++index) {
    if ([baseCode isEqualToString:kCommonCurrencies[index].code]) {
      baseName = kCommonCurrencies[index].name;
      break;
    }
  }
  [rows addObject:@[[NSString stringWithFormat:@"%@ (%@)", baseName, baseCode],
                    [NSString stringWithFormat:@"%@ %@", UtilityNumber(amount), baseCode]]];
  NSDictionary *rates = [cachedRates[@"rates"] isKindOfClass:NSDictionary.class] ?
      cachedRates[@"rates"] : @{};
  NSDictionary *dates = [cachedRates[@"dates"] isKindOfClass:NSDictionary.class] ?
      cachedRates[@"dates"] : @{};
  for (size_t index = 0;
       index < sizeof(kCommonCurrencies) / sizeof(kCommonCurrencies[0]); ++index) {
    NSString *code = kCommonCurrencies[index].code;
    if ([code isEqualToString:baseCode]) continue;
    NSNumber *rate = [rates[code] isKindOfClass:NSNumber.class] ? rates[code] : nil;
    if (!rate || !isfinite(rate.doubleValue) || rate.doubleValue <= 0) continue;
    double converted = amount * rate.doubleValue;
    if (!isfinite(converted))
      return @[@[@"数值超出范围", @"请缩小输入金额"]];
    NSString *rateDate = [dates[code] isKindOfClass:NSString.class] ? dates[code] : @"";
    NSString *result = [NSString stringWithFormat:@"%@ %@%@",
        UtilityNumber(converted), code,
        rateDate.length ? [NSString stringWithFormat:@" · %@参考汇率", rateDate] : @""];
    [rows addObject:@[[NSString stringWithFormat:@"%@ (%@)",
        kCommonCurrencies[index].name, code], result]];
  }
  return rows;
}

static void ScheduleCurrencyLookup(NSString *payload, double amount,
                                   NSString *baseCode) {
  if ([query_currency_payload isEqualToString:payload] &&
      query_currency_rows.count) return;
  query_currency_payload = [payload copy];
  query_currency_rows = @[@[@"货币换算", @"正在获取每日参考汇率…"]];
  NSUInteger generation = query_utility_generation;
  if (!query_currency_rate_cache)
    query_currency_rate_cache = [NSMutableDictionary dictionary];
  NSDictionary *cache = query_currency_rate_cache[baseCode];
  NSDate *fetchedAt = [cache[@"fetchedAt"] isKindOfClass:NSDate.class] ?
      cache[@"fetchedAt"] : nil;
  NSDictionary *rates = [cache[@"data"] isKindOfClass:NSDictionary.class] ?
      cache[@"data"] : nil;
  if (rates && fetchedAt && [[NSDate date] timeIntervalSinceDate:fetchedAt] < 3600) {
    query_currency_rows = CurrencyRowsForRates(amount, baseCode, rates);
    return;
  }
  NSString *expectedQuery = [query_text copy];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
    if (!query_active || generation != query_utility_generation ||
        ![UtilityPayload(query_text, @"conv") isEqualToString:payload]) return;
    NSMutableArray<NSString *> *quotes = [NSMutableArray array];
    for (size_t index = 0;
         index < sizeof(kCommonCurrencies) / sizeof(kCommonCurrencies[0]); ++index) {
      NSString *code = kCommonCurrencies[index].code;
      if (![code isEqualToString:baseCode]) [quotes addObject:code];
    }
    NSURLComponents *components =
        [NSURLComponents componentsWithString:@"https://api.frankfurter.dev/v2/rates"];
    components.queryItems = @[
      [NSURLQueryItem queryItemWithName:@"base" value:baseCode],
      [NSURLQueryItem queryItemWithName:@"quotes"
                                  value:[quotes componentsJoinedByString:@","]]
    ];
    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:components.URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:6.0];
    query_currency_task = [NSURLSession.sharedSession
        dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
      id json = data ? [NSJSONSerialization JSONObjectWithData:data
          options:0 error:nil] : nil;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!query_active || generation != query_utility_generation ||
            ![query_text isEqualToString:expectedQuery] ||
            ![UtilityPayload(query_text, @"conv") isEqualToString:payload]) return;
        query_currency_task = nil;
        if (error || http.statusCode < 200 || http.statusCode >= 300 ||
            ![json isKindOfClass:NSArray.class]) {
          query_currency_rows = @[@[@"汇率查询失败", @"网络不可用或服务暂不可达"]];
        } else {
          NSMutableDictionary *rateValues = [NSMutableDictionary dictionary];
          NSMutableDictionary *rateDates = [NSMutableDictionary dictionary];
          for (id item in (NSArray *)json) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            NSString *code = [item[@"quote"] isKindOfClass:NSString.class] ?
                [item[@"quote"] uppercaseString] : @"";
            NSNumber *rate = [item[@"rate"] isKindOfClass:NSNumber.class] ?
                item[@"rate"] : nil;
            if (!rate || !isfinite(rate.doubleValue) || rate.doubleValue <= 0) continue;
            rateValues[code] = rate;
            if ([item[@"date"] isKindOfClass:NSString.class])
              rateDates[code] = item[@"date"];
          }
          NSDictionary *rateData = @{@"rates": rateValues, @"dates": rateDates};
          if (!rateValues.count) {
            query_currency_rows = @[@[@"暂无汇率数据", @"该币种暂不受支持"]];
          } else {
            query_currency_rate_cache[baseCode] = @{
              @"data": rateData, @"fetchedAt": [NSDate date]
            };
            query_currency_rows = CurrencyRowsForRates(amount, baseCode, rateData);
          }
        }
        ShowQueryContext();
      });
    }];
    [query_currency_task resume];
  });
}

static NSArray<NSArray<NSString *> *> *RowsForUnitInput(NSString *payload) {
  NSScanner *scanner = [NSScanner scannerWithString:payload ?: @""];
  scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  double inputValue = 0;
  if (![scanner scanDouble:&inputValue] || !isfinite(inputValue)) return @[
    @[@"单位换算", @"格式：uconv数值单位，如 5kg、5MPa、100rmb"]
  ];
  NSString *inputUnit = [[payload substringFromIndex:scanner.scanLocation]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  inputUnit = [inputUnit stringByReplacingOccurrencesOfString:@"°" withString:@""];
  NSDictionary<NSString *, NSString *> *caseSensitiveElectricalSymbols = @{
    @"mW": @"milliw", @"MW": @"megaw",
    @"mWh": @"milliwh", @"MWh": @"megawh", @"mΩ": @"milliohm",
    @"MΩ": @"mω", @"F": @"farad"
  };
  NSString *exactElectricalUnit = caseSensitiveElectricalSymbols[inputUnit];
  inputUnit = inputUnit.lowercaseString;
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
    @"celsius": @"c", @"fahrenheit": @"f", @"kelvin": @"k",
    @"pascal": @"pa", @"pascals": @"pa", @"帕": @"pa",
    @"kilopascal": @"kpa", @"kilopascals": @"kpa", @"千帕": @"kpa",
    @"kp": @"kpa", @"megapascal": @"mpa", @"megapascals": @"mpa", @"兆帕": @"mpa",
    @"mp": @"mpa",
    @"kgf/cm2": @"kgf/cm²", @"kgf/cm^2": @"kgf/cm²",
    @"kg/cm2": @"kgf/cm²", @"kg/cm^2": @"kgf/cm²", @"kg/cm²": @"kgf/cm²",
    @"公斤压力": @"kgf/cm²", @"千克力每平方厘米": @"kgf/cm²",
    @"毫米汞柱": @"mmhg", @"mwc": @"mh2o", @"mwater": @"mh2o",
    @"米水柱": @"mh2o", @"米水头": @"mh2o",
    @"层": @"floor", @"层高": @"floor", @"floor": @"floor",
    @"floors": @"floor", @"storeys": @"floor", @"stories": @"floor",
    @"millivolt": @"mv", @"millivolts": @"mv", @"毫伏": @"mv",
    @"volt": @"v", @"volts": @"v", @"伏": @"v", @"伏特": @"v",
    @"kilovolt": @"kv", @"kilovolts": @"kv", @"千伏": @"kv",
    @"milliamp": @"ma", @"milliampere": @"ma", @"milliamps": @"ma",
    @"milliamperes": @"ma", @"毫安": @"ma", @"ua": @"μa", @"μa": @"μa", @"µa": @"μa",
    @"amp": @"a", @"amps": @"a", @"ampere": @"a", @"amperes": @"a",
    @"安": @"a", @"安培": @"a", @"kiloamp": @"ka", @"kiloampere": @"ka",
    @"千安": @"ka", @"milliwatt": @"milliw", @"milliwatts": @"milliw",
    @"watt": @"w", @"watts": @"w", @"瓦": @"w", @"瓦特": @"w",
    @"kilowatt": @"kw", @"kilowatts": @"kw", @"千瓦": @"kw", @"mw": @"milliw",
    @"megawatt": @"megaw", @"megawatts": @"megaw", @"兆瓦": @"megaw",
    @"ohm": @"ω", @"ohms": @"ω", @"欧姆": @"ω",
    @"kilohm": @"kω", @"kilohms": @"kω", @"千欧": @"kω",
    @"milliohm": @"milliohm", @"milliohms": @"milliohm", @"毫欧": @"milliohm",
    @"megaohm": @"mω", @"megaohms": @"mω", @"兆欧": @"mω",
    @"hertz": @"hz", @"赫兹": @"hz", @"kilohertz": @"khz", @"千赫": @"khz",
    @"megahertz": @"mhz", @"兆赫": @"mhz", @"gigahertz": @"ghz", @"吉赫": @"ghz",
    @"milliwatt-hour": @"milliwh", @"milliwatt-hours": @"milliwh", @"mwh": @"milliwh",
    @"watt-hour": @"wh", @"watt-hours": @"wh", @"瓦时": @"wh",
    @"kilowatt-hour": @"kwh", @"kilowatt-hours": @"kwh", @"千瓦时": @"kwh",
    @"megawatt-hour": @"megawh", @"megawatt-hours": @"megawh", @"兆瓦时": @"megawh",
    @"farad": @"farad", @"farads": @"farad",
    @"millifarad": @"mf", @"毫法": @"mf", @"microfarad": @"μf", @"微法": @"μf",
    @"uf": @"μf", @"µf": @"μf",
    @"nanofarad": @"nf", @"纳法": @"nf", @"picofarad": @"pf", @"皮法": @"pf",
    @"henry": @"h", @"亨": @"h", @"millihenry": @"mh", @"毫亨": @"mh",
    @"microhenry": @"μh", @"微亨": @"μh", @"uh": @"μh", @"µh": @"μh",
    @"coulomb": @"coulomb", @"coulombs": @"coulomb", @"库仑": @"coulomb",
    @"millicoulomb": @"mc", @"毫库仑": @"mc",
    @"microcoulomb": @"μc", @"微库仑": @"μc", @"uc": @"μc", @"µc": @"μc"
  };
  NSInteger fireCategory = 3;
  BOOL fireCategorySpecified = NO;
  if (inputUnit.length > 1) {
    unichar finalCharacter = [inputUnit characterAtIndex:inputUnit.length - 1];
    if (finalCharacter >= '0' && finalCharacter <= '9') {
      NSString *unitWithoutCategory =
          [inputUnit substringToIndex:inputUnit.length - 1];
      NSString *normalizedUnit = aliases[unitWithoutCategory] ?: unitWithoutCategory;
      if ([@[@"pa", @"kpa", @"mpa", @"kgf/cm²", @"mmhg", @"mh2o"]
          containsObject:normalizedUnit]) {
        NSInteger requestedCategory = finalCharacter - '0';
        fireCategory = (requestedCategory == 1 || requestedCategory == 2) ?
            requestedCategory : 3;
        fireCategorySpecified = YES;
        inputUnit = unitWithoutCategory;
      }
    }
  }
  inputUnit = exactElectricalUnit ?: (aliases[inputUnit] ?: inputUnit);
  NSString *currencyCode = CurrencyCodeForUnit(inputUnit);
  if (currencyCode) {
    ScheduleCurrencyLookup(payload, inputValue, currencyCode);
    return query_currency_rows ?: @[@[@"货币换算", @"正在获取每日参考汇率…"]];
  }

  double configuredFloorHeight = QueryConfiguredFloorHeight();
  if ([inputUnit isEqualToString:@"floor"]) {
    double pressurePa = inputValue * configuredFloorHeight * 9806.65;
    if (!isfinite(pressurePa))
      return @[@[@"数值超出范围", @"请缩小输入数值"]];
    NSMutableArray *floorRows = [NSMutableArray array];
    for (size_t index = 0; index < sizeof(pressure) / sizeof(pressure[0]); ++index) {
      NSString *label = [NSString stringWithFormat:@"%@ (%@)",
          pressure[index].name, pressure[index].symbol];
      NSString *result = [NSString stringWithFormat:@"%@ %@",
          UtilityNumber(pressurePa / pressure[index].factor), pressure[index].symbol];
      [floorRows addObject:@[label, result]];
    }
    [floorRows addObject:@[@"大约几层",
        FloorEstimateResult(inputValue, configuredFloorHeight)]];
    [floorRows addObject:@[@"层高设置", FloorHeightSettingHint()]];
    return floorRows;
  }

  static const STUnitDefinition length[] = {
    {@"mm", @"mm", @"毫米", 0.001}, {@"cm", @"cm", @"厘米", 0.01},
    {@"m", @"m", @"米", 1.0}, {@"km", @"km", @"公里", 1000.0},
    {@"in", @"in", @"英寸", 0.0254}, {@"ft", @"ft", @"英尺", 0.3048},
    {@"yd", @"yd", @"码", 0.9144}, {@"mi", @"mi", @"英里", 1609.344}
  };
  static const STUnitDefinition mass[] = {
    {@"mg", @"mg", @"毫克", 0.000001}, {@"g", @"g", @"克", 0.001},
    {@"kg", @"kg", @"千克", 1.0}, {@"oz", @"oz", @"盎司", 0.028349523125},
    {@"lb", @"lb", @"磅", 0.45359237}
  };
  static const STUnitDefinition volume[] = {
    {@"ml", @"ml", @"毫升", 0.001}, {@"l", @"l", @"升", 1.0},
    {@"gal", @"gal", @"美制加仑", 3.785411784}
  };
  static const STUnitDefinition voltage[] = {
    {@"mv", @"mV", @"毫伏", 0.001}, {@"v", @"V", @"伏特", 1.0},
    {@"kv", @"kV", @"千伏", 1000.0}
  };
  static const STUnitDefinition current[] = {
    {@"μa", @"μA", @"微安", 0.000001}, {@"ma", @"mA", @"毫安", 0.001},
    {@"a", @"A", @"安培", 1.0}, {@"ka", @"kA", @"千安", 1000.0}
  };
  static const STUnitDefinition power[] = {
    {@"milliw", @"mW", @"毫瓦", 0.001}, {@"w", @"W", @"瓦特", 1.0},
    {@"kw", @"kW", @"千瓦", 1000.0}, {@"megaw", @"MW", @"兆瓦", 1000000.0}
  };
  static const STUnitDefinition resistance[] = {
    {@"milliohm", @"mΩ", @"毫欧", 0.001}, {@"ω", @"Ω", @"欧姆", 1.0},
    {@"kω", @"kΩ", @"千欧", 1000.0},
    {@"mω", @"MΩ", @"兆欧", 1000000.0}
  };
  static const STUnitDefinition energy[] = {
    {@"milliwh", @"mWh", @"毫瓦时", 0.001}, {@"wh", @"Wh", @"瓦时", 1.0},
    {@"kwh", @"kWh", @"千瓦时", 1000.0}, {@"megawh", @"MWh", @"兆瓦时", 1000000.0}
  };
  static const STUnitDefinition frequency[] = {
    {@"hz", @"Hz", @"赫兹", 1.0}, {@"khz", @"kHz", @"千赫", 1000.0},
    {@"mhz", @"MHz", @"兆赫", 1000000.0}, {@"ghz", @"GHz", @"吉赫", 1000000000.0}
  };
  static const STUnitDefinition capacitance[] = {
    {@"pf", @"pF", @"皮法", 1e-12}, {@"nf", @"nF", @"纳法", 1e-9},
    {@"μf", @"μF", @"微法", 1e-6}, {@"mf", @"mF", @"毫法", 1e-3},
    {@"farad", @"F", @"法拉", 1.0}
  };
  static const STUnitDefinition inductance[] = {
    {@"μh", @"μH", @"微亨", 1e-6}, {@"mh", @"mH", @"毫亨", 1e-3},
    {@"h", @"H", @"亨利", 1.0}
  };
  static const STUnitDefinition charge[] = {
    {@"μc", @"μC", @"微库仑", 1e-6}, {@"mc", @"mC", @"毫库仑", 1e-3},
    {@"coulomb", @"C", @"库仑", 1.0}
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
  } else if ([inputUnit isEqualToString:@"pa"] ||
             [inputUnit isEqualToString:@"kpa"] ||
             [inputUnit isEqualToString:@"mpa"] ||
             [inputUnit isEqualToString:@"kgf/cm²"] ||
             [inputUnit isEqualToString:@"mmhg"] ||
             [inputUnit isEqualToString:@"mh2o"]) {
    definitions = pressure; definitionCount = sizeof(pressure) / sizeof(pressure[0]);
    dimension = STUnitPressure;
  } else if ([inputUnit isEqualToString:@"c"] || [inputUnit isEqualToString:@"f"] ||
             [inputUnit isEqualToString:@"k"]) {
    dimension = STUnitTemperature;
  } else if ([inputUnit isEqualToString:@"mv"] || [inputUnit isEqualToString:@"v"] ||
             [inputUnit isEqualToString:@"kv"]) {
    definitions = voltage; definitionCount = sizeof(voltage) / sizeof(voltage[0]);
    dimension = STUnitVoltage;
  } else if ([inputUnit isEqualToString:@"μa"] || [inputUnit isEqualToString:@"ma"] ||
             [inputUnit isEqualToString:@"a"] || [inputUnit isEqualToString:@"ka"]) {
    definitions = current; definitionCount = sizeof(current) / sizeof(current[0]);
    dimension = STUnitCurrent;
  } else if ([inputUnit isEqualToString:@"milliw"] || [inputUnit isEqualToString:@"w"] ||
             [inputUnit isEqualToString:@"kw"] || [inputUnit isEqualToString:@"megaw"]) {
    definitions = power; definitionCount = sizeof(power) / sizeof(power[0]);
    dimension = STUnitPower;
  } else if ([inputUnit isEqualToString:@"milliohm"] || [inputUnit isEqualToString:@"ω"] ||
             [inputUnit isEqualToString:@"kω"] || [inputUnit isEqualToString:@"mω"]) {
    definitions = resistance; definitionCount = sizeof(resistance) / sizeof(resistance[0]);
    dimension = STUnitResistance;
  } else if ([inputUnit isEqualToString:@"milliwh"] || [inputUnit isEqualToString:@"wh"] ||
             [inputUnit isEqualToString:@"kwh"] || [inputUnit isEqualToString:@"megawh"]) {
    definitions = energy; definitionCount = sizeof(energy) / sizeof(energy[0]);
    dimension = STUnitEnergy;
  } else if ([inputUnit isEqualToString:@"hz"] || [inputUnit isEqualToString:@"khz"] ||
             [inputUnit isEqualToString:@"mhz"] || [inputUnit isEqualToString:@"ghz"]) {
    definitions = frequency; definitionCount = sizeof(frequency) / sizeof(frequency[0]);
    dimension = STUnitFrequency;
  } else if ([inputUnit isEqualToString:@"pf"] || [inputUnit isEqualToString:@"nf"] ||
             [inputUnit isEqualToString:@"μf"] || [inputUnit isEqualToString:@"mf"] ||
             [inputUnit isEqualToString:@"farad"]) {
    definitions = capacitance; definitionCount = sizeof(capacitance) / sizeof(capacitance[0]);
    dimension = STUnitCapacitance;
  } else if ([inputUnit isEqualToString:@"μh"] || [inputUnit isEqualToString:@"mh"] ||
             [inputUnit isEqualToString:@"h"]) {
    definitions = inductance; definitionCount = sizeof(inductance) / sizeof(inductance[0]);
    dimension = STUnitInductance;
  } else if ([inputUnit isEqualToString:@"μc"] || [inputUnit isEqualToString:@"mc"] ||
             [inputUnit isEqualToString:@"coulomb"]) {
    definitions = charge; definitionCount = sizeof(charge) / sizeof(charge[0]);
    dimension = STUnitCharge;
  } else {
    return @[@[@"单位不支持", @"长度、质量、体积、温度、压力、电气或货币单位"]];
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
    if ([inputUnit caseInsensitiveCompare:definitions[index].key] ==
        NSOrderedSame) {
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
  if (dimension == STUnitPressure) {
    double floors = baseValue / (9806.65 * configuredFloorHeight);
    [rows addObject:@[@"大约几层",
        PressureFloorEstimateResult(floors, configuredFloorHeight,
                                    fireCategory, fireCategorySpecified)]];
    [rows addObject:@[@"层高设置", FloorHeightSettingHint()]];
    [rows addObject:@[@"静压设置", FireStaticPressureSettingHint()]];
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
  NSMutableArray *rows = [@[
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
      [NSString stringWithFormat:@"%@ L", UtilityNumber(value * 3.785411784)]],
    @[@"Pa → kPa",
      [NSString stringWithFormat:@"%@ kPa", UtilityNumber(value / 1000.0)]],
    @[@"Pa → MPa",
      [NSString stringWithFormat:@"%@ MPa", UtilityNumber(value / 1000000.0)]],
    @[@"kPa → Pa",
      [NSString stringWithFormat:@"%@ Pa", UtilityNumber(value * 1000.0)]],
    @[@"kPa → MPa",
      [NSString stringWithFormat:@"%@ MPa", UtilityNumber(value / 1000.0)]],
    @[@"MPa → Pa",
      [NSString stringWithFormat:@"%@ Pa", UtilityNumber(value * 1000000.0)]],
    @[@"MPa → kPa",
      [NSString stringWithFormat:@"%@ kPa", UtilityNumber(value * 1000.0)]],
    @[@"kg → g",
      [NSString stringWithFormat:@"%@ g", UtilityNumber(value * 1000.0)]],
    @[@"g → kg",
      [NSString stringWithFormat:@"%@ kg", UtilityNumber(value / 1000.0)]],
    @[@"V → mV",
      [NSString stringWithFormat:@"%@ mV", UtilityNumber(value * 1000.0)]],
    @[@"A → mA",
      [NSString stringWithFormat:@"%@ mA", UtilityNumber(value * 1000.0)]],
    @[@"W → kW",
      [NSString stringWithFormat:@"%@ kW", UtilityNumber(value / 1000.0)]],
    @[@"kW → W",
      [NSString stringWithFormat:@"%@ W", UtilityNumber(value * 1000.0)]],
    @[@"kWh → Wh",
      [NSString stringWithFormat:@"%@ Wh", UtilityNumber(value * 1000.0)]],
    @[@"Hz → kHz",
      [NSString stringWithFormat:@"%@ kHz", UtilityNumber(value / 1000.0)]]
  ] mutableCopy];
  [rows addObject:@[@"Pa → 大约几层", FloorEstimateResult(
      value / (9806.65 * QueryConfiguredFloorHeight()),
      QueryConfiguredFloorHeight())]];
  [rows addObject:@[@"层高设置", FloorHeightSettingHint()]];
  // Include conventional pressure units even when no input unit is given.
  // Reuse the exact same pressure definitions as explicit-unit conversion.
  for (NSUInteger index = 3; index < sizeof(pressure) / sizeof(pressure[0]); ++index) {
    STUnitDefinition unit = pressure[index];
    [rows insertObject:@[[NSString stringWithFormat:@"Pa → %@", unit.symbol],
        [NSString stringWithFormat:@"%@ %@", UtilityNumber(value / unit.factor), unit.symbol]]
        atIndex:14 + (index - 3) * 2];
    [rows insertObject:@[[NSString stringWithFormat:@"%@ → Pa", unit.symbol],
        [NSString stringWithFormat:@"%@ Pa", UtilityNumber(value * unit.factor)]]
        atIndex:15 + (index - 3) * 2];
  }
  return rows;
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

static const NSInteger kQueryUtilityPageSize = 9;

static CGEventTapPlacement QueryTapPlacement(void) {
  // Hammerspoon installs head taps. Let global leader-key shortcuts consume
  // their full down/up sequence before the U panel handles the remaining keys.
  // A lone Space replayed by the global handler still reaches this tail tap.
  return kCGTailAppendEventTap;
}

static NSInteger QueryPageCount(NSInteger count) {
  return count > 0 ? 1 + (count - 1) / kQueryUtilityPageSize : 1;
}

static NSInteger QueryClampedSelection(NSInteger count, NSInteger selected) {
  return MIN(MAX(0, selected), MAX(0, count - 1));
}

static NSInteger QueryMovePage(NSInteger count, NSInteger selected,
                                NSInteger direction) {
  selected = QueryClampedSelection(count, selected);
  NSInteger page = selected / kQueryUtilityPageSize;
  NSInteger target = MIN(MAX(0, page + direction), QueryPageCount(count) - 1);
  if (target == page) return selected;
  return QueryClampedSelection(count,
      target * kQueryUtilityPageSize + selected % kQueryUtilityPageSize);
}

static NSInteger QueryPageDirection(CGKeyCode key) {
  if (key == kVK_LeftArrow || key == kVK_PageUp) return -1;
  if (key == kVK_RightArrow || key == kVK_PageDown) return 1;
  return 0;
}

static NSInteger QueryRowDirection(CGKeyCode key) {
  if (key == kVK_UpArrow) return -1;
  if (key == kVK_DownArrow) return 1;
  return 0;
}

static NSInteger QueryNavigateSelection(NSInteger count, NSInteger selected,
                                         CGKeyCode key) {
  NSInteger page = QueryPageDirection(key);
  if (page) return QueryMovePage(count, selected, page);
  selected = QueryClampedSelection(count, selected);
  NSInteger row = QueryRowDirection(key);
  return count > 0 && row ? (selected + count + row) % count : selected;
}

static NSString *QueryPagingKeyName(NSString *name) {
  if (name.length == 1) return name;
  static NSDictionary<NSString *, NSString *> *names;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    names = @{@"semicolon": @";", @"apostrophe": @"'", @"quoteright": @"'",
      @"comma": @",", @"period": @".", @"minus": @"-", @"equal": @"=",
      @"bracketleft": @"[", @"bracketright": @"]", @"slash": @"/",
      @"backslash": @"\\", @"grave": @"`", @"quoteleft": @"`",
      @"colon": @":", @"quotedbl": @"\"", @"less": @"<", @"greater": @">",
      @"underscore": @"_", @"plus": @"+", @"braceleft": @"{",
      @"braceright": @"}", @"question": @"?", @"bar": @"|", @"asciitilde": @"~",
      @"exclam": @"!", @"at": @"@", @"numbersign": @"#", @"dollar": @"$",
      @"percent": @"%", @"asciicircum": @"^", @"ampersand": @"&",
      @"asterisk": @"*", @"parenleft": @"(", @"parenright": @")",
      @"space": @" ", @"Tab": @"\t", @"Return": @"\r",
      @"Page_Up": @"Page_Up", @"Prior": @"Page_Up",
      @"Page_Down": @"Page_Down", @"Next": @"Page_Down",
      @"Home": @"Home", @"End": @"End",
      @"Left": @"Left", @"Right": @"Right", @"Up": @"Up", @"Down": @"Down"};
  });
  if (names[name]) return names[name];
  if ([name hasPrefix:@"F"] && name.length <= 3) {
    NSInteger number = [[name substringFromIndex:1] integerValue];
    if (number >= 1 && number <= 35 &&
        [name isEqualToString:[NSString stringWithFormat:@"F%ld", (long)number]])
      return name;
  }
  return nil;
}

static NSDictionary *QueryPagingBinding(NSString *accept, NSString *send,
                                        NSString *condition) {
  NSString *target = QueryPagingKeyName(send);
  NSInteger direction = [target isEqualToString:@"Page_Up"] ? -1 :
      ([target isEqualToString:@"Page_Down"] ? 1 : 0);
  if (!direction || !condition.length || ![@[@"always", @"composing", @"has_menu", @"paging"]
                       containsObject:condition]) return nil;
  NSArray<NSString *> *parts = [accept componentsSeparatedByString:@"+"];
  NSString *key = QueryPagingKeyName(parts.lastObject);
  // These keys are input, never U-panel paging shortcuts, even if the schema
  // binds them to Page_Up/Page_Down. Do not mutate the normal Rime config.
  if (!key || [key isEqualToString:@"-"] || [key isEqualToString:@"="]) return nil;
  CGEventFlags modifiers = 0;
  for (NSUInteger index = 0; index + 1 < parts.count; ++index) {
    NSString *modifier = parts[index];
    if ([modifier isEqualToString:@"Shift"]) modifiers |= kCGEventFlagMaskShift;
    else if ([modifier isEqualToString:@"Control"]) modifiers |= kCGEventFlagMaskControl;
    else if ([modifier isEqualToString:@"Alt"] || [modifier isEqualToString:@"Mod1"])
      modifiers |= kCGEventFlagMaskAlternate;
    else if ([modifier isEqualToString:@"Super"]) modifiers |= kCGEventFlagMaskCommand;
    else return nil;
  }
  return @{@"key": key, @"modifiers": @(modifiers), @"direction": @(direction),
           @"when": condition, @"accept": accept};
}

static NSInteger QueryConfiguredPageDirection(NSArray<NSDictionary *> *bindings,
    NSString *key, CGEventFlags flags, BOOL hasMenu, BOOL composing, BOOL paging,
    BOOL keywordInput) {
  CGEventFlags modifiers = flags & (kCGEventFlagMaskShift | kCGEventFlagMaskControl |
      kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand);
  // Numeric and structured tool payloads must remain editable: e.g. IPv4 dots,
  // date separators, color commas and fractional/negative conversion values.
  if (keywordInput && !modifiers && key.length == 1 &&
      [@"0123456789.-=+/:, #%^()" containsString:key]) return 0;
  for (NSDictionary *binding in bindings) {
    if (![binding[@"key"] isEqualToString:key] ||
        [binding[@"modifiers"] unsignedLongLongValue] != modifiers) continue;
    NSString *condition = binding[@"when"];
    if ([condition isEqualToString:@"always"] ||
        ([condition isEqualToString:@"has_menu"] && hasMenu) ||
        ([condition isEqualToString:@"composing"] && composing) ||
        ([condition isEqualToString:@"paging"] && paging))
      return [binding[@"direction"] integerValue];
  }
  return 0;
}

static NSArray<NSDictionary *> *QueryLoadPagingBindings(RimeApi_stdbool *api,
                                                         RimeSessionId session) {
  if (!api || !RIME_PROVIDED(api, config_begin_list) || !api->get_status ||
      !api->free_status || !api->schema_open || !api->config_open ||
      !api->config_close || !api->config_begin_list || !api->config_next ||
      !api->config_end || !api->config_get_cstring) return @[];
  RimeStatus_stdbool status = {0};
  RIME_STRUCT_INIT(RimeStatus_stdbool, status);
  NSString *schema = nil;
  if (api->get_status(session, &status)) {
    if (status.schema_id) schema = [NSString stringWithUTF8String:status.schema_id];
    api->free_status(&status);
  }
  RimeConfig config = {0};
  RimeConfigIterator iterator = {0};
  BOOL opened = schema.length && api->schema_open(schema.UTF8String, &config);
  BOOL found = opened && api->config_begin_list(&iterator, &config, "key_binder/bindings");
  if (!found) {
    if (opened) api->config_close(&config);
    config = (RimeConfig){0};
    opened = api->config_open("default", &config);
    found = opened && api->config_begin_list(&iterator, &config, "key_binder/bindings");
  }
  NSMutableArray *bindings = [NSMutableArray array];
  if (found) {
    while (api->config_next(&iterator)) {
      NSString *path = iterator.path ? [NSString stringWithUTF8String:iterator.path] : nil;
      if (!path) continue;
      NSMutableArray *values = [NSMutableArray array];
      for (NSString *field in @[@"accept", @"send", @"when"]) {
        const char *value = api->config_get_cstring(&config,
            [[path stringByAppendingFormat:@"/%@", field] UTF8String]);
        [values addObject:value ? [NSString stringWithUTF8String:value] : @""];
      }
      NSDictionary *binding = QueryPagingBinding(values[0], values[1], values[2]);
      if (binding) [bindings addObject:binding];
    }
    api->config_end(&iterator);
  }
  if (opened) api->config_close(&config);
  return bindings;
}

static NSString *PaginateQueryRows(NSMutableArray<NSString *> *candidates,
                                    NSMutableArray<NSString *> *comments,
                                    NSInteger *highlighted) {
  NSInteger count = (NSInteger)candidates.count;
  *highlighted = QueryClampedSelection(count, *highlighted);
  NSInteger page = *highlighted / kQueryUtilityPageSize;
  NSUInteger start = (NSUInteger)(page * kQueryUtilityPageSize);
  NSUInteger length = MIN((NSUInteger)kQueryUtilityPageSize,
                           candidates.count - start);
  NSRange range = NSMakeRange(start, length);
  [candidates setArray:[candidates subarrayWithRange:range]];
  [comments setArray:[comments subarrayWithRange:range]];
  *highlighted -= (NSInteger)start;
  return QueryPageCount(count) > 1 ?
      [NSString stringWithFormat:@"%ld/%ld", (long)page + 1,
          (long)QueryPageCount(count)] : nil;
}

static NSInteger QueryUtilityCandidateCount(void) {
  NSInteger count = 0;
  if (UtilityPayload(query_text, @"maxwidth") != nil ||
      UtilityPayload(query_text, @"floorheight") != nil ||
      UtilityPayload(query_text, @"firedefault") != nil) count = 1;
  else if (UtilityPayload(query_text, @"lang") != nil) count = 5;
  else if (IsColorQuery())
    count = IsColorConversionQuery() ? (NSInteger)RowsForColorConversion().count :
        (NSInteger)ColorFormatNames().count;
  else if (IsTimeQuery()) count = (NSInteger)RowsForTimeQuery().count;
  else if (IsDateQuery()) count = (NSInteger)RowsForDateQuery().count;
  else if (IsUnitQuery()) count = (NSInteger)RowsForUnitQuery().count;
  else if ([query_text isEqualToString:@"ip"]) count = 2;
  else if (UtilityPayload(query_text, @"ip") != nil) count = 1;
  else if (UtilityPayload(query_text, @"phone") != nil ||
           query_phone_prefix_active) count = 1;
  NSString *keyword = ActiveUtilityKeyword();
  return count + (count > 0 && keyword != nil &&
      ![keyword isEqualToString:@"lang"] ? 1 : 0);
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
  if (!EnsurePhoneData()) return nil;
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

static NSString *QueryIPResponseLanguage(void) {
  // ipwho.is supports English, Simplified Chinese and Japanese, but not
  // Korean or Traditional Chinese. Traditional output is converted locally.
  NSString *language = QueryUILanguage();
  if ([language isEqualToString:@"ja"]) return @"ja";
  if ([language hasPrefix:@"zh-"]) return @"zh-CN";
  return @"en";
}

static NSString *LocalizedIPCountry(NSString *countryName, NSString *countryCode) {
  if (!countryCode.length) return countryName ?: @"";
  NSString *localizedName = [[NSLocale localeWithLocaleIdentifier:QueryUILanguage()]
      displayNameForKey:NSLocaleCountryCode value:countryCode.uppercaseString];
  return localizedName.length ? localizedName : (countryName ?: @"");
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
                                  value:@"success,ip,country,country_code,region,city,connection"],
      [NSURLQueryItem queryItemWithName:@"lang" value:QueryIPResponseLanguage()]
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
        query_ip_task = nil;
        id success = [json isKindOfClass:NSDictionary.class] ? json[@"success"] : nil;
        if (error || http.statusCode < 200 || http.statusCode >= 300 ||
            ![success respondsToSelector:@selector(boolValue)] ||
            ![success boolValue]) {
          query_ip_details = @"公网 IP 查询失败（网络不可用或服务限流）";
        } else {
          NSString *ip = [json[@"ip"] isKindOfClass:NSString.class] ? json[@"ip"] : @"";
          if (isPublicIPLookup) query_ip_public_ip = ip.length ? ip : nil;
          NSString *countrySource = [json[@"country"] isKindOfClass:NSString.class] ?
              json[@"country"] : @"";
          NSString *countryCode = [json[@"country_code"] isKindOfClass:NSString.class] ?
              json[@"country_code"] : @"";
          NSString *country = LocalizedIPCountry(countrySource, countryCode);
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
  NSString *languagePayload = UtilityPayload(query_text, @"lang");
  if (languagePayload != nil) {
    [candidates removeAllObjects];
    [comments removeAllObjects];
    *input = [@"u" stringByAppendingString:query_text];
    [candidates addObjectsFromArray:@[@"简体中文", @"繁體中文", @"English", @"한국어", @"日本語"]];
    [comments addObjectsFromArray:@[
      @"ulangzh", @"ulangtw", @"ulangen", @"ulangko", @"ulangja"]];
    if (languagePayload.length == 0) {
      [comments replaceObjectAtIndex:0 withObject:
          @"设置界面语言，例如 ulangen、ulangko、ulangja、ulangtw"];
    }
    return YES;
  }
  NSString *floorHeightPayload = UtilityPayload(query_text, @"floorheight");
  if (floorHeightPayload != nil) {
    [candidates removeAllObjects];
    [comments removeAllObjects];
    *input = [@"u" stringByAppendingString:query_text];
    double requestedHeight = 0;
    BOOL valid = floorHeightPayload.length == 0 ||
        ParseFloorHeight(floorHeightPayload, &requestedHeight);
    [candidates addObject:valid ? @"层高设置" : @"层高格式不正确"];
    [comments addObject:floorHeightPayload.length == 0 ?
        [NSString stringWithFormat:@"当前 %@ m；%@",
            UtilityNumber(QueryConfiguredFloorHeight()), FloorHeightSettingHint()] :
        (valid ? [NSString stringWithFormat:
            @"%@ m · 停止输入约 1 秒后保存", UtilityNumber(requestedHeight)] :
            @"输入 2–12 米，例如 ufloorheight3.2")];
    return YES;
  }
  NSString *fireDefaultPayload = UtilityPayload(query_text, @"firedefault");
  if (fireDefaultPayload != nil) {
    [candidates removeAllObjects];
    [comments removeAllObjects];
    *input = [@"u" stringByAppendingString:query_text];
    NSInteger category = 0;
    double pressureMPa = 0;
    BOOL valid = ParseFireStaticPressureDefault(fireDefaultPayload,
        &category, &pressureMPa);
    [candidates addObject:valid ? @"消防静压默认设置" : @"消防静压格式不正确"];
    NSString *hint = fireDefaultPayload.length == 0 ?
        [NSString stringWithFormat:
          @"类别1：%@ MPa（>100米按0.15）；类别2：%@ MPa；类别3：%@ MPa（自定义）",
          UtilityNumber(QueryFireStaticPressureMPa(1)),
          UtilityNumber(QueryFireStaticPressureMPa(2)),
          UtilityNumber(QueryFireStaticPressureMPa(3))] :
        (valid ? [NSString stringWithFormat:
          @"类别 %ld 参考静压 %@ MPa · 停顿约 1 秒保存",
          (long)category, UtilityNumber(pressureMPa)] :
          @"格式：ufiredefault1-0.15（类别1-静压MPa，范围大于0至2.4）");
    [comments addObject:hint];
    return YES;
  }
  NSString *maxWidthPayload = UtilityPayload(query_text, @"maxwidth");
  if (maxWidthPayload != nil) {
    [candidates removeAllObjects];
    [comments removeAllObjects];
    *input = [@"u" stringByAppendingString:query_text];
    BOOL digitsOnly = maxWidthPayload.length == 0 ||
        [maxWidthPayload rangeOfCharacterFromSet:
            [NSCharacterSet characterSetWithCharactersInString:@"0123456789"]
                .invertedSet].location == NSNotFound;
    [candidates addObject:digitsOnly ? @"最大面板宽度" : @"宽度格式不正确"];
    [comments addObject:maxWidthPayload.length ?
        (digitsOnly ? [NSString stringWithFormat:
            @"%@ pt · 停止输入约 1 秒后保存（200–2000）", maxWidthPayload] :
            @"请输入 200–2000 的整数") :
        @"输入 200–2000 的整数，例如 umaxwidth600"];
    return YES;
  }
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
        NSString *result = values ? values[index] :
            (index == 0 ? placeholder : @"");
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
  if (UtilityPayload(query_text, @"phone") == nil &&
      !query_phone_prefix_active) return NO;
  [candidates removeAllObjects];
  [comments removeAllObjects];
  *input = [@"u" stringByAppendingString:query_text];
  NSString *digits = nil;
  NSString *landlineArea = nil;
  PhoneInputStatus phoneStatus = ValidatePhoneInput(&digits, &landlineArea);
  if (phoneStatus == PhoneInputInvalid) {
    [candidates addObject:@"号码格式不正确"];
    [comments addObject:@""];
    return YES;
  }
  if (phoneStatus == PhoneInputIncomplete) {
    [candidates addObject:landlineArea ? @"座机归属地" : @"号码归属地"];
    [comments addObject:landlineArea ?
        [NSString stringWithFormat:@"%@ · 区号 %@ · 继续输入本地号码",
            LandlineRegionForAreaCode(landlineArea) ?: @"地区未收录", landlineArea] :
        [NSString stringWithFormat:@"继续输入 · %lu/11", (unsigned long)digits.length]];
  } else {
    if (landlineArea) {
      [candidates addObject:@"座机归属地"];
      [comments addObject:[NSString stringWithFormat:@"%@ · 区号 %@ · %@",
          LandlineRegionForAreaCode(landlineArea) ?: @"地区未收录", landlineArea, digits]];
    } else {
      NSString *region = PhoneRegionForDigits(digits);
      [candidates addObject:region ? @"号段归属地" : @"未找到该号段"];
      [comments addObject:region ?: @"本地号段库未收录该号码，或号码格式不正确"];
    }
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

static NSString *QueryVisibleInput(NSString *query, NSString *preedit) {
  if (!query.length) return @"u";
  BOOL containsNonLetters = [query rangeOfCharacterFromSet:
      [NSCharacterSet characterSetWithCharactersInString:
          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet]
      .location != NSNotFound;
  NSString *composition = containsNonLetters || !preedit.length ? query : preedit;
  return [@"u" stringByAppendingString:composition];
}

static CGFloat QueryPanelWidth(CGFloat desiredWidth, CGFloat availableWidth) {
  return MIN(QueryConfiguredPanelMaxWidth(),
             MIN(desiredWidth, MAX(1, availableWidth)));
}

static NSFont *QueryCandidateFontForWidth(NSString *text, NSFont *font, CGFloat width) {
  if (!text.length || width <= 0) return font;
  NSFont *fitted = font;
  CGFloat measured = [text sizeWithAttributes:@{NSFontAttributeName:fitted}].width;
  // Preserve every glyph on one line under the panel's fixed width limit.
  for (NSUInteger attempt = 0; measured > width && attempt < 4; ++attempt) {
    fitted = [NSFont fontWithDescriptor:fitted.fontDescriptor
        size:fitted.pointSize * width / measured * 0.99] ?: fitted;
    measured = [text sizeWithAttributes:@{NSFontAttributeName:fitted}].width;
  }
  return fitted;
}

static CGFloat QueryCommentColumn(CGFloat width, CGFloat widestCandidate,
                                    CGFloat gap, BOOL hasComments, CGFloat indicatorWidth) {
  CGFloat candidateX = QueryPanelHorizontalPadding() + 27;
  CGFloat preferred = candidateX + widestCandidate + gap;
  CGFloat minimumCommentWidth = hasComments ? MIN(100, width * 0.25) : 0;
  CGFloat maximum = width - 40 - indicatorWidth - minimumCommentWidth +
      (hasComments ? 0 : gap);
  // Prioritize complete labels; results can wrap within the remaining space.
  return MIN(preferred, MAX(candidateX + gap + 1, maximum));
}

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

static NSString *QueryVisibleComment(NSString *comment, NSFont *font,
                                     NSUInteger *continuationStart,
                                     CGFloat *continuationIndent) {
  if (continuationStart) *continuationStart = NSUIntegerMax;
  if (continuationIndent) *continuationIndent = 0;
  if (!comment.length) return @"";
  NSUInteger leadingTabs = 0;
  while (leadingTabs < comment.length &&
         [comment characterAtIndex:leadingTabs] == '\t')
    ++leadingTabs;
  NSString *content = [comment substringFromIndex:leadingTabs];
  NSRange separator = [content rangeOfString:@"\t"];
  NSString *normalized = [content stringByReplacingOccurrencesOfString:@"\t"
      withString:@"  "];
  if (separator.location != NSNotFound) {
    NSString *prefix = [content substringToIndex:separator.location];
    NSDictionary *attributes = @{NSFontAttributeName:
        font ?: [NSFont userFontOfSize:16]};
    if (continuationStart) *continuationStart = separator.location + 2;
    if (continuationIndent)
      *continuationIndent = [[prefix stringByAppendingString:@"  "]
          sizeWithAttributes:attributes].width;
  }
  return normalized;
}

static CFIndex QueryNextWrappedCommentLine(CTTypesetterRef typesetter,
    NSString *text, CFIndex start, CGFloat width, NSUInteger continuationStart,
    CGFloat continuationIndent) {
  CGFloat availableWidth = width -
      ((NSUInteger)start >= continuationStart ? continuationIndent : 0);
  return QueryNextLineLength(typesetter, text, start,
                             MAX(1, availableWidth));
}

static NSUInteger QueryWrappedLineCount(NSString *text, NSFont *font,
                                        CGFloat width) {
  NSUInteger continuationStart = NSUIntegerMax;
  CGFloat continuationIndent = 0;
  text = QueryVisibleComment(text, font, &continuationStart,
                             &continuationIndent);
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
    start += QueryNextWrappedCommentLine(typesetter, text, start, width,
        continuationStart, continuationIndent);
    ++count;
  }
  CFRelease(typesetter);
  CFRelease(ctFont);
  return MAX(1, count);
}

static NSArray<NSNumber *> *QueryMeasuredRowHeights(NSArray<NSString *> *candidates,
    NSArray<NSString *> *comments, NSFont *candidateFont, NSFont *commentFont,
    CGFloat width, CGFloat commentColumnX, CGFloat indicatorWidth, CGFloat availableHeight) {
  CGFloat candidateLineHeight = FontLineHeight(candidateFont);
  CGFloat commentLineHeight = FontLineHeight(commentFont);
  CGFloat step = MAX(candidateLineHeight, commentLineHeight);
  CGFloat baseHeight = step + QueryCandidateRowPadding();
  NSMutableArray<NSNumber *> *naturalHeights = [NSMutableArray array];
  NSMutableArray<NSNumber *> *heights = [NSMutableArray array];
  for (NSUInteger index = 0; index < candidates.count; ++index) {
    CGFloat trailing = index + 1 == candidates.count ? 40 + indicatorWidth : 8;
    NSString *comment = index < comments.count ? comments[index] : @"";
    NSUInteger commentLines = QueryWrappedLineCount(comment, commentFont, width - commentColumnX - trailing);
    [naturalHeights addObject:@(MAX(candidateLineHeight,
        commentLines * commentLineHeight) + QueryCandidateRowPadding())];
    [heights addObject:@(baseHeight)];
  }
  CGFloat budget = MAX(0, availableHeight - baseHeight * candidates.count);
  BOOL allocated = YES;
  while (budget > 0 && allocated) {
    allocated = NO;
    for (NSUInteger index = 0; index < heights.count; ++index) {
      CGFloat extra = MIN(step, naturalHeights[index].doubleValue - heights[index].doubleValue);
      if (extra <= 0 || extra > budget) continue;
      heights[index] = @(heights[index].doubleValue + extra);
      budget -= extra;
      allocated = YES;
    }
  }
  return heights;
}

static void DrawQueryTextWrapped(NSString *text, NSFont *font, NSColor *color,
                                 NSRect row, CGFloat x, CGFloat width,
                                 NSUInteger maxLines) {
  NSUInteger continuationStart = NSUIntegerMax;
  CGFloat continuationIndent = 0;
  text = QueryVisibleComment(text, font, &continuationStart,
                             &continuationIndent);
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
  NSUInteger drawnLines = 0;
  CFIndex measured = 0;
  while (measured < (CFIndex)text.length && drawnLines < maxLines) {
    measured += QueryNextWrappedCommentLine(typesetter, text, measured, width,
        continuationStart, continuationIndent);
    ++drawnLines;
  }
  CGFloat baseline = NSMidY(row) + (drawnLines - 1) * lineHeight / 2 -
      (font.ascender + font.descender) / 2;
  CFIndex start = 0;
  for (NSUInteger index = 0; index < maxLines && start < (CFIndex)text.length;
       ++index) {
    BOOL continuation = (NSUInteger)start >= continuationStart;
    CGFloat lineX = x + (continuation ? continuationIndent : 0);
    CGFloat lineWidth = MAX(1, width - (continuation ? continuationIndent : 0));
    CFIndex length = QueryNextWrappedCommentLine(typesetter, text, start,
        width, continuationStart, continuationIndent);
    BOOL overflow = index + 1 == maxLines && start + length < (CFIndex)text.length;
    CTLineRef line = CTTypesetterCreateLine(typesetter,
        CFRangeMake(start, overflow ? (CFIndex)text.length - start : length));
    if (overflow) {
      NSAttributedString *ellipsis = [[NSAttributedString alloc]
          initWithString:@"…" attributes:attributes];
      CTLineRef token = CTLineCreateWithAttributedString(
          (__bridge CFAttributedStringRef)ellipsis);
      CTLineRef truncated = CTLineCreateTruncatedLine(line, lineWidth,
          kCTLineTruncationEnd, token);
      if (truncated) {
        CFRelease(line);
        line = truncated;
      }
      CFRelease(token);
    }
    CGContextSetTextPosition(context, lineX, baseline - index * lineHeight);
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
    if (candidateWidth > 0)
      DrawQueryTextCentered(candidate,
          QueryCandidateFontForWidth(candidate, candidateFont, candidateWidth),
          NSColor.labelColor, row, candidateX, NO);
    BOOL lastCandidate = index + 1 == self.candidates.count;
    if (index < self.comments.count && self.comments[index].length) {
      NSFont *commentFont = commentAttributes[NSFontAttributeName];
      CGFloat commentX = self.commentColumnX;
      CGFloat indicatorWidth = lastCandidate && self.helpPageIndicator.length ?
          [self.helpPageIndicator sizeWithAttributes:commentAttributes].width + 8 : 0;
      CGFloat trailingSpace = lastCandidate ? 40 + indicatorWidth : 8;
      CGFloat commentWidth = self.bounds.size.width - commentX - trailingSpace;
      NSUInteger maxLines = MAX(1, (NSUInteger)floor(
          (rowHeight - QueryCandidateRowPadding()) / FontLineHeight(commentFont)));
      DrawQueryTextWrapped(self.comments[index], commentFont,
          NSColor.secondaryLabelColor, row, commentX, commentWidth, maxLines);
    }
    if (lastCandidate && self.helpPageIndicator.length) {
      NSFont *commentFont = commentAttributes[NSFontAttributeName];
      CGFloat indicatorWidth =
          [self.helpPageIndicator sizeWithAttributes:commentAttributes].width + 8;
      CGFloat pageX = self.bounds.size.width - QueryPanelHorizontalPadding() -
          28 - indicatorWidth + 8;
      DrawQueryTextTruncated(self.helpPageIndicator, commentFont,
          NSColor.secondaryLabelColor, row, pageX, indicatorWidth - 8);
    }
  }
  NSRect helpCircleRect = NSInsetRect(self.helpIconRect, 5, 5);
  NSBezierPath *helpCircle = [NSBezierPath bezierPathWithOvalInRect:helpCircleRect];
  [NSColor.secondaryLabelColor setStroke];
  helpCircle.lineWidth = 1.2;
  [helpCircle stroke];
  CGFloat iconDiameter = MIN(NSWidth(helpCircleRect), NSHeight(helpCircleRect));
  CGFloat glyphHeight = iconDiameter * 0.54;
  CGFloat dotDiameter = iconDiameter * 0.12;
  CGFloat gap = iconDiameter * 0.08;
  CGFloat stemWidth = dotDiameter * 0.88;
  CGFloat stemHeight = glyphHeight - dotDiameter - gap;
  CGFloat glyphBottom = NSMidY(helpCircleRect) - glyphHeight / 2;
  NSRect stemRect = NSMakeRect(NSMidX(helpCircleRect) - stemWidth / 2,
      glyphBottom, stemWidth, stemHeight);
  NSRect dotRect = NSMakeRect(NSMidX(helpCircleRect) - dotDiameter / 2,
      NSMaxY(stemRect) + gap, dotDiameter, dotDiameter);
  [NSColor.secondaryLabelColor setFill];
  [[NSBezierPath bezierPathWithRoundedRect:stemRect
      xRadius:stemWidth / 2 yRadius:stemWidth / 2] fill];
  [[NSBezierPath bezierPathWithOvalInRect:dotRect] fill];
}
@end

static STQueryBridgeViewV4 *QueryView(void) {
  return (STQueryBridgeViewV4 *)query_panel.contentView;
}

static NSString *SelectedQueryCandidate(void) {
  if (!query_active || !query_panel) return nil;
  STQueryBridgeViewV4 *view = QueryView();
  NSInteger selected = view.highlighted;
  return selected >= 0 && selected < (NSInteger)view.candidates.count ?
      view.candidates[(NSUInteger)selected] : nil;
}

static void ToggleQueryHelp(void) {
  if (!query_active || !query_panel) return;
  ResetQueryRepeatAction();
  if (!query_help_visible && !query_panel_position_pinned && query_panel.visible) {
    NSRect frame = query_panel.frame;
    query_panel_pinned_top_left = NSMakePoint(NSMinX(frame), NSMaxY(frame));
    query_panel_position_pinned = YES;
  }
  query_help_visible = !query_help_visible;
  query_help_selected = 0;
  ShowQueryContext();
}

static void CopySelectedQueryComment(void) {
  ResetQueryRepeatAction();
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

static void CopyQueryTextToPasteboard(NSString *text) {
  if (!text.length) return;
  NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
  [pasteboard clearContents];
  [pasteboard setString:text forType:NSPasteboardTypeString];
}

static NSString *QueryTranslationText(NSString *candidate) {
  NSString *target = QueryTargetForCandidate(candidate);
  if (!target.length) return nil;
  return query_public_translation_texts[QueryTranslationKey(target, candidate)];
}

static void PerformQueryTranslationAction(STQueryTranslationAction action,
                                         NSString *translation) {
  if (!translation.length) return;
  if (action == STQueryTranslationActionCopy) {
    CopyQueryTextToPasteboard(translation);
  } else if (action == STQueryTranslationActionSpeak) {
    if (!query_speech_synthesizer)
      query_speech_synthesizer = [[NSSpeechSynthesizer alloc] initWithVoice:nil];
    [query_speech_synthesizer stopSpeaking];
    [query_speech_synthesizer startSpeakingString:translation];
  }
}

static NSString *FirstActionableQueryCandidate(void) {
  if (!query_active || !query_panel.visible || query_help_visible ||
      query_search_feedback || IsKeywordInputMode()) return nil;
  STQueryBridgeViewV4 *view = QueryView();
  NSString *candidate = view.candidates.firstObject;
  return candidate.length && ![candidate isEqualToString:@"·"] ? candidate : nil;
}

static void ResetQueryRepeatAction(void) {
  query_repeat_action_character = 0;
  query_repeat_action_count = 0;
  query_repeat_action_base_text = nil;
  query_repeat_action_candidate = nil;
}

static CGKeyCode QueryRepeatActionKeycode(unichar character) {
  switch (character) {
    case 'g': return kVK_ANSI_G;
    case 'b': return kVK_ANSI_B;
    case 'c': return kVK_ANSI_C;
    case 'p': return kVK_ANSI_P;
    case 'n': return kVK_ANSI_N;
    default: return 0;
  }
}

static BOOL HandleQueryRepeatAction(unichar character, BOOL autorepeat) {
  if (autorepeat || (character != 'g' && character != 'b' &&
                     character != 'c' && character != 'p' &&
                     character != 'n') ||
      IsKeywordInputMode() || query_help_visible || query_search_feedback ||
      !query_panel.visible) {
    ResetQueryRepeatAction();
    return NO;
  }

  // Consume the rest of a qualifying run so it cannot arm the same action again.
  if (query_repeat_action_character == character &&
      query_repeat_action_count >= 3 && query_repeat_action_candidate.length &&
      query_repeat_action_base_text &&
      [query_text isEqualToString:query_repeat_action_base_text]) {
    return YES;
  }

  if (query_repeat_action_character == character &&
      query_repeat_action_candidate.length && query_repeat_action_base_text &&
      query_repeat_action_count > 0 && query_repeat_action_count < 3) {
    NSMutableString *expected = [query_repeat_action_base_text mutableCopy];
    for (NSUInteger index = 0; index < query_repeat_action_count; ++index)
      [expected appendFormat:@"%C", character];
    if ([query_text isEqualToString:expected]) {
      if (query_repeat_action_count == 1) {
        query_repeat_action_count = 2;
        return NO;
      }
      if (query_repeat_action_count >= 2) {
        NSString *candidate = query_repeat_action_candidate;
        NSString *baseText = query_repeat_action_base_text;
        query_repeat_action_tail_keycode = QueryRepeatActionKeycode(character);
        query_repeat_action_tail_deadline =
            CFAbsoluteTimeGetCurrent() + 0.35;
        query_repeat_action_count = 3;
        query_text = [baseText mutableCopy];
        query_phone_prefix_active = IsDirectPhoneQueryText(query_text);
        query_utility_highlighted = 0;
        AdvanceQueryGeneration();
        SetQueryInput(query_text);
        ShowQueryContext();

        if (character == 'g' || character == 'b') {
          if (OpenQuerySearchForCandidate(
              character == 'g' ? kVK_ANSI_G : kVK_ANSI_B, candidate))
            HideQueryPanel();
        } else if (character == 'n') {
          if (OpenInternalNewsExtensionForCandidate(candidate))
            HideQueryPanel();
        } else {
          STQueryTranslationAction action = character == 'c' ?
              STQueryTranslationActionCopy : STQueryTranslationActionSpeak;
          NSString *translation = QueryTranslationText(candidate);
          if (translation.length) {
            PerformQueryTranslationAction(action, translation);
            HideQueryPanel();
          } else {
            query_pending_translation_action = action;
            query_pending_translation_candidate = candidate;
            query_pending_translation_generation = query_utility_generation;
            NSString *target = QueryTargetForCandidate(candidate);
            if (target) {
              SquirrelQueryTranslationRequest(candidate.UTF8String,
                  target.UTF8String, (uint64_t)query_utility_generation,
                  QueryTranslationDidFinish, NULL);
            } else {
              query_pending_translation_action = STQueryTranslationActionNone;
              query_pending_translation_candidate = nil;
            }
          }
        }
        return YES;
      }
      return NO;
    }
  }

  ResetQueryRepeatAction();
  NSString *candidate = query_text.length ? FirstActionableQueryCandidate() : nil;
  if (candidate.length) {
    query_repeat_action_character = character;
    query_repeat_action_count = 1;
    query_repeat_action_base_text = [query_text copy];
    query_repeat_action_candidate = candidate;
  }
  return NO;
}

static void CopySelectedQueryCandidate(void) {
  ResetQueryRepeatAction();
  NSString *text = SelectedQueryCandidate();
  if (!text.length) return;
  NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
  [pasteboard clearContents];
  [pasteboard setString:text forType:NSPasteboardTypeString];
}

static NSString *ConfigString(RimeConfig *config, const char *key) {
  const char *value = query_api->config_get_cstring(config, key);
  return value && *value ? [NSString stringWithUTF8String:value] : nil;
}

static NSInteger QueryPagingDirectionForEvent(CGEventRef event, CGKeyCode keycode,
                                               CGEventFlags flags) {
  if (!query_paging_bindings.count || query_search_feedback) return 0;
  if (!(flags & (kCGEventFlagMaskShift | kCGEventFlagMaskControl |
                 kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand)) &&
      (QueryPageDirection(keycode) || QueryRowDirection(keycode))) return 0;
  // Search shortcuts and the unassigned Ctrl+N key pass through schema paging.
  if ((flags & kCGEventFlagMaskControl) &&
      (keycode == kVK_ANSI_G || keycode == kVK_ANSI_B || keycode == kVK_ANSI_N)) return 0;
  if ((flags & kCGEventFlagMaskCommand) && keycode == kVK_ANSI_V) return 0;
  NSString *key = nil;
  switch (keycode) {
    case kVK_LeftArrow: key = @"Left"; break;
    case kVK_RightArrow: key = @"Right"; break;
    case kVK_UpArrow: key = @"Up"; break;
    case kVK_DownArrow: key = @"Down"; break;
    case kVK_PageUp: key = @"Page_Up"; break;
    case kVK_PageDown: key = @"Page_Down"; break;
    case kVK_Home: key = @"Home"; break;
    case kVK_End: key = @"End"; break;
    case kVK_Tab: key = @"\t"; break;
    case kVK_Return: key = @"\r"; break;
    default: {
      key = [NSEvent eventWithCGEvent:event].charactersIgnoringModifiers;
      if (key.length == 1) {
        unichar character = [key characterAtIndex:0];
        if (character >= NSF1FunctionKey && character <= NSF35FunctionKey)
          key = [NSString stringWithFormat:@"F%d", character - NSF1FunctionKey + 1];
      }
      break;
    }
  }
  BOOL hasMenu = QueryView().candidates.count > 0;
  BOOL composing = QueryView().input.length > 0;
  BOOL keywordInput = !query_help_visible && IsKeywordInputMode();
  // Most typing does not match a binding. Avoid querying the Rime context or
  // rebuilding utility rows for those events.
  if (!QueryConfiguredPageDirection(query_paging_bindings, key, flags,
      hasMenu, composing, YES, keywordInput)) return 0;
  NSInteger utilityCount = query_help_visible ? 0 : QueryUtilityCandidateCount();
  BOOL paging = query_help_visible ? query_help_selected >= kQueryUtilityPageSize :
      utilityCount > 0 ? query_utility_highlighted >= kQueryUtilityPageSize : NO;
  if (!query_help_visible && utilityCount == 0) {
    RimeContext_stdbool context = {0};
    RIME_STRUCT_INIT(RimeContext_stdbool, context);
    if (query_api->get_context(query_session, &context)) {
      paging = context.menu.page_no > 0;
      query_api->free_context(&context);
    }
  }
  return QueryConfiguredPageDirection(query_paging_bindings, key, flags,
      hasMenu, composing, paging, keywordInput);
}

static NSArray<NSArray<NSString *> *> *QueryHelpEntries(void) {
  NSString *defaultEngine = SearchEngineDisplayName(NO);
  NSString *secondaryEngine = SearchEngineDisplayName(YES);
#if defined(SQUIRREL_ENABLE_INTERNAL_NEWS_EXTENSION_ACTION)
  NSString *newsActionHelp = @"内部构建配置后用新闻扩展搜索首候选";
#else
  NSString *newsActionHelp = @"公开版不执行动作（触发按键会被吞掉）";
#endif
  NSArray<NSArray<NSString *> *> *entries = @[
    @[@"⌃T", @"开启或关闭候选翻译"],
    @[@"⌃P", @"朗读当前候选的译文"],
    @[@"⌃Y", @"上屏当前候选的译文"],
    @[@"⇧^", @"展开或收起当前候选的完整翻译"],
    @[@"⇧P", @"开启或关闭音标显示"],
    @[@"⌃G", [NSString stringWithFormat:@"%@ 搜索当前候选", defaultEngine]],
    @[@"⌃B", [NSString stringWithFormat:@"%@ 搜索当前候选", secondaryEngine]],
    @[@"ggg / bbb", @"搜索首候选（默认／第二引擎）"],
    @[@"ccc", @"复制首候选译文"],
    @[@"ppp", @"朗读首候选译文"],
    @[@"nnn", newsActionHelp],
    @[@"⌘C", @"复制当前结果信息"],
    @[@"空格", @"复制当前候选词；取色时选定颜色或重新取色"],
    @[@"ucolorRRGGBB / rgb(...) ", @"支持省略 #；方向键选格式，⌘C复制颜色值"],
    @[@"utime时间戳", @"转换 Unix 秒／毫秒；不带参数时显示输入时刻快照"],
    @[@"utime时区／城市", @"支持城市拼音，例如：niuyue、dongjing"],
    @[@"udate日期", @"8 位日期可直接换算；双日期用 .、- 或空格分隔"],
    @[@"umaxwidth数字", @"设置 U 面板最大宽度（200–2000 pt，默认 400）"],
    @[@"层高设置", @"ufloorheight3.2（3.2:层高；可设置范围2-12米；默认3米）"],
    @[@"uconv2.6mp1 / uconv2.6mpa1", @"末尾类别码：1一类高层公共建筑；2二类高层公共建筑／多层公共建筑；3其他"],
    @[@"消防静压默认设置", @"ufiredefault1-0.15 设置类别1静压MPa；类别2默认0.07；类别3默认0.01（用户参考值）"],
    @[@"u<语言>", @"按 u<语言> 设置界面语言，例如 ulangen / ulangko / ulangja / ulangtw"],
    @[@"uconv5 / uconv5mi / uconv100rmb", @"支持压力、质量、电气及货币换算"],
    @[@"颜色取色时 ←↑↓→", @"将采样点移动一个物理像素；按空格选色"],
    @[@"数字和标点", @"直接输入并显示；8 位日期自动进入日期换算"],
    @[@"↑ / ↓", @"移动选择候选词或帮助条目；到页边缘自动跨页"],
    @[@"← / →", @"上一页／下一页；每页最多 9 条"],
    @[@"PageUp / PageDown", @"上一页／下一页，同左右方向键"],
    @[@"方案翻页键", @"沿用鼠须管当前方案；不使用 -、= 翻页"],
    @[@"⌘,", @"关闭快捷键帮助"],
    @[@"u<引擎>1", @"设置 ⌃G 搜索引擎，例如 ugoogle1"],
    @[@"u<引擎>2", @"设置 ⌃B 搜索引擎，例如 ubing2"],
    @[@"Esc", @"返回原候选列表"],
    @[@"点击 ⓘ", @"打开或关闭本帮助"]
  ];
  NSMutableArray<NSArray<NSString *> *> *localized = [NSMutableArray arrayWithCapacity:entries.count];
  for (NSArray<NSString *> *entry in entries)
    [localized addObject:@[LocalizedQueryText(entry[0]), LocalizedQueryText(entry[1])]];
  return localized;
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
  query_help_selected = 0;
  query_phone_prefix_active = NO;
  query_cache_refresh_pending = NO;
  query_panel_position_pinned = NO;
  query_time_snapshot = nil;
  AdvanceQueryGeneration();
  [query_ip_task cancel];
  query_ip_task = nil;
  query_ip_details = nil;
  query_ip_public_ip = nil;
  query_utility_highlighted = 0;
  query_search_feedback = nil;
  query_search_feedback_title = nil;
  ResetQueryRepeatAction();
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
  } else {
    input = QueryVisibleInput(query_text, input);
  }
  if (query_search_feedback) {
    candidates = [NSMutableArray arrayWithObject:query_search_feedback];
    comments = [NSMutableArray arrayWithObject:@"设置已保存"];
    input = LocalizedQueryText(query_search_feedback_title ?: @"设置结果");
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
  if (utilityMode && !query_help_visible && !query_search_feedback) {
    query_utility_highlighted = QueryClampedSelection(
        (NSInteger)candidates.count, query_utility_highlighted);
    highlighted = query_utility_highlighted;
    helpPageIndicator = PaginateQueryRows(candidates, comments, &highlighted);
  }
  if (query_help_visible) {
    NSArray<NSArray<NSString *> *> *entries = QueryHelpEntries();
    [candidates removeAllObjects];
    [comments removeAllObjects];
    for (NSArray<NSString *> *entry in entries) {
      [candidates addObject:entry[0]];
      [comments addObject:entry[1]];
    }
    query_help_selected = QueryClampedSelection((NSInteger)entries.count,
                                                 query_help_selected);
    highlighted = query_help_selected;
    helpPageIndicator = PaginateQueryRows(candidates, comments, &highlighted);
  }
  if (!candidates.count) {
    [candidates addObject:@"·"];
    [comments addObject:@""];
  }
  for (NSUInteger index = 0; index < candidates.count; ++index) {
    candidates[index] = LocalizedQueryText(candidates[index]);
    comments[index] = LocalizedQueryText(comments[index]);
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
        [QueryVisibleComment(comments[index], view.commentFont, NULL, NULL)
            sizeWithAttributes:commentAttributes].width);
  }
  CGFloat candidateContentWidth = 27 + widestCandidate +
      (widestComment > 0 ? QueryCandidateCommentTabWidth(view.candidateFont) +
          widestComment : 0);
  CGFloat inputContentWidth = 12 +
      [input sizeWithAttributes:@{NSFontAttributeName: view.preeditFont}].width;
  CGFloat indicatorWidth = helpPageIndicator.length ?
      [helpPageIndicator sizeWithAttributes:commentAttributes].width + 8 : 0;
  CGFloat desiredWidth = MAX(180, horizontalPadding * 2 +
      MAX(candidateContentWidth, inputContentWidth) + 40 + indicatorWidth);
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
  CGFloat width = QueryPanelWidth(desiredWidth, maxWidth);
  CGFloat commentColumnX = QueryCommentColumn(width, widestCandidate,
      QueryCandidateCommentTabWidth(view.candidateFont), widestComment > 0, indicatorWidth);
  view.commentColumnX = MAX(horizontalPadding + 27, commentColumnX);
  CGFloat availablePanelHeight = visible.size.height - 24;
  CGFloat availableRowsHeight = availablePanelHeight -
      QueryPanelVerticalPadding() * 2 - inputHeight;
  NSArray<NSNumber *> *rowHeights = QueryMeasuredRowHeights(candidates, comments,
      view.candidateFont, view.commentFont, width, view.commentColumnX,
      indicatorWidth, availableRowsHeight);
  CGFloat totalRowsHeight = 0;
  for (NSNumber *measuredHeight in rowHeights) totalRowsHeight += measuredHeight.doubleValue;
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
  // Phone rows use the raw query string, not Rime candidates. Keep a valid
  // private session when a schema rejects pasted spaces or parentheses.
  if (!inputSet && (query_phone_prefix_active ||
                    UtilityPayload(query_text, @"phone") != nil)) {
    inputSet = RIME_PROVIDED(query_api, set_input) &&
        query_api->set_input(query_session, "u");
    if (!inputSet) inputSet = query_api->process_key(query_session, 'u', 0);
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

static void ScheduleQueryPanelWidthCommand(void) {
  NSUInteger generation = ++query_panel_width_command_generation;
  NSString *payload = [UtilityPayload(query_text, @"maxwidth") copy];
  if (!payload.length) return;
  NSString *command = [query_text copy];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
    if (!query_active || generation != query_panel_width_command_generation ||
        ![query_text isEqualToString:command])
      return;
    NSString *feedback = SaveQueryPanelMaxWidth(payload);
    if (!feedback) return;
    query_text = [NSMutableString string];
    query_search_feedback = feedback;
    query_search_feedback_title = @"面板宽度设置";
    RebuildQuerySession();
    ShowQueryContext();
  });
}

static void ScheduleQueryFloorHeightCommand(void) {
  NSUInteger generation = ++query_floor_height_command_generation;
  NSString *payload = [UtilityPayload(query_text, @"floorheight") copy];
  if (!payload.length) return;
  NSString *command = [query_text copy];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
    if (!query_active || generation != query_floor_height_command_generation ||
        ![query_text isEqualToString:command])
      return;
    NSString *feedback = SaveQueryFloorHeight(payload);
    query_text = [NSMutableString string];
    query_search_feedback = feedback;
    query_search_feedback_title = @"层高设置";
    RebuildQuerySession();
    ShowQueryContext();
  });
}

static void ScheduleFireStaticPressureDefaultCommand(void) {
  NSUInteger generation = ++query_fire_pressure_command_generation;
  NSString *payload = [UtilityPayload(query_text, @"firedefault") copy];
  if (!payload.length) return;
  NSInteger category = 0;
  double pressureMPa = 0;
  if (!ParseFireStaticPressureDefault(payload, &category, &pressureMPa)) return;
  NSString *command = [query_text copy];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
    if (!query_active || generation != query_fire_pressure_command_generation ||
        ![query_text isEqualToString:command])
      return;
    NSString *feedback = SaveFireStaticPressureDefault(category, pressureMPa);
    query_text = [NSMutableString string];
    query_search_feedback = feedback;
    query_search_feedback_title = @"消防静压默认设置";
    RebuildQuerySession();
    ShowQueryContext();
  });
}

static void RemoveLastQueryCharacter(void) {
  ResetQueryRepeatAction();
  if (query_text.length) {
    NSRange lastCharacter = [query_text
        rangeOfComposedCharacterSequenceAtIndex:query_text.length - 1];
    [query_text deleteCharactersInRange:lastCharacter];
  }
  if (!query_text.length) {
    // Keep the prefix panel available for another query after deleting the
    // final typed letter; Rime rebuild resets both its composition and Lua env.
  }
  ScheduleQueryPanelWidthCommand();
  ScheduleQueryFloorHeightCommand();
  ScheduleFireStaticPressureDefaultCommand();
  query_phone_prefix_active = IsDirectPhoneQueryText(query_text);
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
  ResetQueryRepeatAction();
  query_search_feedback = nil;
  query_search_feedback_title = nil;
  [query_text appendString:normalized];
  query_phone_prefix_active = IsDirectPhoneQueryText(query_text);
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
      query_search_feedback_title = @"搜索引擎设置";
      RebuildQuerySession();
    } else {
      NSString *languageFeedback = ConfigureQueryLanguage(query_text);
      if (languageFeedback) {
        query_text = [NSMutableString string];
        query_search_feedback = languageFeedback;
        query_search_feedback_title = @"语言设置";
        RebuildQuerySession();
      } else {
        BOOL completeIP = NO;
        if ([query_text isEqualToString:@"ip"]) ScheduleIPLookup(nil);
        else if (IPv4QueryStatus(SpecificIPInput(), &completeIP) && completeIP)
          ScheduleIPLookup(SpecificIPInput());
      }
    }
    ScheduleQueryPanelWidthCommand();
    ScheduleQueryFloorHeightCommand();
    ScheduleFireStaticPressureDefaultCommand();
    ShowQueryContext();
  }
}

static BOOL TranslationCacheChanged(void) {
  NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:
      @"Library/Rime/input_translation.cache.tsv"];
  struct stat info;
  if (stat(path.fileSystemRepresentation, &info) != 0) {
    BOOL changed = query_cache_size != -1;
    query_cache_size = -1;
    query_cache_mtime = (struct timespec){0};
    return changed;
  }
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
    if (TranslationCacheChanged()) query_cache_refresh_pending = YES;
    if (query_cache_refresh_pending && !query_color_sampling_active &&
        CFAbsoluteTimeGetCurrent() - query_last_key_time > 0.35 &&
        RebuildQuerySession())
      query_cache_refresh_pending = NO;
  });
  dispatch_resume(query_refresh_source);
}

static BOOL StartQuery(void) {
  if (!EnsureQuerySession()) {
    SetQueryBridgeStatus(@"prefix rejected: Rime session unavailable");
    return NO;
  }
  query_text = [NSMutableString string];
  // Read the deployed (already patched/imported) schema once per opening, not
  // on every keystroke or asynchronous repaint. A newly deployed config takes
  // effect the next time the U panel opens.
  query_paging_bindings = QueryLoadPagingBindings(query_api, query_session);
  query_phone_prefix_active = NO;
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
  query_cache_refresh_pending = NO;
  TranslationCacheChanged();
  StartQueryRefresh();
  ShowQueryContext();
  [query_panel orderFrontRegardless];
  SetQueryBridgeStatus(@"panel requested: 9-row pagination; global hotkeys first");
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
    if (query_repeat_action_tail_keycode == released &&
        CFAbsoluteTimeGetCurrent() <= query_repeat_action_tail_deadline)
      return NULL;
    if ([query_paging_keyup_pending containsIndex:released]) {
      [query_paging_keyup_pending removeIndex:released];
      return NULL;
    }
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
  if (query_repeat_action_tail_keycode) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now > query_repeat_action_tail_deadline) {
      query_repeat_action_tail_keycode = 0;
    } else if (keycode == query_repeat_action_tail_keycode) {
      query_repeat_action_tail_deadline = now + 0.35;
      return NULL;
    } else {
      query_repeat_action_tail_keycode = 0;
    }
  }
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
  NSInteger configuredPage = query_active ?
      QueryPagingDirectionForEvent(event, keycode, flags) : 0;
  if (configuredPage) {
    if (!query_paging_keyup_pending) query_paging_keyup_pending = [NSMutableIndexSet indexSet];
    [query_paging_keyup_pending addIndex:keycode];
    dispatch_async(dispatch_get_main_queue(), ^{
      ResetQueryRepeatAction();
      if (!query_active || query_search_feedback) return;
      if (query_help_visible) {
        query_help_selected = QueryMovePage((NSInteger)QueryHelpEntries().count,
            query_help_selected, configuredPage);
        ShowQueryContext();
      } else {
        NSInteger count = QueryUtilityCandidateCount();
        if (count > 0) {
          query_utility_highlighted = QueryMovePage(count, query_utility_highlighted,
                                                   configuredPage);
          ShowQueryContext();
        } else {
          ProcessQueryKey(configuredPage < 0 ? 0xff55 : 0xff56);
        }
      }
      query_last_key_time = CFAbsoluteTimeGetCurrent();
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
    if (plainNavigation && (QueryRowDirection(keycode) || QueryPageDirection(keycode))) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!query_active || !query_help_visible) return;
        query_help_selected = QueryNavigateSelection(
            (NSInteger)QueryHelpEntries().count, query_help_selected, keycode);
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
    if (!(query_text.length == 8 && IsASCIIDigitString(query_text)) &&
        !query_phone_prefix_active &&
        UtilityPayload(query_text, @"phone") == nil) {
      dispatch_async(dispatch_get_main_queue(), ^{
        CopySelectedQueryCandidate();
      });
      return NULL;
    }
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
  if (query_active && keycode == kVK_Escape &&
      (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                kCGEventFlagMaskAlternate | kCGEventFlagMaskShift)) == 0) {
    query_escape_keyup_pending = YES;
    HideQueryPanel();
    return NULL;
  }
  if (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl)) {
    if (query_active)
      dispatch_async(dispatch_get_main_queue(), ^{ ResetQueryRepeatAction(); });
    return event;
  }
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
    if (utilityCount > 0 && !query_search_feedback &&
        (QueryRowDirection(keycode) || QueryPageDirection(keycode))) {
      dispatch_async(dispatch_get_main_queue(), ^{
        ResetQueryRepeatAction();
        if (!query_active || query_help_visible || query_search_feedback) return;
        NSInteger count = QueryUtilityCandidateCount();
        if (count <= 0) return;
        query_utility_highlighted = QueryNavigateSelection(count, query_utility_highlighted, keycode);
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
      case kVK_LeftArrow: navigationKey = 0xff55; break;     // XK_Page_Up
      case kVK_RightArrow: navigationKey = 0xff56; break;    // XK_Page_Down
      default: break;
    }
    if (navigationKey) {
      dispatch_async(dispatch_get_main_queue(), ^{
        ResetQueryRepeatAction();
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
  BOOL autorepeat = CGEventGetIntegerValueField(event,
      kCGKeyboardEventAutorepeat) != 0;
  BOOL plainDigit = character >= '0' && character <= '9' &&
      !(flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                 kCGEventFlagMaskAlternate | kCGEventFlagMaskShift));
  BOOL asciiPunctuation = character >= 0x21 && character <= 0x7e &&
      !((character >= 'a' && character <= 'z') ||
        (character >= 'A' && character <= 'Z') ||
        (character >= '0' && character <= '9'));
  BOOL punctuation = asciiPunctuation ||
      [[NSCharacterSet punctuationCharacterSet] characterIsMember:character];
  BOOL dateSeparatorSpace = character == ' ' && query_text.length == 8 &&
      IsASCIIDigitString(query_text);
  BOOL phoneSeparatorSpace = character == ' ' &&
      (query_phone_prefix_active || UtilityPayload(query_text, @"phone") != nil);
  if ((character >= 'a' && character <= 'z') ||
      (keywordInput && ((character >= 0x21 && character <= 0x7e) ||
                        character == 0x00b0)) || plainDigit ||
      punctuation || dateSeparatorSpace || phoneSeparatorSpace) {
    if (plainDigit && keycode < 64)
      query_number_keyup_pending |= UINT64_C(1) << keycode;
    if (dateSeparatorSpace || phoneSeparatorSpace) query_space_keyup_pending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (HandleQueryRepeatAction(character, autorepeat)) return;
      query_search_feedback = nil;
      query_search_feedback_title = nil;
      [query_text appendFormat:@"%C", character];
      query_phone_prefix_active = IsDirectPhoneQueryText(query_text);
      query_utility_highlighted = 0;
      query_last_key_time = CFAbsoluteTimeGetCurrent();
      AdvanceQueryGeneration();
      NSString *feedback = ConfigureQuerySearchEngine(query_text);
      if (feedback) {
        query_text = [NSMutableString string];
        query_search_feedback = feedback;
        query_search_feedback_title = @"搜索引擎设置";
        RebuildQuerySession();
        ShowQueryContext();
        return;
      }
      NSString *languageFeedback = ConfigureQueryLanguage(query_text);
      if (languageFeedback) {
        query_text = [NSMutableString string];
        query_search_feedback = languageFeedback;
        query_search_feedback_title = @"语言设置";
        RebuildQuerySession();
        ShowQueryContext();
        return;
      }
      BOOL inputSet = SetQueryInput(query_text);
      BOOL rawUtilityInput = plainDigit || punctuation || dateSeparatorSpace ||
          phoneSeparatorSpace;
      if (!inputSet && !rawUtilityInput)
        inputSet = ProcessQueryKey((int)character);
      if (!inputSet && !rawUtilityInput) {
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
      ScheduleQueryPanelWidthCommand();
      ScheduleQueryFloorHeightCommand();
      ScheduleFireStaticPressureDefaultCommand();
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
  query_tap = CGEventTapCreate(kCGSessionEventTap, QueryTapPlacement(),
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
  SetQueryBridgeStatus(@"installed: 9-row pagination; global hotkeys first; waiting for u");
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
