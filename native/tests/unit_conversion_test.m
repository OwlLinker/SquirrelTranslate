// Test the actual bridge parser without loading its constructor or posting events.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <CoreText/CoreText.h>
#include <rime_api_stdbool.h>
#include <rime_api.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>

static NSArray *query_currency_rows;
static NSMutableString *query_text;
static BOOL query_phone_prefix_active;
static BOOL IsKnownPhonePrefix(NSString *prefix) {
  return [@[@"171", @"132"] containsObject:prefix];
}
static NSString *UtilityPayload(NSString *text, NSString *command) {
  return [command isEqualToString:@"phone"] && [text hasPrefix:@"phone"] ?
      [text substringFromIndex:5] : nil;
}
static NSString *CurrencyCodeForUnit(NSString *unit) { (void)unit; return nil; }
static void ScheduleCurrencyLookup(NSString *payload, double value, NSString *code) {
  (void)payload; (void)value; (void)code;
  assert(!"Unexpected network lookup in local unit conversion test");
}
static double QueryConfiguredFloorHeight(void) { return 3.0; }
static double QueryFireStaticPressureMPa(NSInteger category) {
  return category == 1 ? 0.10 : category == 2 ? 0.07 : 0.01;
}
static CGFloat QueryConfiguredPanelMaxWidth(void) { return 400.0; }
static NSString *QueryUILanguage(void) { return @"zh-Hans"; }
#include "unit_conversion_under_test.inc"

static void ExpectPhone(NSString *input, BOOL direct, NSInteger expectedStatus,
                        NSString *expectedDigits, NSString *expectedArea) {
  query_text = [input mutableCopy];
  query_phone_prefix_active = direct;
  NSString *digits = nil, *area = nil;
  NSInteger status = ValidatePhoneInput(&digits, &area);
  assert(status == expectedStatus);
  assert((!expectedDigits && !digits) || [expectedDigits isEqualToString:digits]);
  assert((!expectedArea && !area) || [expectedArea isEqualToString:area]);
}

static void TestPhoneFormats(void) {
  assert([LandlineRegionForAreaCode(@"021") isEqualToString:@"上海"]);
  assert(LandlineRegionForAreaCode(@"0999") == nil);
  assert(IsDirectPhoneQueryText(@"+"));
  assert(IsDirectPhoneQueryText(@"+86 171 6772 6019"));
  assert(IsDirectPhoneQueryText(@"171"));
  assert(!IsDirectPhoneQueryText(@"color"));
  ExpectPhone(@"+86 171 6772 6019", YES, PhoneInputComplete,
              @"17167726019", nil);
  ExpectPhone(@"phone+86 171 6772 6019", NO, PhoneInputComplete,
              @"17167726019", nil);
  ExpectPhone(@"+86 (21) 6349 3582", YES, PhoneInputComplete,
              @"63493582", @"021");
  ExpectPhone(@"+86\u00a0(21)\u202f6349 3582", YES, PhoneInputComplete,
              @"63493582", @"021");
  ExpectPhone(@"phone+86 (21) 6349 3582", NO, PhoneInputComplete,
              @"63493582", @"021");
  ExpectPhone(@"+86 (21) 6349", YES, PhoneInputIncomplete, @"6349", @"021");
  ExpectPhone(@"+86 (999) 1234 5678", YES, PhoneInputComplete,
              @"12345678", @"0999");
  ExpectPhone(@"+86 171 6772 60190", YES, PhoneInputInvalid, nil, nil);
  ExpectPhone(@"+86 (21) 6349 358X", YES, PhoneInputInvalid, nil, nil);
}

static double ValueFor(NSArray *rows, NSString *label) {
  for (NSArray *row in rows) {
    if ([row[0] isEqualToString:label]) return [row[1] doubleValue];
  }
  assert(!"Missing expected conversion row");
  return NAN;
}

static void ExpectValue(NSArray *rows, NSString *label, double expected) {
  double actual = ValueFor(rows, label);
  assert(isfinite(actual) && fabs(actual - expected) <= fmax(1e-9, fabs(expected) * 1e-6));
}

