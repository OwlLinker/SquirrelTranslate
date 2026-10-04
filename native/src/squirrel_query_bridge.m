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
static CFAbsoluteTime query_last_key_time;
static BOOL query_prefix_armed = YES;
static CGFloat query_panel_max_width = 400;
static BOOL query_panel_max_width_loaded;
static NSString *query_ui_language;
static NSUInteger query_panel_width_command_generation;
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
static NSString *SelectedQueryCandidate(void);

static void AdvanceQueryGeneration(void) {
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

static NSString *QueryPanelWidthProfilePath(void) {
  return [@"~/Library/Rime/input_translation.query_panel_max_width"
      stringByExpandingTildeInPath];
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
        @"本地 IP": @"Local IP", @"公网 IP": @"Public IP", @"IP 地址查询": @"IP lookup",
        @"输入 IPv4 地址": @"Enter an IPv4 address", @"号码归属地": @"Phone region",
        @"座机归属地": @"Landline region", @"号码格式不正确": @"Invalid phone number",
        @"未找到该号段": @"Prefix not found", @"地区未收录": @"Region unavailable",
        @"过去天数": @"Days ago", @"剩余天数": @"Days remaining", @"相差天数": @"Days apart",
        @"开始日期": @"Start date", @"结束日期": @"End date", @"今天": @"Today",
        @"点击屏幕选择颜色": @"Click to pick a color", @"不可用": @"Unavailable",
        @"本地时间": @"Local time", @"目标时区": @"Target time zone", @"Unix 秒": @"Unix seconds", @"Unix 毫秒": @"Unix milliseconds",
        @"日期格式": @"Date format", @"日期间隔": @"Date interval", @"时区或时间戳": @"Time zone or timestamp", @"时间戳超出范围": @"Timestamp out of range",
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
        @"用第二搜索引擎搜索当前候选": @"Search with the second engine", @"打开新闻扩展并搜索当前候选": @"Search with the news extension",
        @"复制当前结果信息": @"Copy the selected result", @"复制当前候选词；取色时选定颜色或重新取色": @"Copy candidate; confirm or resume color sampling",
        @"关闭快捷键帮助": @"Close shortcut help", @"打开或关闭本帮助": @"Toggle this help",
        @"上一页／下一页；每页最多 9 条": @"Previous/next page; up to 9 rows per page",
        @"移动选择候选词或帮助条目；到页边缘自动跨页": @"Move through candidates or help; cross pages at the edges",
        @"数字和标点": @"Digits and punctuation", @"直接输入并显示；8 位日期自动进入日期换算": @"Type to enter; valid 8-digit dates open date conversion",
        @"按 u<语言> 设置界面语言，例如 ulangen / ulangko / ulangja / ulangtw": @"Set the UI with u<language>: ulangen, ulangko, ulangja or ulangtw",
        @"umaxwidth数字": @"umaxwidth<number>", @"设置 U 面板最大宽度（200–2000 pt，默认 400）": @"Set U panel width (200–2000 pt; default 400)",
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
        @"本地 IP": @"로컬 IP", @"公网 IP": @"공인 IP", @"IP 地址查询": @"IP 조회",
        @"输入 IPv4 地址": @"IPv4 주소 입력", @"号码归属地": @"전화번호 지역", @"座机归属地": @"유선전화 지역",
        @"号码格式不正确": @"전화번호 형식이 올바르지 않습니다", @"未找到该号段": @"번호 대역을 찾을 수 없습니다",
        @"地区未收录": @"지역 정보 없음", @"过去天数": @"지난 일수", @"剩余天数": @"남은 일수", @"相差天数": @"날짜 차이",
        @"开始日期": @"시작 날짜", @"结束日期": @"종료 날짜", @"今天": @"오늘", @"点击屏幕选择颜色": @"화면을 클릭해 색상 선택",
        @"不可用": @"사용할 수 없음", @"颜色": @"색상", @"HEX（无 #）": @"HEX (# 없음)", @"HEX + Alpha": @"HEX + 알파", @"摄氏度": @"섭씨", @"华氏度": @"화씨", @"开尔文": @"켈빈",
        @"本地时间": @"현지 시간", @"目标时区": @"대상 시간대", @"Unix 秒": @"Unix 초", @"Unix 毫秒": @"Unix 밀리초",
        @"日期格式": @"날짜 형식", @"日期间隔": @"날짜 간격", @"时区或时间戳": @"시간대 또는 타임스탬프", @"时间戳超出范围": @"타임스탬프 범위 초과",
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
        @"打开新闻扩展并搜索当前候选": @"뉴스 확장 프로그램에서 검색", @"复制当前结果信息": @"현재 결과 정보 복사",
        @"复制当前候选词；取色时选定颜色或重新取色": @"후보 복사; 색상 선택 또는 다시 샘플링", @"关闭快捷键帮助": @"단축키 도움말 닫기",
        @"打开或关闭本帮助": @"도움말 열기/닫기", @"上一页／下一页；每页最多 9 条": @"이전/다음 페이지 (최대 9개)",
        @"移动选择候选词或帮助条目；到页边缘自动跨页": @"후보/도움말 이동; 가장자리에서 페이지 전환", @"数字和标点": @"숫자와 문장 부호",
        @"直接输入并显示；8 位日期自动进入日期换算": @"직접 입력; 8자리 날짜 자동 변환",
        @"按 u<语言> 设置界面语言，例如 ulangen / ulangko / ulangja / ulangtw": @"u<언어>로 설정: ulangen, ulangko, ulangja 또는 ulangtw",
        @"umaxwidth数字": @"umaxwidth<숫자>", @"设置 U 面板最大宽度（200–2000 pt，默认 400）": @"U 패널 너비 설정 (200–2000pt, 기본 400)",
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
        @"最大面板宽度": @"パネルの最大幅", @"宽度格式不正确": @"幅の形式が正しくありません", @"本地 IP": @"ローカル IP",
        @"公网 IP": @"パブリック IP", @"IP 地址查询": @"IP 検索", @"输入 IPv4 地址": @"IPv4 アドレスを入力",
        @"号码归属地": @"電話番号の地域", @"座机归属地": @"固定電話の地域", @"号码格式不正确": @"電話番号の形式が正しくありません",
        @"未找到该号段": @"番号帯が見つかりません", @"地区未收录": @"地域情報なし", @"过去天数": @"経過日数", @"剩余天数": @"残り日数",
        @"相差天数": @"日数差", @"开始日期": @"開始日", @"结束日期": @"終了日", @"今天": @"今日", @"点击屏幕选择颜色": @"クリックして色を選択",
        @"不可用": @"利用できません", @"颜色": @"色", @"HEX（无 #）": @"HEX（#なし）", @"HEX + Alpha": @"HEX + アルファ", @"摄氏度": @"摂氏", @"华氏度": @"華氏", @"开尔文": @"ケルビン",
        @"本地时间": @"現地時刻", @"目标时区": @"対象タイムゾーン", @"Unix 秒": @"Unix 秒", @"Unix 毫秒": @"Unix ミリ秒",
        @"日期格式": @"日付形式", @"日期间隔": @"日付の間隔", @"时区或时间戳": @"タイムゾーンまたはタイムスタンプ", @"时间戳超出范围": @"タイムスタンプ範囲外",
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
        @"打开新闻扩展并搜索当前候选": @"ニュース拡張機能で検索", @"复制当前结果信息": @"現在の結果をコピー",
        @"复制当前候选词；取色时选定颜色或重新取色": @"候補をコピー；色を確定／再サンプリング", @"关闭快捷键帮助": @"ショートカットヘルプを閉じる",
        @"打开或关闭本帮助": @"ヘルプの表示切り替え", @"上一页／下一页；每页最多 9 条": @"前／次のページ（最大9件）",
        @"移动选择候选词或帮助条目；到页边缘自动跨页": @"候補やヘルプ項目を移動；端でページ切り替え", @"数字和标点": @"数字と句読点",
        @"直接输入并显示；8 位日期自动进入日期换算": @"そのまま入力；8桁の日付は自動変換",
        @"按 u<语言> 设置界面语言，例如 ulangen / ulangko / ulangja / ulangtw": @"u<言語> で設定: ulangen、ulangko、ulangja、ulangtw",
        @"umaxwidth数字": @"umaxwidth<数値>", @"设置 U 面板最大宽度（200–2000 pt，默认 400）": @"U パネル幅を設定（200～2000 pt、既定400）",
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
        @"最大面板宽度": @"最大面板寬度", @"宽度格式不正确": @"寬度格式不正確", @"本地 IP": @"本機 IP", @"公网 IP": @"公網 IP",
        @"IP 地址查询": @"IP 位址查詢", @"输入 IPv4 地址": @"輸入 IPv4 位址", @"号码归属地": @"電話號碼歸屬地", @"座机归属地": @"市話歸屬地",
        @"号码格式不正确": @"號碼格式不正確", @"未找到该号段": @"找不到此號段", @"地区未收录": @"未收錄此地區",
        @"过去天数": @"已過天數", @"剩余天数": @"剩餘天數", @"相差天数": @"相差天數", @"开始日期": @"開始日期", @"结束日期": @"結束日期", @"今天": @"今天",
        @"点击屏幕选择颜色": @"點擊螢幕選取顏色", @"不可用": @"無法使用", @"颜色": @"顏色", @"HEX（无 #）": @"HEX（無 #）", @"HEX + Alpha": @"HEX + Alpha", @"摄氏度": @"攝氏度", @"华氏度": @"華氏度", @"开尔文": @"克耳文",
        @"本地时间": @"本機時間", @"目标时区": @"目標時區", @"Unix 秒": @"Unix 秒", @"Unix 毫秒": @"Unix 毫秒",
        @"日期格式": @"日期格式", @"日期间隔": @"日期間隔", @"时区或时间戳": @"時區或時間戳", @"时间戳超出范围": @"時間戳超出範圍",
        @"单位不支持": @"不支援的單位", @"温度超出范围": @"溫度超出範圍", @"数值超出范围": @"數值超出範圍",
        @"货币换算": @"貨幣換算", @"汇率查询失败": @"匯率查詢失敗",
        @"设置已保存": @"設定已儲存", @"设置结果": @"設定結果", @"搜索引擎设置": @"搜尋引擎設定", @"面板宽度设置": @"面板寬度設定",
        @"开启或关闭候选翻译": @"開啟或關閉候選翻譯", @"朗读当前候选的译文": @"朗讀目前候選詞的譯文", @"上屏当前候选的译文": @"輸入目前候選詞的譯文",
        @"展开或收起当前候选的完整翻译": @"展開或收合目前候選詞的完整翻譯", @"开启或关闭音标显示": @"開啟或關閉音標顯示",
        @"用默认搜索引擎搜索当前候选": @"使用預設搜尋引擎搜尋目前候選詞", @"用第二搜索引擎搜索当前候选": @"使用第二搜尋引擎搜尋目前候選詞",
        @"打开新闻扩展并搜索当前候选": @"開啟新聞擴充功能並搜尋目前候選詞", @"复制当前结果信息": @"複製目前結果資訊",
        @"复制当前候选词；取色时选定颜色或重新取色": @"複製目前候選詞；取色時確認或重新取色", @"关闭快捷键帮助": @"關閉快速鍵說明", @"打开或关闭本帮助": @"開啟或關閉本說明",
        @"umaxwidth数字": @"umaxwidth數字", @"u<语言> 设置界面语言": @"使用 u<語言> 設定介面語言", @"语言": @"語言",
        @"下一页／上一页，同左右方向键": @"上一頁／下一頁，同左右方向鍵", @"颜色格式": @"顏色格式",
        @"输入完整地址 · 例如 uip8.8.8.8": @"輸入完整位址，例如 uip8.8.8.8", @"输入停顿后自动查询": @"停止輸入後自動查詢",
        @"简体中文": @"簡體中文", @"繁體中文": @"繁體中文", @"English": @"英文", @"한국어": @"韓文", @"日本語": @"日文",
        @"设置界面语言，例如 ulangen、ulangko、ulangja、ulangtw": @"使用 ulangen、ulangko、ulangja、ulangtw 設定介面語言"
      }
    };
  });
  NSDictionary<NSString *, NSString *> *table = tables[language];
  NSString *localized = table[text];
  if (localized) return localized;
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
  NSString *candidate = SelectedQueryCandidate();
  if (!candidate.length) return;

  NSString *template = CurrentSearchEngineURL(keycode != kVK_ANSI_G);
  NSString *urlString = [template stringByReplacingOccurrencesOfString:@"{query}"
                                                              withString:QueryURLEncode(candidate)];
  NSURL *url = [NSURL URLWithString:urlString];
  if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

