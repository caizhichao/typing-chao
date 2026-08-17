#import "RimeBridge.h"

#include <rime_api.h>
#include <rime/key_table.h>

#include <filesystem>
#include <fstream>
#include <iterator>
#include <mutex>
#include <string>
#include <cstring>

namespace {

RimeApi* g_rime = nullptr;
std::once_flag g_rime_once;
std::string g_shared_data_directory;
std::string g_user_data_directory;
std::string g_app_name = "rime.typingchao";

void initializeRime(const std::string& sharedDataDirectory,
                    const std::string& userDataDirectory) {
  g_shared_data_directory = sharedDataDirectory;
  g_user_data_directory = userDataDirectory;
  std::filesystem::create_directories(g_user_data_directory);

  g_rime = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = g_shared_data_directory.c_str();
  traits.user_data_dir = g_user_data_directory.c_str();
  traits.app_name = g_app_name.c_str();
  traits.log_dir = g_user_data_directory.c_str();
  traits.prebuilt_data_dir = g_user_data_directory.c_str();
  traits.staging_dir = g_user_data_directory.c_str();
  g_rime->setup(&traits);

  // 仅在首次安装或本项目 Rime 数据版本变化时重新部署，不触碰其他输入法的数据目录。
  const auto userDataPath = std::filesystem::path(g_user_data_directory);
  const auto sharedDataPath = std::filesystem::path(g_shared_data_directory);
  const auto tablePath = userDataPath / "typing_pinyin.table.bin";
  const auto defaultConfigPath = userDataPath / "default.yaml";
  const auto sharedVersionPath = sharedDataPath / "rime-data-version.txt";
  const auto userVersionPath = userDataPath / "rime-data-version.txt";
  auto readText = [](const std::filesystem::path& path) {
    std::ifstream stream(path);
    return std::string(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>());
  };
  const bool needsDeploy = !std::filesystem::exists(tablePath) ||
                           !std::filesystem::exists(defaultConfigPath) ||
                           !std::filesystem::exists(sharedVersionPath) ||
                           readText(sharedVersionPath) != readText(userVersionPath);
  if (needsDeploy) {
    // 数据升级时只覆盖项目随包分发的配置，让 Rime 用新版 schema 重建缓存，同时保留用户词频和 custom patch。
    for (const auto& sharedEntry : std::filesystem::directory_iterator(sharedDataPath)) {
      if (!sharedEntry.is_regular_file()) {
        continue;
      }
      const auto sourcePath = sharedEntry.path();
      const auto fileName = sourcePath.filename();
      const bool isSchemaConfig = sourcePath.extension() == ".yaml" &&
          sourcePath.stem().extension() == ".schema";
      if (fileName != "default.yaml" && !isSchemaConfig) {
        continue;
      }
      std::filesystem::copy_file(
          sourcePath, userDataPath / fileName,
          std::filesystem::copy_options::overwrite_existing);
    }
    g_rime->deployer_initialize(&traits);
    if (!g_rime->deploy_config_file("default.yaml", "config_version") ||
        !g_rime->prebuild()) {
      NSLog(@"TypingChao failed to prepare Rime data.");
    } else if (std::filesystem::exists(sharedVersionPath)) {
      std::filesystem::copy_file(
          sharedVersionPath, userVersionPath,
          std::filesystem::copy_options::overwrite_existing);
    }
  }
  g_rime->initialize(&traits);
}

NSString* stringFromUTF8(const char* value) {
  if (!value) {
    return @"";
  }
  return [NSString stringWithUTF8String:value] ?: @"";
}

NSDictionary<NSString*, id>* snapshotForSession(RimeSessionId sessionId,
                                                  BOOL includesCommitText) {
  NSMutableArray<NSDictionary<NSString*, NSString*>*>* candidates =
      [NSMutableArray array];
  NSString* preedit = @"";
  NSString* preview = @"";
  NSInteger highlightedIndex = -1;
  NSInteger selectionStart = 0;
  NSInteger selectionEnd = 0;
  NSInteger caretPosition = 0;
  NSInteger pageSize = 0;
  NSInteger pageNumber = 0;
  BOOL isLastPage = YES;

  RIME_STRUCT(RimeContext, context);
  if (g_rime->get_context(sessionId, &context)) {
    preedit = stringFromUTF8(context.composition.preedit);
    preview = stringFromUTF8(context.commit_text_preview);
    selectionStart = context.composition.sel_start;
    selectionEnd = context.composition.sel_end;
    caretPosition = context.composition.cursor_pos;
    pageSize = context.menu.page_size;
    pageNumber = context.menu.page_no;
    isLastPage = context.menu.is_last_page == True;
    highlightedIndex = context.menu.highlighted_candidate_index;
    for (int i = 0; i < context.menu.num_candidates; ++i) {
      RimeCandidate& candidate = context.menu.candidates[i];
      NSString* candidateLabel = @"";
      if (RIME_STRUCT_HAS_MEMBER(context, context.select_labels) &&
          context.select_labels && context.select_labels[i]) {
        candidateLabel = stringFromUTF8(context.select_labels[i]);
      } else if (context.menu.select_keys &&
                 i < static_cast<int>(std::strlen(context.menu.select_keys))) {
        candidateLabel = [NSString stringWithFormat:@"%c", context.menu.select_keys[i]];
      }
      [candidates addObject:@{
        @"text": stringFromUTF8(candidate.text),
        @"comment": stringFromUTF8(candidate.comment),
        @"label": candidateLabel,
      }];
    }
    g_rime->free_context(&context);
  }

  NSString* schemaIdentifier = @"";
  NSString* schemaName = @"";
  BOOL isDisabled = NO;
  BOOL isAsciiMode = NO;
  BOOL isFullShape = NO;
  BOOL isSimplified = YES;
  BOOL isAsciiPunctuation = NO;
  BOOL isSimplifiedChinese = NO;
  RIME_STRUCT(RimeStatus, status);
  if (g_rime->get_status(sessionId, &status)) {
    schemaIdentifier = stringFromUTF8(status.schema_id);
    schemaName = stringFromUTF8(status.schema_name);
    isDisabled = status.is_disabled == True;
    isAsciiMode = status.is_ascii_mode == True;
    isFullShape = status.is_full_shape == True;
    isSimplified = status.is_simplified == True;
    isAsciiPunctuation = status.is_ascii_punct == True;
    g_rime->free_status(&status);
  }
  if (g_rime) {
    isSimplifiedChinese = g_rime->get_option(sessionId, "zh_hans") == True;
  }

  NSString* commitText = @"";
  if (includesCommitText) {
    RIME_STRUCT(RimeCommit, commit);
    if (g_rime->get_commit(sessionId, &commit)) {
      commitText = stringFromUTF8(commit.text);
      g_rime->free_commit(&commit);
    }
  }

  return @{
    @"preedit": preedit,
    @"commitText": commitText,
    @"commitPreview": preview,
    @"candidates": candidates,
    @"highlightedIndex": @(highlightedIndex),
    @"selectionStart": @(selectionStart),
    @"selectionEnd": @(selectionEnd),
    @"caretPosition": @(caretPosition),
    @"pageSize": @(pageSize),
    @"pageNumber": @(pageNumber),
    @"isLastPage": @(isLastPage),
    @"schemaIdentifier": schemaIdentifier,
    @"schemaName": schemaName,
    @"isDisabled": @(isDisabled),
    @"isAsciiMode": @(isAsciiMode),
    @"isFullShape": @(isFullShape),
    @"isSimplified": @(isSimplified),
    @"isAsciiPunctuation": @(isAsciiPunctuation),
    @"isSimplifiedChinese": @(isSimplifiedChinese),
    @"isComposing": @(preedit.length > 0),
  };
}

// 只有可能提交文本的动作才读取 commit；状态动作不得为获取快照而消费 librime 的待提交文本。
NSDictionary<NSString*, id>* snapshotAfterAction(RimeSessionId sessionId,
                                                  Bool handled,
                                                  BOOL includesCommitText) {
  NSMutableDictionary<NSString*, id>* snapshot =
      [snapshotForSession(sessionId, includesCommitText) mutableCopy];
  snapshot[@"handled"] = @(handled == True);
  return snapshot;
}

}  // namespace