static NSArray *schemaBindings;
static NSArray *defaultBindings;
static BOOL schemaListExists;
static NSUInteger configCloseCount, statusFreeCount, defaultOpenCount;
static NSString *iteratorPath;

static Bool TestGetStatus(RimeSessionId session, RimeStatus_stdbool *status) {
  assert(session == 17);
  status->schema_id = "test_schema";
  return true;
}
static Bool TestFreeStatus(RimeStatus_stdbool *status) {
  assert(status->schema_id);
  ++statusFreeCount;
  return true;
}
static Bool TestSchemaOpen(const char *schema, RimeConfig *config) {
  assert(strcmp(schema, "test_schema") == 0);
  config->ptr = (__bridge void *)schemaBindings;
  return true;
}
static Bool TestConfigOpen(const char *name, RimeConfig *config) {
  assert(strcmp(name, "default") == 0);
  ++defaultOpenCount;
  config->ptr = (__bridge void *)defaultBindings;
  return true;
}
static Bool TestConfigClose(RimeConfig *config) {
  ++configCloseCount;
  config->ptr = NULL;
  return true;
}
static Bool TestBeginList(RimeConfigIterator *iterator, RimeConfig *config, const char *key) {
  assert(strcmp(key, "key_binder/bindings") == 0);
  if (config->ptr == (__bridge void *)schemaBindings && !schemaListExists) return false;
  iterator->list = config->ptr;
  iterator->index = -1;
  return true;
}
static Bool TestConfigNext(RimeConfigIterator *iterator) {
  NSArray *rows = (__bridge NSArray *)iterator->list;
  if (++iterator->index >= (int)rows.count) return false;
  iteratorPath = [NSString stringWithFormat:@"key_binder/bindings/@%d", iterator->index];
  iterator->path = iteratorPath.UTF8String;
  return true;
}
static void TestConfigEnd(RimeConfigIterator *iterator) { iterator->list = NULL; }
static const char *TestConfigString(RimeConfig *config, const char *key) {
  NSArray *parts = [[NSString stringWithUTF8String:key] componentsSeparatedByString:@"/"];
  NSUInteger index = [[parts[2] substringFromIndex:1] integerValue];
  NSArray *rows = (__bridge NSArray *)config->ptr;
  return [rows[index][parts.lastObject] UTF8String];
}