static void OpenQueryNews(void) {
  NSString *candidate = SelectedQueryCandidate();
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
  {@"mmhg", @"mmHg", @"毫米汞柱", 133.3224}
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
    @"megapascal": @"mpa", @"megapascals": @"mpa", @"兆帕": @"mpa",
    @"kgf/cm2": @"kgf/cm²", @"kgf/cm^2": @"kgf/cm²",
    @"kg/cm2": @"kgf/cm²", @"kg/cm^2": @"kgf/cm²", @"kg/cm²": @"kgf/cm²",
    @"公斤压力": @"kgf/cm²", @"千克力每平方厘米": @"kgf/cm²",
    @"毫米汞柱": @"mmhg",
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
  inputUnit = exactElectricalUnit ?: (aliases[inputUnit] ?: inputUnit);
  NSString *currencyCode = CurrencyCodeForUnit(inputUnit);
  if (currencyCode) {
    ScheduleCurrencyLookup(payload, inputValue, currencyCode);
    return query_currency_rows ?: @[@[@"货币换算", @"正在获取每日参考汇率…"]];
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
             [inputUnit isEqualToString:@"mmhg"]) {
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
  // Include conventional mmHg and kgf/cm² even when no input unit is given.
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
  if (UtilityPayload(query_text, @"maxwidth") != nil) count = 1;
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
  // Dedicated U shortcuts retain priority over schema-configured bindings.
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
  NSArray<NSArray<NSString *> *> *entries = @[
    @[@"⌃T", @"开启或关闭候选翻译"],
    @[@"⌃P", @"朗读当前候选的译文"],
    @[@"⌃Y", @"上屏当前候选的译文"],
    @[@"⇧^", @"展开或收起当前候选的完整翻译"],
    @[@"⇧P", @"开启或关闭音标显示"],
    @[@"⌃G", [NSString stringWithFormat:@"%@ 搜索当前候选", defaultEngine]],
    @[@"⌃B", [NSString stringWithFormat:@"%@ 搜索当前候选", secondaryEngine]],
    @[@"⌃N", @"打开新闻扩展并搜索当前候选"],
    @[@"⌘C", @"复制当前结果信息"],
    @[@"空格", @"复制当前候选词；取色时选定颜色或重新取色"],
    @[@"ucolorRRGGBB / rgb(...) ", @"支持省略 #；方向键选格式，⌘C复制颜色值"],
    @[@"utime时间戳／时区", @"查看本地、目标时区、UTC 与 Unix 秒／毫秒"],
    @[@"udate日期", @"8 位日期可直接换算；双日期用 .、- 或空格分隔"],
    @[@"umaxwidth数字", @"设置 U 面板最大宽度（200–2000 pt，默认 400）"],
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
  ScheduleQueryPanelWidthCommand();
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
    if (utilityCount > 0 && !query_search_feedback &&
        (QueryRowDirection(keycode) || QueryPageDirection(keycode))) {
      dispatch_async(dispatch_get_main_queue(), ^{
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
