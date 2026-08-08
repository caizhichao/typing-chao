#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 通过 Objective-C++ 隔离 librime C++ 静态库，Swift 只接收稳定的快照结构。
@interface TDNRimeSession : NSObject

- (instancetype)initWithSharedDataDirectory:(NSString *)sharedDataDirectory
                              userDataDirectory:(NSString *)userDataDirectory;

- (NSDictionary<NSString *, id> *)processKey:(NSString *)keyName
                                  modifiers:(NSArray<NSString *> *)modifierNames;

- (NSDictionary<NSString *, id> *)currentSnapshot;

- (NSDictionary<NSString *, id> *)commitComposition;

- (NSArray<NSDictionary<NSString *, NSString *> *> *)schemaList;

- (NSDictionary<NSString *, id> *)selectSchema:(NSString *)schemaIdentifier;

- (NSDictionary<NSString *, id> *)setOption:(NSString *)optionName enabled:(BOOL)enabled;

- (NSDictionary<NSString *, id> *)selectCandidate:(NSUInteger)candidateIndex;

- (NSDictionary<NSString *, id> *)changePageBackward:(BOOL)pageBackward;

- (void)clearComposition;

@end

NS_ASSUME_NONNULL_END