static void TestSchemaPaging(void) {
  assert(!QueryPagingBinding(@"minus", @"Page_Up", @"has_menu"));
  assert(!QueryPagingBinding(@"equal", @"Page_Down", @"has_menu"));
  assert(!QueryPagingBinding(@"Control+minus", @"Page_Up", @"always"));
  assert(!QueryPagingBinding(@"-", @"Page_Up", @"has_menu"));
  assert(!QueryPagingBinding(@"=", @"Page_Down", @"has_menu"));
  assert(!QueryPagingBinding(@"semicolon", @"Left", @"has_menu"));
  assert(!QueryPagingBinding(@"NoSuchKey", @"Page_Up", @"has_menu"));
  assert(!QueryPagingBinding(@"Mystery+Tab", @"Page_Up", @"always"));
  assert(!QueryPagingBinding(@"semicolon", @"Page_Up", @"unknown"));
  NSArray *bindings = @[
    QueryPagingBinding(@"semicolon", @"Page_Up", @"has_menu"),
    QueryPagingBinding(@"apostrophe", @"Page_Down", @"has_menu"),
    QueryPagingBinding(@"Control+p", @"Page_Up", @"composing"),
    QueryPagingBinding(@"Shift+Tab", @"Page_Down", @"paging"),
    QueryPagingBinding(@"bracketright", @"Next", @"always")];
  assert(QueryConfiguredPageDirection(bindings, @";", 0, YES, YES, NO, NO) == -1);
  assert(QueryConfiguredPageDirection(bindings, @"'", 0, YES, YES, NO, YES) == 1);
  assert(QueryConfiguredPageDirection(bindings, @";", 0, NO, YES, NO, NO) == 0);
  assert(QueryConfiguredPageDirection(bindings, @";", kCGEventFlagMaskShift, YES, YES, NO, NO) == 0);
  assert(QueryConfiguredPageDirection(bindings, @"p", kCGEventFlagMaskControl, YES, YES, NO, NO) == -1);
  assert(QueryConfiguredPageDirection(bindings, @"p", 0, YES, YES, NO, NO) == 0);
  assert(QueryConfiguredPageDirection(bindings, @"\t", kCGEventFlagMaskShift, YES, YES, NO, NO) == 0);
  assert(QueryConfiguredPageDirection(bindings, @"\t", kCGEventFlagMaskShift, YES, YES, YES, NO) == 1);
  assert(QueryConfiguredPageDirection(bindings, @"]", 0, NO, NO, NO, NO) == 1);
  NSArray *dot = @[QueryPagingBinding(@"period", @"Page_Down", @"has_menu")];
  assert(QueryConfiguredPageDirection(dot, @".", 0, YES, YES, NO, NO) == 1);
  assert(QueryConfiguredPageDirection(dot, @".", 0, YES, YES, NO, YES) == 0);
  assert(QueryMovePage(23, 4, QueryConfiguredPageDirection(bindings, @"'", 0,
      YES, YES, NO, YES)) == 13);
  schemaBindings = @[
    @{@"accept": @"semicolon", @"send": @"Page_Up", @"when": @"has_menu"},
    @{@"accept": @"apostrophe", @"send": @"Page_Down", @"when": @"has_menu"},
    @{@"accept": @"minus", @"send": @"Page_Up", @"when": @"has_menu"},
    @{@"accept": @"equal", @"send": @"Page_Down", @"when": @"has_menu"},
    @{@"accept": @"Control+t", @"toggle": @"translation", @"when": @"always"}];
  defaultBindings = @[@{@"accept": @"bracketright", @"send": @"Page_Down", @"when": @"has_menu"}];
  schemaListExists = YES;
  RimeApi_stdbool api = {0};
  RIME_STRUCT_INIT(RimeApi_stdbool, api);
  api.get_status = TestGetStatus;
  api.free_status = TestFreeStatus;
  api.schema_open = TestSchemaOpen;
  api.config_open = TestConfigOpen;
  api.config_close = TestConfigClose;
  api.config_begin_list = TestBeginList;
  api.config_next = TestConfigNext;
  api.config_end = TestConfigEnd;
  api.config_get_cstring = TestConfigString;
  NSArray *loaded = QueryLoadPagingBindings(&api, 17);
  assert(loaded.count == 2 && configCloseCount == 1 && statusFreeCount == 1);
  assert(defaultOpenCount == 0);  // Do not append disabled/default scheme keys.
  schemaBindings = @[];
  assert(QueryLoadPagingBindings(&api, 17).count == 0 && defaultOpenCount == 0);
  schemaListExists = NO;
  assert(QueryLoadPagingBindings(&api, 17).count == 1 && defaultOpenCount == 1);
  assert(configCloseCount == 4 && statusFreeCount == 3);
  assert(!QueryLoadPagingBindings(NULL, 17).count);
  api.config_begin_list = NULL;
  assert(!QueryLoadPagingBindings(&api, 17).count);
}

