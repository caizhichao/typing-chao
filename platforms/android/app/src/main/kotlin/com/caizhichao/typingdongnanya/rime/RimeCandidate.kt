package com.caizhichao.typingdongnanya.rime

// JNI 直接写入候选字段，避免每次按键通过 JSON 序列化完整 librime 快照。
class RimeCandidate {
    @JvmField var textValue: String = ""
    @JvmField var commentText: String = ""
    @JvmField var labelText: String = ""
}
