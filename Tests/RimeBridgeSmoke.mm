#import <Foundation/Foundation.h>

#import "RimeBridge.h"

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    if (argc != 3) {
      return 2;
    }

    NSString* sharedDataDirectory = [NSString stringWithUTF8String:argv[1]];
    NSString* userDataDirectory = [NSString stringWithUTF8String:argv[2]];
    TDNRimeSession* session = [[TDNRimeSession alloc]
        initWithSharedDataDirectory:sharedDataDirectory
                   userDataDirectory:userDataDirectory];
    if (!session) {
      return 3;
    }

    NSDictionary<NSString*, id>* initialSnapshot = [session currentSnapshot];
    if ([initialSnapshot[@"commitText"] length] != 0) {
      return 4;
    }
    NSArray<NSDictionary<NSString*, NSString*>*>* schemaList = [session schemaList];
    if (schemaList.count != 1 ||
        ![schemaList.firstObject[@"identifier"] isEqualToString:@"luna_pinyin"]) {
      return 5;
    }
    NSDictionary<NSString*, id>* directTextSnapshot = [session processKey:@"你" modifiers:@[]];
    if ([directTextSnapshot[@"handled"] boolValue] ||
        [directTextSnapshot[@"commitText"] length] != 0 ||
        [directTextSnapshot[@"preedit"] length] != 0) {
      return 11;
    }

    NSDictionary<NSString*, id>* escapePreparationSnapshot = [session processKey:@"n" modifiers:@[]];
    if (![escapePreparationSnapshot[@"handled"] boolValue]) {
      return 17;
    }
    [session processKey:@"i" modifiers:@[]];
    [session clearComposition];
    NSDictionary<NSString*, id>* clearedSnapshot = [session currentSnapshot];
    if ([clearedSnapshot[@"commitText"] length] != 0 ||
        [clearedSnapshot[@"preedit"] length] != 0) {
      return 18;
    }

    NSDictionary<NSString*, id>* idleBackspaceSnapshot = [session processKey:@"BackSpace" modifiers:@[]];
    if ([idleBackspaceSnapshot[@"handled"] boolValue] ||
        [idleBackspaceSnapshot[@"preedit"] length] != 0) {
      return 25;
    }
    [session processKey:@"n" modifiers:@[]];
    [session processKey:@"i" modifiers:@[]];
    NSDictionary<NSString*, id>* composingBackspaceSnapshot = [session processKey:@"BackSpace" modifiers:@[]];
    if (![composingBackspaceSnapshot[@"handled"] boolValue] ||
        ![composingBackspaceSnapshot[@"preedit"] isEqualToString:@"n"]) {
      return 26;
    }
    NSDictionary<NSString*, id>* finalBackspaceSnapshot = [session processKey:@"BackSpace" modifiers:@[]];
    if (![finalBackspaceSnapshot[@"handled"] boolValue] ||
        [finalBackspaceSnapshot[@"preedit"] length] != 0) {
      return 27;
    }

    NSDictionary<NSString*, id>* leadingSlashSnapshot = [session processKey:@"/" modifiers:@[]];
    NSArray<NSDictionary<NSString*, NSString*>*>* leadingSlashCandidates = leadingSlashSnapshot[@"candidates"];
    NSUInteger slashCandidateIndex = NSNotFound;
    for (NSUInteger candidateIndex = 0; candidateIndex < leadingSlashCandidates.count; ++candidateIndex) {
      if ([leadingSlashCandidates[candidateIndex][@"text"] isEqualToString:@"/"]) {
        slashCandidateIndex = candidateIndex;
        break;
      }
    }
    if (slashCandidateIndex == NSNotFound || ![leadingSlashSnapshot[@"isComposing"] boolValue]) {
      return 19;
    }
    NSDictionary<NSString*, id>* leadingSlashCommit = [session selectCandidate:slashCandidateIndex];
    if (![leadingSlashCommit[@"commitText"] isEqualToString:@"/"] ||
        [leadingSlashCommit[@"preedit"] length] != 0) {
      return 20;
    }

    [session setOption:@"full_shape" enabled:NO];
    [session setOption:@"ascii_punct" enabled:NO];
    [session processKey:@"n" modifiers:@[]];
    [session processKey:@"i" modifiers:@[]];
    [session processKey:@"h" modifiers:@[]];
    [session processKey:@"a" modifiers:@[]];
    [session processKey:@"o" modifiers:@[]];
    NSDictionary<NSString*, id>* trailingSlashSnapshot = [session processKey:@"/" modifiers:@[]];
    NSArray<NSDictionary<NSString*, NSString*>*>* trailingSlashCandidates = trailingSlashSnapshot[@"candidates"];
    NSUInteger trailingSlashCandidateIndex = NSNotFound;
    for (NSUInteger candidateIndex = 0; candidateIndex < trailingSlashCandidates.count; ++candidateIndex) {
      if ([trailingSlashCandidates[candidateIndex][@"text"] isEqualToString:@"/"]) {
        trailingSlashCandidateIndex = candidateIndex;
        break;
      }
    }
    if (trailingSlashCandidateIndex == NSNotFound) {
      return 21;
    }
    NSDictionary<NSString*, id>* trailingSlashCommit = [session selectCandidate:trailingSlashCandidateIndex];
    if (![trailingSlashSnapshot[@"isComposing"] boolValue] ||
        ![trailingSlashCommit[@"commitText"] isEqualToString:@"你好/"] ||
        [trailingSlashCommit[@"preedit"] length] != 0) {
      return 22;
    }

    NSDictionary<NSString*, id>* composingSnapshot = [session processKey:@"n" modifiers:@[]];
    if (![composingSnapshot[@"handled"] boolValue]) {
      return 6;
    }
    [session processKey:@"i" modifiers:@[]];
    [session processKey:@"h" modifiers:@[]];
    [session processKey:@"a" modifiers:@[]];
    [session processKey:@"o" modifiers:@[]];

    NSDictionary<NSString*, id>* menuSnapshot = [session currentSnapshot];
    if ([menuSnapshot[@"commitText"] length] != 0 ||
        [menuSnapshot[@"preedit"] length] == 0) {
      return 7;
    }
    NSDictionary<NSString*, id>* commitSnapshot = [session commitComposition];
    if (![commitSnapshot[@"handled"] boolValue] ||
        ![commitSnapshot[@"commitText"] isEqualToString:@"你好"]) {
      return 8;
    }
    NSDictionary<NSString*, id>* afterCommitSnapshot = [session currentSnapshot];
    if ([afterCommitSnapshot[@"commitText"] length] != 0 ||
        [afterCommitSnapshot[@"preedit"] length] != 0) {
      return 9;
    }
    NSDictionary<NSString*, id>* trailingSpaceSnapshot = [session processKey:@" " modifiers:@[]];
    if ([trailingSpaceSnapshot[@"handled"] boolValue] ||
        [trailingSpaceSnapshot[@"commitText"] length] != 0 ||
        [trailingSpaceSnapshot[@"preedit"] length] != 0) {
      return 12;
    }

    [session processKey:@"n" modifiers:@[]];
    [session processKey:@"i" modifiers:@[]];
    NSDictionary<NSString*, id>* rawReturnSnapshot = [session processKey:@"Return" modifiers:@[]];
    if (![rawReturnSnapshot[@"handled"] boolValue] ||
        ![rawReturnSnapshot[@"commitText"] isEqualToString:@"ni"] ||
        [rawReturnSnapshot[@"preedit"] length] != 0) {
      return 23;
    }

    [session processKey:@"n" modifiers:@[]];
    [session processKey:@"i" modifiers:@[]];
    [session processKey:@"h" modifiers:@[]];
    [session processKey:@"a" modifiers:@[]];
    [session processKey:@"o" modifiers:@[]];
    NSDictionary<NSString*, id>* naturalTextCommit = [session processKey:@"space" modifiers:@[]];
    NSDictionary<NSString*, id>* naturalPunctuationCommit = [session processKey:@"." modifiers:@[]];
    if (![naturalTextCommit[@"commitText"] isEqualToString:@"你好"] ||
        ![naturalPunctuationCommit[@"commitText"] isEqualToString:@"。"] ||
        [naturalPunctuationCommit[@"preedit"] length] != 0) {
      return 24;
    }

    NSDictionary<NSString*, id>* optionSnapshot = [session setOption:@"ascii_mode" enabled:YES];
    if (![optionSnapshot[@"isAsciiMode"] boolValue]) {
      return 10;
    }
    [session setOption:@"ascii_mode" enabled:NO];
    [session setOption:@"full_shape" enabled:NO];
    NSDictionary<NSString*, id>* fullShapeSnapshot = [session processKey:@"space" modifiers:@[@"Shift"]];
    if (![fullShapeSnapshot[@"handled"] boolValue] ||
        ![fullShapeSnapshot[@"isFullShape"] boolValue]) {
      return 13;
    }
    NSDictionary<NSString*, id>* halfShapeSnapshot = [session processKey:@"space" modifiers:@[@"Shift"]];
    if (![halfShapeSnapshot[@"handled"] boolValue] ||
        [halfShapeSnapshot[@"isFullShape"] boolValue]) {
      return 14;
    }
    [session setOption:@"ascii_punct" enabled:NO];
    NSDictionary<NSString*, id>* westernPunctuationSnapshot = [session processKey:@"." modifiers:@[@"Control"]];
    if (![westernPunctuationSnapshot[@"handled"] boolValue] ||
        ![westernPunctuationSnapshot[@"isAsciiPunctuation"] boolValue]) {
      return 15;
    }
    NSDictionary<NSString*, id>* chinesePunctuationSnapshot = [session processKey:@"." modifiers:@[@"Control"]];
    if (![chinesePunctuationSnapshot[@"handled"] boolValue] ||
        [chinesePunctuationSnapshot[@"isAsciiPunctuation"] boolValue]) {
      return 16;
    }
    printf("Rime bridge smoke test passed: direct text, Escape composition clear, Backspace composition editing, Return raw commit, punctuation commit, direct symbol selection, explicit commit, schema, option, Shift-Space width, and Control-Period punctuation toggles\n");
  }
  return 0;
}