static void TestPagination(void) {
  assert(QueryTapPlacement() == kCGTailAppendEventTap);
  assert(QueryPageDirection(kVK_LeftArrow) == -1);
  assert(QueryPageDirection(kVK_RightArrow) == 1);
  assert(QueryPageDirection(kVK_PageUp) == -1);
  assert(QueryPageDirection(kVK_PageDown) == 1);
  assert(QueryPageDirection(kVK_UpArrow) == 0 && QueryPageDirection(kVK_DownArrow) == 0);
  assert(QueryRowDirection(kVK_UpArrow) == -1 && QueryRowDirection(kVK_DownArrow) == 1);
  assert(QueryRowDirection(kVK_LeftArrow) == 0 && QueryRowDirection(kVK_RightArrow) == 0);
  assert(QueryNavigateSelection(23, 4, kVK_RightArrow) == 13);
  assert(QueryNavigateSelection(23, 13, kVK_LeftArrow) == 4);
  assert(QueryNavigateSelection(23, 8, kVK_DownArrow) == 9);
  assert(QueryNavigateSelection(23, 9, kVK_UpArrow) == 8);
  assert(QueryNavigateSelection(23, 22, kVK_RightArrow) == 22);
  assert(QueryNavigateSelection(23, 0, kVK_LeftArrow) == 0);
  assert(QueryNavigateSelection(23, 22, kVK_DownArrow) == 0);
  assert(QueryNavigateSelection(23, 4, kVK_ANSI_A) == 4);
  assert(QueryNavigateSelection(0, 10, kVK_DownArrow) == 0);
  assert(QueryPageCount(0) == 1 && QueryPageCount(9) == 1);
  assert(QueryPageCount(10) == 2 && QueryPageCount(18) == 2 && QueryPageCount(19) == 3);
  assert(QueryMovePage(23, 4, 1) == 13);
  assert(QueryMovePage(23, 13, 1) == 22);
  assert(QueryMovePage(23, 22, 1) == 22);
  assert(QueryMovePage(23, 22, -1) == 13);
  assert(QueryMovePage(23, 4, -1) == 4);
  assert(QueryMovePage(0, 100, 1) == 0);
  for (NSInteger count = 0; count <= 30; ++count) {
    for (NSInteger selected = -1; selected <= count + 1; ++selected) {
      NSMutableArray *labels = [NSMutableArray array];
      NSMutableArray *values = [NSMutableArray array];
      for (NSInteger index = 0; index < count; ++index) {
        [labels addObject:[NSString stringWithFormat:@"候选%ld", (long)index]];
        [values addObject:[NSString stringWithFormat:@"结果%ld", (long)index]];
      }
      NSInteger local = selected;
      NSString *indicator = PaginateQueryRows(labels, values, &local);
      NSInteger clamped = QueryClampedSelection(count, selected);
      assert(labels.count <= 9 && labels.count == values.count);
      assert((indicator != nil) == (count > 9));
      if (!count) { assert(local == 0 && labels.count == 0); continue; }
      assert(local >= 0 && local < (NSInteger)labels.count);
      assert(([labels[local] isEqualToString:[NSString stringWithFormat:@"候选%ld", (long)clamped]]));
      assert(([values[local] isEqualToString:[NSString stringWithFormat:@"结果%ld", (long)clamped]]));
      if (indicator) assert(([indicator isEqualToString:[NSString stringWithFormat:@"%ld/%ld",
          (long)(clamped / 9 + 1), (long)QueryPageCount(count)]]));
    }
  }
  // Nine color formats plus the independent keyword must expose the tenth row.
  assert(QueryMovePage(10, 0, 1) == 9);
  assert(QueryMovePage(10, 9, -1) == 0);
  // uconv1000: test the actual production rows, including the keyword footer.
  NSMutableArray *labels = [NSMutableArray array];
  NSMutableArray *values = [NSMutableArray array];
  for (NSArray *row in RowsForQuickConversions(1000)) {
    [labels addObject:row[0]];
    [values addObject:row[1]];
  }
  [labels addObject:@"换算"];
  [values addObject:@"conv"];
  assert(labels.count > 18 && QueryPageCount((NSInteger)labels.count) == 4);
  NSInteger total = (NSInteger)labels.count;
  for (NSInteger page = 0; page < 4; ++page) {
    NSMutableArray *pageLabels = [labels mutableCopy];
    NSMutableArray *pageValues = [values mutableCopy];
    NSInteger local = page * 9;
    NSString *indicator = PaginateQueryRows(pageLabels, pageValues, &local);
    assert(local == 0 && pageLabels.count == (NSUInteger)MIN(9, total - page * 9));
    assert(([indicator isEqualToString:[NSString stringWithFormat:@"%ld/4", (long)page + 1]]));
    assert([pageValues[0] isEqualToString:values[page * 9]]);
    if (page == 3) assert([pageLabels.lastObject isEqualToString:@"换算"]);
  }
}