@implementation TDNRimeSession {
  RimeSessionId _sessionId;
}

- (instancetype)initWithSharedDataDirectory:(NSString *)sharedDataDirectory
                              userDataDirectory:(NSString *)userDataDirectory {
  self = [super init];
  if (!self) {
    return nil;
  }

  std::call_once(g_rime_once, [&] {
    initializeRime(sharedDataDirectory.UTF8String ?: "",
                   userDataDirectory.UTF8String ?: "");
  });

  _sessionId = g_rime->create_session();
  if (!_sessionId) {
    return nil;
  }
  g_rime->select_schema(_sessionId, "typing_pinyin");
  return self;
}

- (void)dealloc {
  if (_sessionId && g_rime) {
    g_rime->destroy_session(_sessionId);
  }
}

// 仅向 librime 传递它定义的 ASCII 按键或命名功能键，直接文本交回宿主处理。
- (NSDictionary<NSString *, id> *)processKey:(NSString *)keyName
                                  modifiers:(NSArray<NSString *> *)modifierNames {
  if (!g_rime || !_sessionId) {
    return @{
      @"preedit": @"",
      @"commitText": @"",
      @"commitPreview": @"",
      @"candidates": @[],
      @"highlightedIndex": @(-1),
      @"selectionStart": @(0),
      @"selectionEnd": @(0),
      @"caretPosition": @(0),
      @"pageSize": @(0),
      @"pageNumber": @(0),
      @"isLastPage": @YES,
      @"schemaIdentifier": @"",
      @"schemaName": @"",
      @"isDisabled": @NO,
      @"isAsciiMode": @NO,
      @"isFullShape": @NO,
      @"isSimplified": @YES,
      @"isAsciiPunctuation": @NO,
      @"isSimplifiedChinese": @YES,
      @"isComposing": @NO,
    };
  }

  int keyCode = 0;
  if (keyName.length == 1 && [keyName canBeConvertedToEncoding:NSASCIIStringEncoding]) {
    const char* keyCharacters = [keyName cStringUsingEncoding:NSASCIIStringEncoding];
    if (keyCharacters) {
      keyCode = keyCharacters[0];
    }
  } else {
    keyCode = RimeGetKeycodeByName(keyName.UTF8String);
  }
  if (keyCode == 0) {
    return snapshotAfterAction(_sessionId, False, NO);
  }

  int modifiers = 0;
  for (NSString* modifierName in modifierNames) {
    modifiers |= RimeGetModifierByName(modifierName.UTF8String);
  }
  const Bool handled = g_rime->process_key(_sessionId, keyCode, modifiers);
  return snapshotAfterAction(_sessionId, handled, YES);
}

