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
  traits.app_name = "rime.typing-dongnanya.smoke";
  rime->setup(&traits);
  rime->deployer_initialize(&traits);
  if (!rime->deploy_config_file("default.yaml", "config_version") ||
      !rime->prebuild()) {
    return 3;
  }
  rime->initialize(&traits);

  RimeSchemaList schema_list = {};
  if (!rime->get_schema_list(&schema_list) || schema_list.size != 1 ||
      !schema_list.list || !schema_list.list[0].schema_id ||
      std::string(schema_list.list[0].schema_id) != "luna_pinyin") {
    rime->free_schema_list(&schema_list);
    rime->finalize();
    return 4;
  }
  rime->free_schema_list(&schema_list);

  RimeSessionId session = rime->create_session();
  if (!session || !rime->select_schema(session, "luna_pinyin") ||
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

  RimeSessionId interactionSession = rime->create_session();
  if (!interactionSession || !rime->select_schema(interactionSession, "luna_pinyin") ||
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
  if (!optionSession || !rime->select_schema(optionSession, "luna_pinyin")) {
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
  if (!simplifiedSession || !rime->select_schema(simplifiedSession, "luna_pinyin") ||
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
      "Rime smoke test passed: nihao -> 你好, candidate interaction and runtime option APIs, nage -> %s\n",
      simplifiedResult.c_str());
  return 0;
}