static void TestPanelWrapping(void) {
  assert([QueryVisibleInput(@"", @"u") isEqualToString:@"u"]);
  assert([QueryVisibleInput(@"nihao", @"ni hao") isEqualToString:@"uni hao"]);
  assert([QueryVisibleInput(@"conv", @"conv") isEqualToString:@"uconv"]);
  assert([QueryVisibleInput(@"conv5.5", @"conv5.5") isEqualToString:@"uconv5.5"]);
  assert([QueryVisibleInput(@"u", @"u") isEqualToString:@"uu"]);
  assert(QueryPanelWidth(900, 1400) == 400);
  assert(QueryPanelWidth(180, 1400) == 180);
  assert(QueryPanelWidth(900, 320) == 320);
  NSFont *font = [NSFont systemFontOfSize:16];
  CGFloat gap = QueryCandidateCommentTabWidth(font);
  assert(QueryCandidateFontForWidth(@"日期", font, 100) == font);
  for (NSNumber *panelWidth in @[@180, @250, @400]) {
    CGFloat width = panelWidth.doubleValue;
    CGFloat column = QueryCommentColumn(width, 700, gap, YES, 40);
    assert(column > 35 + gap && column < width - 80);
    assert(QueryCommentColumn(width, 700, gap, NO, 40) - gap <= width - 80);
    CGFloat candidateWidth = column - 35 - gap;
    NSString *label = @"这是必须完整单行显示而不能省略或换行的很长候选词 (mmHg)";
    NSFont *fitted = QueryCandidateFontForWidth(label, font, candidateWidth);
    assert([label sizeWithAttributes:@{NSFontAttributeName:fitted}].width <= candidateWidth);
    assert(fitted.pointSize < font.pointSize);
  }
  NSString *longResult = @"毫米汞柱与压力之间可以双向换算。The result wraps automatically inside the panel without overflowing its background.";
  NSString *longLabel = @"uconv5 / uconv5mi / uconv100rmb";
  NSArray *candidates = @[@"毫米汞柱 (mmHg)", longLabel, @"帕 (Pa)"];
  NSArray *comments = @[longResult, @"按单位显示完整换算结果，支持上下选择与左右翻页。", @"101325.024 Pa"];
  CGFloat width = QueryPanelWidth(800, 1400);
  CGFloat column = QueryCommentColumn(width,
      [longLabel sizeWithAttributes:@{NSFontAttributeName:font}].width, gap, YES, 40);
  NSArray<NSNumber *> *heights = QueryMeasuredRowHeights(candidates, comments,
      font, font, width, column, 40, 900);
  CGFloat commentWidth = width - column - 8;
  assert(QueryWrappedLineCount(longResult, font, commentWidth) > 1);
  CGFloat lineHeight = FontLineHeight(font);
  assert(heights[0].doubleValue >= QueryWrappedLineCount(longResult, font, commentWidth) *
      lineHeight + QueryCandidateRowPadding());
  assert(heights[1].doubleValue >= QueryWrappedLineCount(comments[1], font, commentWidth) *
      lineHeight + QueryCandidateRowPadding());
  // Screen-height exhaustion alone may limit lines; width never removes rows.
  CGFloat base = lineHeight + QueryCandidateRowPadding();
  // Candidate length never adds lines, even with explicit line breaks.
  NSArray *singleLineHeights = QueryMeasuredRowHeights(
      @[longLabel, @"很长的候选词标签\n仍然只能显示一行", @"短"],
      @[@"", @"OK", @"OK"], font, font, width, column, 40, 900);
  for (NSNumber *height in singleLineHeights) assert(height.doubleValue == base);
  NSArray *shortLabelHeights = QueryMeasuredRowHeights(@[@"甲", @"乙", @"丙"],
      comments, font, font, width, column, 40, 900);
  assert([heights isEqualToArray:shortLabelHeights]);
  NSArray *limited = QueryMeasuredRowHeights(candidates, comments, font, font,
      width, column, 40, base * 3 + lineHeight);
  CGFloat used = 0;
  for (NSNumber *height in limited) used += height.doubleValue;
  assert(limited.count == candidates.count && used <= base * 3 + lineHeight);
  assert(QueryWrappedLineCount(@"第一行\n第二行", font, 200) == 2);
  assert(QueryWrappedLineCount(@"", font, 100) == 1);

  // Render the actual production view off-screen: no panel, event tap or Rime
  // session is created. Keep this fixture in the ignored build directory.
  CGFloat total = QueryPanelVerticalPadding() * 2 + FontLineHeight(font) + QueryPreeditPadding() * 2;
  for (NSNumber *height in heights) total += height.doubleValue;
  STQueryBridgeViewV4 *view = [[STQueryBridgeViewV4 alloc] initWithFrame:NSMakeRect(0, 0, width, total)];
  view.candidateFont = view.commentFont = view.preeditFont = font;
  view.labelFont = [NSFont systemFontOfSize:12];
  view.input = @"uconv1000pa";
  view.candidates = candidates;
  view.comments = comments;
  view.rowHeights = heights;
  view.commentColumnX = column;
  view.highlighted = 0;
  view.helpPageIndicator = @"2/3";
  view.helpIconRect = NSMakeRect(width - 36, QueryPanelVerticalPadding() +
      (heights.lastObject.doubleValue - 28) / 2, 28, 28);
  NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
      pixelsWide:(NSInteger)width pixelsHigh:(NSInteger)ceil(total) bitsPerSample:8
      samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
      bytesPerRow:0 bitsPerPixel:0];
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:image];
  [view drawRect:view.bounds];
  [NSGraphicsContext restoreGraphicsState];
  NSData *png = [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  assert(png.length && [png writeToFile:@"query-panel-layout-preview.png" atomically:YES]);
}

