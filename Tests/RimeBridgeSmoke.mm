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

    NSDictionary<NSString*, id>* optionSnapshot = [session setOption:@"ascii_mode" enabled:YES];
    if (![optionSnapshot[@"isAsciiMode"] boolValue]) {
      return 10;
    }
    printf("Rime bridge smoke test passed: direct text and trailing space pass-through, non-consuming state snapshot, explicit commit, schema, and option\n");
  }
  return 0;
}
