package com.caizhichao.typingdongnanya.rime

// JNI 薄桥只暴露输入法当前需要的会话动作，不把 Swift/AppKit 前端结构带到 Android。
object RimeNative {
    init {
        System.loadLibrary("typing_dongnanya_rime")
    }

    external fun initialize(sharedDataDirectory: String, userDataDirectory: String): Boolean
    external fun createSession(): Long
    external fun destroySession(sessionIdentifier: Long)
    external fun currentSnapshot(sessionIdentifier: Long): RimeSnapshot
    external fun selectSchema(sessionIdentifier: Long, schemaIdentifier: String): RimeSnapshot
    external fun processKey(sessionIdentifier: Long, keyName: String): RimeSnapshot
    external fun selectCandidate(sessionIdentifier: Long, candidateIndex: Int): RimeSnapshot
    external fun changePage(sessionIdentifier: Long, pageBackward: Boolean): RimeSnapshot
    external fun commitComposition(sessionIdentifier: Long): RimeSnapshot
    external fun clearComposition(sessionIdentifier: Long)
    external fun setOption(sessionIdentifier: Long, optionName: String, enabledValue: Boolean): RimeSnapshot
}