int main(void) {
  @autoreleasepool {
    TestPhoneFormats();
    TestSchemaPaging();
    TestPagination();
    TestPanelWrapping();
    NSArray *rows = RowsForUnitInput(@"1000pa");
    assert(rows.count == 8);
    ExpectValue(rows, @"帕 (Pa)", 1000);
    ExpectValue(rows, @"千帕 (kPa)", 1);
    ExpectValue(rows, @"兆帕 (MPa)", 0.001);
    ExpectValue(rows, @"公斤压力 (kgf/cm²)", 1000 / 98066.5);
    ExpectValue(rows, @"毫米汞柱 (mmHg)", 1000 / 133.3224);
    ExpectValue(rows, @"水柱高度 (mH₂O)", 1000 / 9806.65);
    assert([rows[6][1] isEqualToString:@"0.0层（按层高3米估算约在0.0层）"]);
    assert([rows[7][0] isEqualToString:@"层高设置"]);
    assert([rows[7][1] isEqualToString:
        @"ufloorheight3.2（3.2:层高；可设置范围2-12米；默认3米）"]);
    ExpectValue(RowsForUnitInput(@"2.6mp"), @"帕 (Pa)", 2600000);
    ExpectValue(RowsForUnitInput(@"2.6MP"), @"兆帕 (MPa)", 2.6);
    ExpectValue(RowsForUnitInput(@"2.6kp"), @"帕 (Pa)", 2600);
    ExpectValue(RowsForUnitInput(@"2.6KP"), @"千帕 (kPa)", 2.6);
    NSArray *fireClass1 = RowsForUnitInput(@"2.6mp1");
    NSArray *fireClass1Long = RowsForUnitInput(@"2.6mpa1");
    NSArray *fireClass2 = RowsForUnitInput(@"2.6MPa2");
    NSArray *fireClass3 = RowsForUnitInput(@"2.6MP3");
    assert(fireClass1.count == 9 && fireClass1Long.count == 9);
    assert([fireClass1[6][0] isEqualToString:@"最不利点最低静压"]);
    assert([fireClass1[6][1] containsString:@"0.1 MPa"]);
    assert([fireClass1[7][0] isEqualToString:@"扣除静压后理论楼层"]);
    assert(fabs([fireClass1[7][1] doubleValue] - 85.0) < 0.1);
    assert([fireClass2[6][1] containsString:@"0.07 MPa"]);
    assert(fabs([fireClass2[7][1] doubleValue] -
        (2600000.0 - 70000.0) / (9806.65 * 3.0)) < 0.1);
    assert([fireClass3[6][1] containsString:@"0.01 MPa"]);
    assert([fireClass3[6][1] containsString:@"用户参考值"]);
    assert(fabs([fireClass3[7][1] doubleValue] -
        (2600000.0 - 10000.0) / (9806.65 * 3.0)) < 0.1);
    NSInteger fireCategory = 0;
    double firePressureMPa = 0;
    assert(ParseFireStaticPressureDefault(@"1-0.15", &fireCategory,
        &firePressureMPa));
    assert(fireCategory == 1 && fabs(firePressureMPa - 0.15) < 1e-9);
    assert(!ParseFireStaticPressureDefault(@"4-0.15", NULL, NULL));
    for (NSString *input in @[@"1kgf/cm2", @"1KGF/CM²", @"1kg/cm^2",
                              @"1kg/cm2", @"1公斤压力", @"1千克力每平方厘米"]) {
      NSArray *converted = RowsForUnitInput(input);
      assert(converted.count == 8);
      ExpectValue(converted, @"帕 (Pa)", 98066.5);
    }
    ExpectValue(RowsForUnitInput(@"760MMHG"), @"帕 (Pa)", 101325.024);
    ExpectValue(RowsForUnitInput(@"1毫米汞柱"), @"帕 (Pa)", 133.3224);
    ExpectValue(RowsForUnitInput(@"1mH2O"), @"帕 (Pa)", 9806.65);
    ExpectValue(RowsForUnitInput(@"1米水柱"), @"帕 (Pa)", 9806.65);
    ExpectValue(RowsForUnitInput(@"2层"), @"帕 (Pa)", 2 * 3.0 * 9806.65);
    NSArray *twoPointOneFloors = RowsForUnitInput(@"61.781895KPA");
    assert([twoPointOneFloors[6][1] isEqualToString:
        @"2.1层（按层高3米估算约在2.1层）"]);
    assert([twoPointOneFloors[7][0] isEqualToString:@"层高设置"]);
    ExpectValue(RowsForUnitInput(@"0.061781895MPA"), @"帕 (Pa)", 61781.895);
    ExpectValue(RowsForUnitInput(@"760MmHg"), @"帕 (Pa)", 101325.024);
    ExpectValue(RowsForUnitInput(@"0pa"), @"公斤压力 (kgf/cm²)", 0);
    ExpectValue(RowsForUnitInput(@"-1000Pa"), @"毫米汞柱 (mmHg)", -1000 / 133.3224);
    ExpectValue(RowsForUnitInput(@"1MPa"), @"公斤压力 (kgf/cm²)", 1000000 / 98066.5);
    NSArray *mass = RowsForUnitInput(@"1kg");
    assert(mass.count == 5);
    ExpectValue(mass, @"克 (g)", 1000);
    for (NSArray *row in mass) assert(![row[0] containsString:@"压力"]);
    ExpectValue(RowsForUnitInput(@"220v"), @"毫伏 (mV)", 220000);
    ExpectValue(RowsForUnitInput(@"1mW"), @"瓦特 (W)", 0.001);
    ExpectValue(RowsForUnitInput(@"1MW"), @"瓦特 (W)", 1000000);
    NSArray *quick = RowsForQuickConversions(1000);
    ExpectValue(quick, @"Pa → mmHg", 1000 / 133.3224);
    ExpectValue(quick, @"mmHg → Pa", 1000 * 133.3224);
    ExpectValue(quick, @"Pa → kgf/cm²", 1000 / 98066.5);
    ExpectValue(quick, @"kgf/cm² → Pa", 1000 * 98066.5);
    ExpectValue(quick, @"Pa → mH₂O", 1000 / 9806.65);
    // Pressure shortcuts remain reachable after pagination.
    NSMutableSet *pagedLabels = [NSMutableSet set];
    for (NSInteger page = 0; page < QueryPageCount((NSInteger)quick.count + 1); ++page) {
      NSMutableArray *labels = [NSMutableArray array];
      NSMutableArray *values = [NSMutableArray array];
      for (NSArray *row in quick) { [labels addObject:row[0]]; [values addObject:row[1]]; }
      [labels addObject:@"换算"]; [values addObject:@"conv"];
      NSInteger selection = page * 9;
      PaginateQueryRows(labels, values, &selection);
      [pagedLabels addObjectsFromArray:labels];
    }
    for (NSString *label in @[@"Pa → mmHg", @"mmHg → Pa", @"Pa → kgf/cm²",
                              @"kgf/cm² → Pa", @"Pa → mH₂O", @"Pa → 大约几层"])
      assert([pagedLabels containsObject:label]);
    puts("Unit conversions and pagination/selection boundary regressions passed.");
  }
  return 0;
}