- (NSDictionary<NSString *, id> *)currentSnapshot {
  if (!g_rime || !_sessionId) {
    return @{};
  }
  return snapshotForSession(_sessionId, NO);
}

- (NSDictionary<NSString *, id> *)commitComposition {
  if (!g_rime || !_sessionId) {
    return @{};
  }
  return snapshotAfterAction(
      _sessionId,
      g_rime->commit_composition(_sessionId),
      YES);
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)schemaList {
  if (!g_rime) {
    return @[];
  }
  RimeSchemaList schemaList = {};
  if (!g_rime->get_schema_list(&schemaList)) {
    return @[];
  }
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *result =
      [NSMutableArray arrayWithCapacity:schemaList.size];
  for (size_t index = 0; index < schemaList.size; ++index) {
    const RimeSchemaListItem& schema = schemaList.list[index];
    [result addObject:@{
      @"identifier": stringFromUTF8(schema.schema_id),
      @"name": stringFromUTF8(schema.name),
    }];
  }
  g_rime->free_schema_list(&schemaList);
  return result;
}

- (NSDictionary<NSString *, id> *)selectSchema:(NSString *)schemaIdentifier {
  if (!g_rime || !_sessionId || schemaIdentifier.length == 0) {
    return @{};
  }
  return snapshotAfterAction(
      _sessionId,
      g_rime->select_schema(_sessionId, schemaIdentifier.UTF8String),
      NO);
}

- (NSDictionary<NSString *, id> *)setOption:(NSString *)optionName enabled:(BOOL)enabled {
  if (!g_rime || !_sessionId || optionName.length == 0) {
    return @{};
  }
  g_rime->set_option(_sessionId, optionName.UTF8String, enabled ? True : False);
  return snapshotAfterAction(_sessionId, True, NO);
}

- (NSDictionary<NSString *, id> *)selectCandidate:(NSUInteger)candidateIndex {
  if (!g_rime || !_sessionId) {
    return @{};
  }
  return snapshotAfterAction(
      _sessionId,
      g_rime->select_candidate_on_current_page(_sessionId, candidateIndex),
      YES);
}

- (NSDictionary<NSString *, id> *)changePageBackward:(BOOL)pageBackward {
  if (!g_rime || !_sessionId) {
    return @{};
  }
  return snapshotAfterAction(
      _sessionId,
      g_rime->change_page(_sessionId, pageBackward ? True : False),
      NO);
}

- (void)clearComposition {
  if (g_rime && _sessionId) {
    g_rime->clear_composition(_sessionId);
  }
}

@end
