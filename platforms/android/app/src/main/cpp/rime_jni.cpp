#include <jni.h>
#include <android/log.h>

#include <rime_api.h>
#include <rime/key_table.h>

#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <mutex>
#include <string>

namespace {

constexpr const char* kLogTag = "TypingDongnanyaRime";
constexpr const char* kApplicationName = "rime.typing-dongnanya.android";

RimeApi* g_rime = nullptr;
std::mutex g_rime_mutex;
bool g_initialized = false;
std::string g_shared_data_directory;
std::string g_user_data_directory;

jclass g_snapshot_class = nullptr;
jmethodID g_snapshot_constructor = nullptr;
jfieldID g_snapshot_preedit_field = nullptr;
jfieldID g_snapshot_commit_field = nullptr;
jfieldID g_snapshot_schema_identifier_field = nullptr;
jfieldID g_snapshot_schema_name_field = nullptr;
jfieldID g_snapshot_handled_field = nullptr;
jfieldID g_snapshot_candidates_field = nullptr;
jfieldID g_snapshot_highlighted_field = nullptr;
jfieldID g_snapshot_page_number_field = nullptr;
jfieldID g_snapshot_last_page_field = nullptr;
jfieldID g_snapshot_composing_field = nullptr;
jfieldID g_snapshot_ascii_mode_field = nullptr;
jfieldID g_snapshot_full_shape_field = nullptr;
jfieldID g_snapshot_ascii_punctuation_field = nullptr;
jfieldID g_snapshot_simplified_field = nullptr;

jclass g_candidate_class = nullptr;
jmethodID g_candidate_constructor = nullptr;
jfieldID g_candidate_text_field = nullptr;
jfieldID g_candidate_comment_field = nullptr;
jfieldID g_candidate_label_field = nullptr;

void logError(const std::string& message) {
  __android_log_print(ANDROID_LOG_ERROR, kLogTag, "%s", message.c_str());
}

std::string utf8String(JNIEnv* environment, jstring javaString) {
  if (!javaString) {
    return {};
  }
  const char* characters = environment->GetStringUTFChars(javaString, nullptr);
  if (!characters) {
    return {};
  }
  std::string result(characters);
  environment->ReleaseStringUTFChars(javaString, characters);
  return result;
}

jstring javaString(JNIEnv* environment, const char* textValue) {
  if (!textValue) {
    return environment->NewStringUTF("");
  }
  return environment->NewStringUTF(textValue);
}

bool readFile(const std::filesystem::path& filePath, std::string* textValue) {
  std::ifstream inputStream(filePath, std::ios::binary);
  if (!inputStream) {
    return false;
  }
  *textValue = std::string(
      std::istreambuf_iterator<char>(inputStream),
      std::istreambuf_iterator<char>());
  return true;
}

// 共享数据版本变化时才重新部署，用户词典目录不会随 APK 更新被删除。
bool prepareRimeData(RimeTraits& traits) {
  const std::filesystem::path sharedRoot(g_shared_data_directory);
  const std::filesystem::path userRoot(g_user_data_directory);
  const std::filesystem::path tablePath = userRoot / "typing_pinyin.table.bin";
  const std::filesystem::path defaultConfigPath = userRoot / "default.yaml";
  const std::filesystem::path sharedVersionPath = sharedRoot / "rime-data-version.txt";
  const std::filesystem::path userVersionPath = userRoot / "rime-data-version.txt";
  std::string sharedVersion;
  std::string userVersion;
  const bool hasSharedVersion = readFile(sharedVersionPath, &sharedVersion);
  const bool hasUserVersion = readFile(userVersionPath, &userVersion);
  const bool needsDeployment = !std::filesystem::exists(tablePath) ||
      !std::filesystem::exists(defaultConfigPath) ||
      !hasSharedVersion ||
      !hasUserVersion ||
      sharedVersion != userVersion;
  if (!needsDeployment) {
    return true;
  }
  g_rime->deployer_initialize(&traits);
  if (!g_rime->deploy_config_file("default.yaml", "config_version") ||
      !g_rime->prebuild()) {
    logError("Failed to deploy Rime data");
    return false;
  }
  if (hasSharedVersion) {
    std::filesystem::copy_file(
        sharedVersionPath,
        userVersionPath,
        std::filesystem::copy_options::overwrite_existing);
  }
  return true;
}

jobject newCandidate(
    JNIEnv* environment,
    const char* textValue,
    const char* commentText,
    const char* labelText) {
  jobject candidateObject = environment->NewObject(g_candidate_class, g_candidate_constructor);
  jstring textString = javaString(environment, textValue);
  jstring commentString = javaString(environment, commentText);
  jstring labelString = javaString(environment, labelText);
  environment->SetObjectField(candidateObject, g_candidate_text_field, textString);
  environment->SetObjectField(candidateObject, g_candidate_comment_field, commentString);
  environment->SetObjectField(candidateObject, g_candidate_label_field, labelString);
  environment->DeleteLocalRef(textString);
  environment->DeleteLocalRef(commentString);
  environment->DeleteLocalRef(labelString);
  return candidateObject;
}

// 候选、组合、页码、运行选项和本次 commit 使用同一快照返回，前端不再二次查询消费状态。
jobject snapshotForSession(
    JNIEnv* environment,
    RimeSessionId sessionIdentifier,
    bool handledValue,
    bool includesCommitText) {
  jobject snapshotObject = environment->NewObject(g_snapshot_class, g_snapshot_constructor);
  std::string preeditText;
  std::string commitText;
  int highlightedIndex = -1;
  int pageNumber = 0;
  bool lastPageValue = true;
  bool composingValue = false;
  jobjectArray candidateArray = environment->NewObjectArray(0, g_candidate_class, nullptr);

  RimeContext context{};
  RIME_STRUCT_INIT(RimeContext, context);
  if (g_rime && sessionIdentifier && g_rime->get_context(sessionIdentifier, &context)) {
    if (context.composition.preedit) {
      preeditText = context.composition.preedit;
    }
    highlightedIndex = context.menu.highlighted_candidate_index;
    pageNumber = context.menu.page_no;
    lastPageValue = context.menu.is_last_page == True;
    composingValue = context.composition.length > 0;
    environment->DeleteLocalRef(candidateArray);
    candidateArray = environment->NewObjectArray(
        context.menu.num_candidates,
        g_candidate_class,
        nullptr);
    for (int candidateIndex = 0; candidateIndex < context.menu.num_candidates; ++candidateIndex) {
      RimeCandidate& candidateValue = context.menu.candidates[candidateIndex];
      const char* labelText = "";
      char fallbackLabel[2] = {0, 0};
      if (RIME_STRUCT_HAS_MEMBER(context, context.select_labels) &&
          context.select_labels &&
          context.select_labels[candidateIndex]) {
        labelText = context.select_labels[candidateIndex];
      } else if (context.menu.select_keys &&
                 candidateIndex < static_cast<int>(std::strlen(context.menu.select_keys))) {
        fallbackLabel[0] = context.menu.select_keys[candidateIndex];
        labelText = fallbackLabel;
      }
      jobject candidateObject = newCandidate(
          environment,
          candidateValue.text,
          candidateValue.comment,
          labelText);
      environment->SetObjectArrayElement(candidateArray, candidateIndex, candidateObject);
      environment->DeleteLocalRef(candidateObject);
    }
    g_rime->free_context(&context);
  }

  if (includesCommitText) {
    RimeCommit commit{};
    RIME_STRUCT_INIT(RimeCommit, commit);
    if (g_rime && sessionIdentifier && g_rime->get_commit(sessionIdentifier, &commit)) {
      if (commit.text) {
        commitText = commit.text;
      }
      g_rime->free_commit(&commit);
    }
  }

  std::string schemaIdentifier;
  std::string schemaName;
  RimeStatus status{};
  RIME_STRUCT_INIT(RimeStatus, status);
  if (g_rime && sessionIdentifier && g_rime->get_status(sessionIdentifier, &status)) {
    if (status.schema_id) {
      schemaIdentifier = status.schema_id;
    }
    if (status.schema_name) {
      schemaName = status.schema_name;
    }
    g_rime->free_status(&status);
  }

  const bool asciiModeValue = g_rime && sessionIdentifier &&
      g_rime->get_option(sessionIdentifier, "ascii_mode") == True;
  const bool fullShapeValue = g_rime && sessionIdentifier &&
      g_rime->get_option(sessionIdentifier, "full_shape") == True;
  const bool asciiPunctuationValue = g_rime && sessionIdentifier &&
      g_rime->get_option(sessionIdentifier, "ascii_punct") == True;
  const bool simplifiedValue = g_rime && sessionIdentifier &&
      g_rime->get_option(sessionIdentifier, "zh_hans") == True;

  jstring preeditString = javaString(environment, preeditText.c_str());
  jstring commitString = javaString(environment, commitText.c_str());
  jstring schemaIdentifierString = javaString(environment, schemaIdentifier.c_str());
  jstring schemaNameString = javaString(environment, schemaName.c_str());
  environment->SetObjectField(snapshotObject, g_snapshot_preedit_field, preeditString);
  environment->SetObjectField(snapshotObject, g_snapshot_commit_field, commitString);
  environment->SetObjectField(snapshotObject, g_snapshot_schema_identifier_field, schemaIdentifierString);
  environment->SetObjectField(snapshotObject, g_snapshot_schema_name_field, schemaNameString);
  environment->SetBooleanField(snapshotObject, g_snapshot_handled_field, handledValue);
  environment->SetObjectField(snapshotObject, g_snapshot_candidates_field, candidateArray);
  environment->SetIntField(snapshotObject, g_snapshot_highlighted_field, highlightedIndex);
  environment->SetIntField(snapshotObject, g_snapshot_page_number_field, pageNumber);
  environment->SetBooleanField(snapshotObject, g_snapshot_last_page_field, lastPageValue);
  environment->SetBooleanField(snapshotObject, g_snapshot_composing_field, composingValue);
  environment->SetBooleanField(snapshotObject, g_snapshot_ascii_mode_field, asciiModeValue);
  environment->SetBooleanField(snapshotObject, g_snapshot_full_shape_field, fullShapeValue);
  environment->SetBooleanField(snapshotObject, g_snapshot_ascii_punctuation_field, asciiPunctuationValue);
  environment->SetBooleanField(snapshotObject, g_snapshot_simplified_field, simplifiedValue);
  environment->DeleteLocalRef(preeditString);
  environment->DeleteLocalRef(commitString);
  environment->DeleteLocalRef(schemaIdentifierString);
  environment->DeleteLocalRef(schemaNameString);
  environment->DeleteLocalRef(candidateArray);
  return snapshotObject;
}

bool cacheJavaTypes(JNIEnv* environment) {
  jclass snapshotLocalClass = environment->FindClass(
      "com/caizhichao/typingdongnanya/rime/RimeSnapshot");
  jclass candidateLocalClass = environment->FindClass(
      "com/caizhichao/typingdongnanya/rime/RimeCandidate");
  if (!snapshotLocalClass || !candidateLocalClass) {
    return false;
  }
  g_snapshot_class = static_cast<jclass>(environment->NewGlobalRef(snapshotLocalClass));
  g_candidate_class = static_cast<jclass>(environment->NewGlobalRef(candidateLocalClass));
  environment->DeleteLocalRef(snapshotLocalClass);
  environment->DeleteLocalRef(candidateLocalClass);
  if (!g_snapshot_class || !g_candidate_class) {
    return false;
  }

  g_snapshot_constructor = environment->GetMethodID(g_snapshot_class, "<init>", "()V");
  g_snapshot_preedit_field = environment->GetFieldID(g_snapshot_class, "preeditText", "Ljava/lang/String;");
  g_snapshot_commit_field = environment->GetFieldID(g_snapshot_class, "commitText", "Ljava/lang/String;");
  g_snapshot_schema_identifier_field = environment->GetFieldID(g_snapshot_class, "schemaIdentifier", "Ljava/lang/String;");
  g_snapshot_schema_name_field = environment->GetFieldID(g_snapshot_class, "schemaName", "Ljava/lang/String;");
  g_snapshot_handled_field = environment->GetFieldID(g_snapshot_class, "wasHandled", "Z");
  g_snapshot_candidates_field = environment->GetFieldID(
      g_snapshot_class,
      "candidateList",
      "[Lcom/caizhichao/typingdongnanya/rime/RimeCandidate;");
  g_snapshot_highlighted_field = environment->GetFieldID(g_snapshot_class, "highlightedIndex", "I");
  g_snapshot_page_number_field = environment->GetFieldID(g_snapshot_class, "pageNumber", "I");
  g_snapshot_last_page_field = environment->GetFieldID(g_snapshot_class, "isLastPage", "Z");
  g_snapshot_composing_field = environment->GetFieldID(g_snapshot_class, "isComposing", "Z");
  g_snapshot_ascii_mode_field = environment->GetFieldID(g_snapshot_class, "isAsciiMode", "Z");
  g_snapshot_full_shape_field = environment->GetFieldID(g_snapshot_class, "isFullShape", "Z");
  g_snapshot_ascii_punctuation_field = environment->GetFieldID(g_snapshot_class, "isAsciiPunctuation", "Z");
  g_snapshot_simplified_field = environment->GetFieldID(g_snapshot_class, "isSimplifiedChinese", "Z");

  g_candidate_constructor = environment->GetMethodID(g_candidate_class, "<init>", "()V");
  g_candidate_text_field = environment->GetFieldID(g_candidate_class, "textValue", "Ljava/lang/String;");
  g_candidate_comment_field = environment->GetFieldID(g_candidate_class, "commentText", "Ljava/lang/String;");
  g_candidate_label_field = environment->GetFieldID(g_candidate_class, "labelText", "Ljava/lang/String;");
  return !environment->ExceptionCheck();
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* javaVirtualMachine, void*) {
  JNIEnv* environment = nullptr;
  if (javaVirtualMachine->GetEnv(
          reinterpret_cast<void**>(&environment),
          JNI_VERSION_1_6) != JNI_OK ||
      !cacheJavaTypes(environment)) {
    return JNI_ERR;
  }
  return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_caizhichao_typingdongnanya_rime_RimeNative_initialize(
    JNIEnv* environment,
    jobject,
    jstring sharedDataDirectory,
    jstring userDataDirectory) {
  std::lock_guard<std::mutex> lock(g_rime_mutex);
  if (g_initialized) {
    return JNI_TRUE;
  }
  try {
    g_shared_data_directory = utf8String(environment, sharedDataDirectory);
    g_user_data_directory = utf8String(environment, userDataDirectory);
    if (g_shared_data_directory.empty() || g_user_data_directory.empty()) {
      return JNI_FALSE;
    }
    std::filesystem::create_directories(g_user_data_directory);
    g_rime = rime_get_api();
    if (!g_rime) {
      return JNI_FALSE;
    }
    RimeTraits traits{};
    RIME_STRUCT_INIT(RimeTraits, traits);
    traits.shared_data_dir = g_shared_data_directory.c_str();
    traits.user_data_dir = g_user_data_directory.c_str();
    traits.prebuilt_data_dir = g_user_data_directory.c_str();
    traits.staging_dir = g_user_data_directory.c_str();
    traits.log_dir = g_user_data_directory.c_str();
    traits.app_name = kApplicationName;
    g_rime->setup(&traits);
    if (!prepareRimeData(traits)) {
      return JNI_FALSE;
    }
    g_rime->initialize(&traits);
    g_initialized = true;
    return JNI_TRUE;
  } catch (const std::exception& errorValue) {
    logError(errorValue.what());
    return JNI_FALSE;
  }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_caizhichao_typingdongnanya_rime_RimeNative_createSession(
    JNIEnv*,
    jobject) {
  std::lock_guard<std::mutex> lock(g_rime_mutex);
  if (!g_initialized || !g_rime) {
    return 0;
  }
  const RimeSessionId sessionIdentifier = g_rime->create_session();
  if (sessionIdentifier) {
    g_rime->select_schema(sessionIdentifier, "typing_pinyin");
    g_rime->set_option(sessionIdentifier, "zh_hans", True);
  }
  return static_cast<jlong>(sessionIdentifier);
}

extern "C" JNIEXPORT void JNICALL
Java_com_caizhichao_typingdongnanya_rime_RimeNative_destroySession(
    JNIEnv*,
    jobject,
    jlong sessionIdentifier) {
  std::lock_guard<std::mutex> lock(g_rime_mutex);
  if (g_rime && sessionIdentifier != 0) {
    g_rime->destroy_session(static_cast<RimeSessionId>(sessionIdentifier));
  }
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_caizhichao_typingdongnanya_rime_RimeNative_currentSnapshot(
    JNIEnv* environment,
    jobject,
    jlong sessionIdentifier) {
  std::lock_guard<std::mutex> lock(g_rime_mutex);
  return snapshotForSession(
      environment,
      static_cast<RimeSessionId>(sessionIdentifier),
      true,
      false);
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_caizhichao_typingdongnanya_rime_RimeNative_selectSchema(
    JNIEnv* environment,
    jobject,
    jlong sessionIdentifier,
    jstring schemaIdentifier) {
  std::lock_guard<std::mutex> lock(g_rime_mutex);
  Bool selectedValue = False;
  if (g_rime && sessionIdentifier != 0) {
    const std::string schemaIdentifierText = utf8String(environment, schemaIdentifier);
    if (!schemaIdentifierText.empty()) {
      selectedValue = g_rime->select_schema(
          static_cast<RimeSessionId>(sessionIdentifier),
          schemaIdentifierText.c_str());
    }
  }
  return snapshotForSession(
      environment,
      static_cast<RimeSessionId>(sessionIdentifier),
      selectedValue == True,
      false);
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_caizhichao_typingdongnanya_rime_RimeNative_processKey(
    JNIEnv* environment,
    jobject,
    jlong sessionIdentifier,
    jstring keyName) {
  std::lock_guard<std::mutex> lock(g_rime_mutex);
  const std::string keyText = utf8String(environment, keyName);
  int keyCode = 0;
  if (keyText.size() == 1 && static_cast<unsigned char>(keyText[0]) <= 0x7f) {
    keyCode = static_cast<unsigned char>(keyText[0]);
  } else {
    keyCode = RimeGetKeycodeByName(keyText.c_str());
  }
  Bool handledValue = False;
  if (g_rime && sessionIdentifier != 0 && keyCode != 0) {
    handledValue = g_rime->process_key(
        static_cast<RimeSessionId>(sessionIdentifier), keyCode, 0);
  }
  return snapshotForSession(
      environment,
      static_cast<RimeSessionId>(sessionIdentifier),
      handledValue == True,
      true);
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_caizhichao_typingdongnanya_rime_RimeNative_selectCandidate(
    JNIEnv* environment,
    jobject,
    jlong sessionIdentifier,
    jint candidateIndex) {
  std::lock_guard<std::mutex> lock(g_rime_mutex);
  Bool handledValue = False;
  if (g_rime && sessionIdentifier != 0 && candidateIndex >= 0) {
    handledValue = g_rime->select_candidate_on_current_page(
        static_cast<RimeSessionId>(sessionIdentifier),
        static_cast<size_t>(candidateIndex));
  }
  return snapshotForSession(
      environment,
      static_cast<RimeSessionId>(sessionIdentifier),
      handledValue == True,
      true);
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_caizhichao_typingdongnanya_rime_RimeNative_changePage(
    JNIEnv* environment,
    jobject,
    jlong sessionIdentifier,
    jboolean pageBackward) {
  std::lock_guard<std::mutex> lock(g_rime_mutex);
  Bool handledValue = False;
  Bool pageBackwardValue = False;
  if (pageBackward == JNI_TRUE) {
    pageBackwardValue = True;
  }
  if (g_rime && sessionIdentifier != 0) {
    handledValue = g_rime->change_page(
        static_cast<RimeSessionId>(sessionIdentifier), pageBackwardValue);
  }
  return snapshotForSession(
      environment,
      static_cast<RimeSessionId>(sessionIdentifier),
      handledValue == True,
      false);
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_caizhichao_typingdongnanya_rime_RimeNative_commitComposition(
    JNIEnv* environment,
    jobject,
    jlong sessionIdentifier) {
  std::lock_guard<std::mutex> lock(g_rime_mutex);
  Bool handledValue = False;
  if (g_rime && sessionIdentifier != 0) {
    handledValue = g_rime->commit_composition(
        static_cast<RimeSessionId>(sessionIdentifier));
  }
  return snapshotForSession(
      environment,
      static_cast<RimeSessionId>(sessionIdentifier),
      handledValue == True,
      true);
}

extern "C" JNIEXPORT void JNICALL
Java_com_caizhichao_typingdongnanya_rime_RimeNative_clearComposition(
    JNIEnv*,
    jobject,
    jlong sessionIdentifier) {
  std::lock_guard<std::mutex> lock(g_rime_mutex);
  if (g_rime && sessionIdentifier != 0) {
    g_rime->clear_composition(static_cast<RimeSessionId>(sessionIdentifier));
  }
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_caizhichao_typingdongnanya_rime_RimeNative_setOption(
    JNIEnv* environment,
    jobject,
    jlong sessionIdentifier,
    jstring optionName,
    jboolean enabledValue) {
  std::lock_guard<std::mutex> lock(g_rime_mutex);
  if (g_rime && sessionIdentifier != 0) {
    const std::string optionText = utf8String(environment, optionName);
    Bool enabledOptionValue = False;
    if (enabledValue == JNI_TRUE) {
      enabledOptionValue = True;
    }
    g_rime->set_option(
        static_cast<RimeSessionId>(sessionIdentifier),
        optionText.c_str(),
        enabledOptionValue);
  }
  return snapshotForSession(
      environment,
      static_cast<RimeSessionId>(sessionIdentifier),
      true,
      false);
}
