#include <cstdio>
#include <string>
#include <rime_api.h>

int main(int argc, char** argv) {
  if (argc != 3) {
    return 2;
  }

  RimeApi* rime = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.prebuilt_data_dir = argv[2];
  traits.staging_dir = argv[2];
  traits.app_name = "rime.typingchao.smoke";
  rime->setup(&traits);
  rime->deployer_initialize(&traits);
  if (!rime->deploy_config_file("default.yaml", "config_version") ||
      !rime->prebuild()) {
    return 3;
  }
  rime->initialize(&traits);

  const char* expectedSchemaList[] = {
      "typing_pinyin",
      "typing_double_pinyin_natural",
      "typing_double_pinyin_flypy",
      "typing_pinyin_t9",
      "typing_wubi86",
  };
  RimeSchemaList schema_list = {};
  if (!rime->get_schema_list(&schema_list) || schema_list.size != 5 ||
      !schema_list.list) {
    rime->free_schema_list(&schema_list);
    rime->finalize();
    return 4;
  }
  for (size_t schemaIndex = 0; schemaIndex < schema_list.size; ++schemaIndex) {
    if (!schema_list.list[schemaIndex].schema_id ||
        std::string(schema_list.list[schemaIndex].schema_id) != expectedSchemaList[schemaIndex]) {
      rime->free_schema_list(&schema_list);
      rime->finalize();
      return 4;
    }
  }
  rime->free_schema_list(&schema_list);

  RimeSessionId session = rime->create_session();
  if (!session || !rime->select_schema(session, "typing_pinyin") ||
      !rime->simulate_key_sequence(session, "nihao{space}")) {
    rime->finalize();
    return 5;
  }

  RIME_STRUCT(RimeCommit, commit);
  const bool hasCommit = rime->get_commit(session, &commit);
  const std::string result = hasCommit && commit.text ? commit.text : "";
  if (hasCommit) {
    rime->free_commit(&commit);
  }
  rime->destroy_session(session);

  if (result != "你好") {
    std::fprintf(stderr, "unexpected Rime result: %s\n", result.c_str());
    rime->finalize();
    return 6;
  }

  // 双拼方案必须使用各自的双键序列生成与全拼一致的中文提交。
  const char* doublePinyinSchemaList[] = {
      "typing_double_pinyin_natural",
      "typing_double_pinyin_flypy",
  };
  const char* doublePinyinSequenceList[] = {
      "nihk{space}",
      "nihc{space}",
  };
  for (size_t schemaIndex = 0; schemaIndex < 2; ++schemaIndex) {
    RimeSessionId doublePinyinSession = rime->create_session();
    if (!doublePinyinSession ||
        !rime->select_schema(doublePinyinSession, doublePinyinSchemaList[schemaIndex]) ||
        !rime->simulate_key_sequence(doublePinyinSession, doublePinyinSequenceList[schemaIndex])) {
      rime->finalize();
      return 16;
    }
    RIME_STRUCT(RimeCommit, doublePinyinCommit);
    const bool hasDoublePinyinCommit = rime->get_commit(doublePinyinSession, &doublePinyinCommit);
    const std::string doublePinyinResult =
        hasDoublePinyinCommit && doublePinyinCommit.text ? doublePinyinCommit.text : "";
    if (hasDoublePinyinCommit) {
      rime->free_commit(&doublePinyinCommit);
    }
    rime->destroy_session(doublePinyinSession);
    if (doublePinyinResult != "你好") {
      std::fprintf(
          stderr,
          "unexpected double pinyin result for %s: %s\n",
          doublePinyinSchemaList[schemaIndex],
          doublePinyinResult.c_str());
      rime->finalize();
      return 17;
    }
  }

  // 九键方案必须把标准 2–9 数字序列解析为与全拼一致的中文候选。
  RimeSessionId t9Session = rime->create_session();
  if (!t9Session || !rime->select_schema(t9Session, "typing_pinyin_t9") ||
      !rime->simulate_key_sequence(t9Session, "64426{space}")) {
    rime->finalize();
    return 18;
  }
  RIME_STRUCT(RimeCommit, t9Commit);
  const bool hasT9Commit = rime->get_commit(t9Session, &t9Commit);
  const std::string t9Result = hasT9Commit && t9Commit.text ? t9Commit.text : "";
  if (hasT9Commit) {
    rime->free_commit(&t9Commit);
  }
  rime->destroy_session(t9Session);
  if (t9Result != "你好") {
    std::fprintf(stderr, "unexpected T9 result: %s\n", t9Result.c_str());
    rime->finalize();
    return 19;
  }

  // 五笔方案必须使用锁定码表的标准词组编码提交完整文本。
  RimeSessionId wubiSession = rime->create_session();
  if (!wubiSession || !rime->select_schema(wubiSession, "typing_wubi86") ||
      !rime->simulate_key_sequence(wubiSession, "wqvb{space}")) {
    rime->finalize();
    return 20;
  }
  RIME_STRUCT(RimeCommit, wubiCommit);
  const bool hasWubiCommit = rime->get_commit(wubiSession, &wubiCommit);
  const std::string wubiResult = hasWubiCommit && wubiCommit.text ? wubiCommit.text : "";
  if (hasWubiCommit) {
    rime->free_commit(&wubiCommit);
  }
  rime->destroy_session(wubiSession);
  if (wubiResult != "你好") {
    std::fprintf(stderr, "unexpected Wubi result: %s\n", wubiResult.c_str());
    rime->finalize();
    return 21;
  }

  RimeSessionId interactionSession = rime->create_session();
  if (!interactionSession || !rime->select_schema(interactionSession, "typing_pinyin") ||
      !rime->simulate_key_sequence(interactionSession, "nihao")) {
    rime->finalize();
    return 7;
  }
  RIME_STRUCT(RimeContext, interactionContext);
  if (!rime->get_context(interactionSession, &interactionContext) ||
      interactionContext.composition.preedit == nullptr ||
      interactionContext.menu.num_candidates <= 0 ||
      interactionContext.menu.page_no != 0) {
    rime->destroy_session(interactionSession);
    rime->finalize();
    return 8;
  }
  const bool canHighlightSecond = interactionContext.menu.num_candidates > 1;
  const bool canPageForward = !interactionContext.menu.is_last_page;
  rime->free_context(&interactionContext);

  rime->set_caret_pos(interactionSession, 2);
  if (rime->get_caret_pos(interactionSession) != 2) {
    rime->destroy_session(interactionSession);
    rime->finalize();
    return 9;
  }
  if (canHighlightSecond &&
      !rime->highlight_candidate_on_current_page(interactionSession, 1)) {
    rime->destroy_session(interactionSession);
    rime->finalize();
    return 10;
  }
  if (canPageForward) {
    if (!rime->change_page(interactionSession, false) ||
        !rime->change_page(interactionSession, true)) {
      rime->destroy_session(interactionSession);
      rime->finalize();
      return 11;
    }
  }
  rime->destroy_session(interactionSession);

  RimeSessionId optionSession = rime->create_session();
  if (!optionSession || !rime->select_schema(optionSession, "typing_pinyin")) {
    rime->finalize();
    return 12;
  }
  rime->set_option(optionSession, "ascii_mode", True);
  rime->set_option(optionSession, "full_shape", True);
  rime->set_option(optionSession, "ascii_punct", True);
  rime->set_option(optionSession, "zh_hans", True);
  RIME_STRUCT(RimeStatus, optionStatus);
  const bool hasExpectedOptions =
      rime->get_option(optionSession, "ascii_mode") &&
      rime->get_option(optionSession, "full_shape") &&
      rime->get_option(optionSession, "ascii_punct") &&
      rime->get_option(optionSession, "zh_hans") &&
      rime->get_status(optionSession, &optionStatus) &&
      optionStatus.is_ascii_mode == True &&
      optionStatus.is_full_shape == True &&
      optionStatus.is_ascii_punct == True;
  if (optionStatus.data_size > 0) {
    rime->free_status(&optionStatus);
  }
  rime->destroy_session(optionSession);
  if (!hasExpectedOptions) {
    rime->finalize();
    return 13;
  }

  RimeSessionId simplifiedSession = rime->create_session();
  if (!simplifiedSession || !rime->select_schema(simplifiedSession, "typing_pinyin") ||
      !rime->simulate_key_sequence(simplifiedSession, "nage{space}")) {
    rime->finalize();
    return 14;
  }
  RIME_STRUCT(RimeCommit, simplifiedCommit);
  const bool hasSimplifiedCommit = rime->get_commit(simplifiedSession, &simplifiedCommit);
  const std::string simplifiedResult = hasSimplifiedCommit && simplifiedCommit.text ? simplifiedCommit.text : "";
  if (hasSimplifiedCommit) {
    rime->free_commit(&simplifiedCommit);
  }
  rime->destroy_session(simplifiedSession);
  rime->finalize();

  if (simplifiedResult.find("個") != std::string::npos) {
    std::fprintf(stderr, "unexpected traditional Rime result: %s\n", simplifiedResult.c_str());
    return 15;
  }
  std::printf(
      "Rime smoke test passed: full pinyin, two double pinyin schemas, T9 and Wubi -> 你好; candidate interaction and runtime option APIs, nage -> %s\n",
      simplifiedResult.c_str());
  return 0;
}
