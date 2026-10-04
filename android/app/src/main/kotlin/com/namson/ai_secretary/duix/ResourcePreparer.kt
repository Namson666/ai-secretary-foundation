package com.namson.ai_secretary.duix

import android.content.Context
import android.util.Log
import ai.guiji.duix.DuixNcnn
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.zip.ZipInputStream

/**
 * Prepares DUIX SDK resources in the app's internal storage.
 *
 * The DUIX SDK reads models and base config from getFilesDir()/duix/, NOT from APK assets.
 * This class copies bundled assets to the expected internal storage paths before SDK init.
 *
 * Expected layout:
 *   {filesDir}/duix/model/gj_dh_res/    ← base config (extracted from zip)
 *   {filesDir}/duix/model/tmp/gj_dh_res  ← tag file (SDK checks existence)
 *   {filesDir}/duix/model/小秘/          ← model files (copied from assets)
 *   {filesDir}/duix/model/tmp/小秘       ← tag file
 */
object ResourcePreparer {

    private const val TAG = "DUIXResourcePrep"
    private const val BASE_ZIP = "duix/gj_dh_res.zip"
    private const val MODEL_ASSET = "duix/小秘"
    private const val BASE_DIR = "gj_dh_res"
    private const val MODEL_NAME = "小秘"

    @Volatile
    private var prepared = false

    @Synchronized
    fun prepareIfNeeded(context: Context): File {
        if (prepared) {
            return duixRoot(context)
        }

        val root = duixRoot(context)
        val modelDir = File(root, "model")
        val tmpDir = File(root, "model/tmp")

        modelDir.mkdirs()
        tmpDir.mkdirs()

        // 1. Extract gj_dh_res base config
        val baseDir = File(modelDir, BASE_DIR)
        val baseTag = File(tmpDir, BASE_DIR)
        val keyFile = File(baseDir, "wenet.o")
        val needsExtraction = !baseDir.exists() || !baseTag.exists() || !keyFile.exists()

        if (needsExtraction) {
            if (baseDir.exists()) baseDir.deleteRecursively()
            if (baseTag.exists()) baseTag.delete()
            Log.i(TAG, "Extracting gj_dh_res from assets...")
            try {
                context.assets.open(BASE_ZIP).use { input ->
                    ZipInputStream(input).use { zis ->
                        var entry = zis.nextEntry
                        while (entry != null) {
                            if (!entry.isDirectory) {
                                val relativeName = entry.name.removePrefix("$BASE_DIR/")
                                val outFile = File(baseDir, relativeName)
                                outFile.parentFile?.mkdirs()
                                FileOutputStream(outFile).use { fos ->
                                    zis.copyTo(fos)
                                }
                            }
                            zis.closeEntry()
                            entry = zis.nextEntry
                        }
                    }
                }
                baseTag.createNewFile()
                Log.i(TAG, "gj_dh_res extracted (${baseDir.listFiles()?.size ?: 0} files)")
            } catch (e: IOException) {
                Log.e(TAG, "Failed to extract gj_dh_res", e)
            }
        } else {
            Log.i(TAG, "gj_dh_res already present, skipping")
        }

        // 2. Copy model files from assets/duix/小秘/
        val modelOutDir = File(modelDir, MODEL_NAME)
        val modelTag = File(tmpDir, MODEL_NAME)

        if (!modelOutDir.exists() || !modelTag.exists()) {
            Log.i(TAG, "Copying model files from assets...")
            try {
                copyAssetsRecursive(context, MODEL_ASSET, modelOutDir)
                modelTag.createNewFile()
                Log.i(TAG, "Model files copied (${modelOutDir.listFiles()?.size ?: 0} top-level)")
            } catch (e: IOException) {
                Log.e(TAG, "Failed to copy model files", e)
            }
        } else {
            Log.i(TAG, "Model files already present, skipping")
        }

        prepareDecodedFiles(baseDir, modelOutDir)
        prepared = true

        return root
    }

    private fun duixRoot(context: Context): File = File(context.filesDir, "duix")

    private fun copyAssetsRecursive(context: Context, assetPath: String, destDir: File) {
        val assets = context.assets.list(assetPath)
        if (assets == null || assets.isEmpty()) {
            try {
                context.assets.open(assetPath).use { input ->
                    destDir.parentFile?.mkdirs()
                    FileOutputStream(destDir).use { output ->
                        input.copyTo(output)
                    }
                }
            } catch (_: IOException) {
            }
            return
        }
        destDir.mkdirs()
        for (name in assets) {
            val childAsset = "$assetPath/$name"
            val childFile = File(destDir, name)
            copyAssetsRecursive(context, childAsset, childFile)
        }
    }

    private fun prepareDecodedFiles(baseDir: File, modelDir: File) {
        try {
            val decoder = DuixNcnn()
            decodeRequiredFiles(
                decoder,
                baseDir,
                mapOf(
                    "alpha_model.b" to "ab",
                    "alpha_model.p" to "ap",
                    "cacert.p" to "cp",
                    "weight_168u.b" to "wb",
                    "wenet.o" to "wo",
                ),
            )
            decodeRequiredFiles(
                decoder,
                modelDir,
                mapOf(
                    "bbox.j" to "bj",
                    "config.j" to "cj",
                    "dh_model.b" to "db",
                    "dh_model.p" to "dp",
                ),
            )
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to prepare decoded DUIX model files", e)
        }
    }

    private fun decodeRequiredFiles(
        decoder: DuixNcnn,
        dir: File,
        files: Map<String, String>,
    ) {
        for ((sourceName, decodedName) in files) {
            val source = File(dir, sourceName)
            val decoded = File(dir, decodedName)
            if (!source.exists()) {
                Log.e(TAG, "DUIX source missing: ${source.absolutePath}")
                continue
            }
            if (decoded.exists() && decoded.length() > 0) {
                Log.i(TAG, "DUIX decoded file already present: ${decoded.absolutePath}")
                continue
            }

            val tmp = File(dir, "$decodedName.tmp")
            if (tmp.exists()) tmp.delete()
            val result = decoder.processmd5(0, source.absolutePath, tmp.absolutePath)
            val renamed = result == 0 && tmp.exists() && tmp.length() > 0 && tmp.renameTo(decoded)
            if (renamed) {
                Log.i(
                    TAG,
                    "DUIX decoded $sourceName -> $decodedName (${decoded.length()} bytes)",
                )
            } else {
                Log.e(
                    TAG,
                    "DUIX decode failed source=$sourceName target=$decodedName result=$result " +
                        "tmpExists=${tmp.exists()} tmpSize=${if (tmp.exists()) tmp.length() else -1}",
                )
                if (tmp.exists()) tmp.delete()
            }
        }
    }
}
