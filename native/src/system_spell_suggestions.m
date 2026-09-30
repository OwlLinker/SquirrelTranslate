#import <AppKit/AppKit.h>

#include <stdlib.h>
#include <string.h>

char* SquirrelTranslateSpellSuggestions(const char* word) {
  if (!word || word[0] == '\0') return NULL;
  @autoreleasepool {
    NSString* input = [NSString stringWithUTF8String:word];
    if (!input) return NULL;
    NSArray<NSString*>* guesses = [[NSSpellChecker sharedSpellChecker]
        guessesForWordRange:NSMakeRange(0, input.length)
                   inString:input
                   language:@"en_US"
      inSpellDocumentWithTag:0];
    if (guesses.count == 0) return NULL;

    NSCharacterSet* invalidCharacters =
        [[NSCharacterSet characterSetWithCharactersInString:
              @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-'"]
            invertedSet];
    NSMutableArray<NSString*>* valid = [NSMutableArray array];
    for (NSString* guess in guesses) {
      if (guess.length > 0 &&
          [guess rangeOfCharacterFromSet:invalidCharacters].location ==
              NSNotFound) {
        [valid addObject:guess];
      }
    }
    if (valid.count == 0) return NULL;

    NSData* data = [[valid componentsJoinedByString:@"\n"]
        dataUsingEncoding:NSUTF8StringEncoding];
    char* output = (char*)malloc(data.length + 1);
    if (!output) return NULL;
    memcpy(output, data.bytes, data.length);
    output[data.length] = '\0';
    return output;
  }
}
