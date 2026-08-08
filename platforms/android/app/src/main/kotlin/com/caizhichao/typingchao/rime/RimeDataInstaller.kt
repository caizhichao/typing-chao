package com.caizhichao.typingchao.rime

import android.content.Context
import java.io.File

// 包内 Rime 数据按版本复制到应用私有目录，用户词典目录始终独立保留。
object RimeDataInstaller {
    data class DataDirectories(
        val sharedDataDirectory: File,
        val userDataDirectory: File,
    )

    fun prepare(context: Context): DataDirectories {
        val rimeRoot = File(context.filesDir, "rime")
        val sharedRoot = File(rimeRoot, "shared")
        val userRoot = File(rimeRoot, "user")
        val packagedVersion = context.assets.open("rime/rime-data-version.txt")
            .bufferedReader()
            .use { it.readText() }
        val installedVersionFile = File(sharedRoot, "rime-data-version.txt")
        val installedVersion = installedVersionFile.takeIf { it.isFile }?.readText()
        if (packagedVersion != installedVersion) {
            if (sharedRoot.exists() && !sharedRoot.deleteRecursively()) {
                error("无法清理旧版 Rime 共享数据")
            }
            sharedRoot.mkdirs()
            copyAssetDirectory(context, "rime", sharedRoot)
        }
        userRoot.mkdirs()
        return DataDirectories(sharedRoot, userRoot)
    }

    private fun copyAssetDirectory(context: Context, assetPath: String, targetDirectory: File) {
        val childNameList = context.assets.list(assetPath).orEmpty()
        if (childNameList.isEmpty()) {
            val targetFile = File(targetDirectory.parentFile, targetDirectory.name)
            targetFile.parentFile?.mkdirs()
            context.assets.open(assetPath).use { sourceStream ->
                targetFile.outputStream().use { targetStream ->
                    sourceStream.copyTo(targetStream)
                }
            }
            return
        }
        targetDirectory.mkdirs()
        for (childName in childNameList) {
            val childAssetPath = "$assetPath/$childName"
            val childTarget = File(targetDirectory, childName)
            val grandChildNameList = context.assets.list(childAssetPath).orEmpty()
            if (grandChildNameList.isEmpty()) {
                context.assets.open(childAssetPath).use { sourceStream ->
                    childTarget.outputStream().use { targetStream ->
                        sourceStream.copyTo(targetStream)
                    }
                }
            } else {
                copyAssetDirectory(context, childAssetPath, childTarget)
            }
        }
    }
}
