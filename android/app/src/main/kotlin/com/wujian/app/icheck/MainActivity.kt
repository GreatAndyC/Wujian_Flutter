package com.wujian.app.icheck

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "com.wujian.app.icheck/file_saver"
    private val saveFileRequestCode = 9327
    private var pendingSave: PendingSave? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            if (call.method != "saveFile") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            if (pendingResult != null) {
                result.error("busy", "Another file save is already in progress.", null)
                return@setMethodCallHandler
            }

            val path = call.argument<String>("path")
            val fileName = call.argument<String>("fileName")
            val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
            if (path.isNullOrBlank() || fileName.isNullOrBlank()) {
                result.error("invalid_args", "Missing file path or file name.", null)
                return@setMethodCallHandler
            }

            val file = File(path)
            if (!file.exists()) {
                result.error("missing_file", "File does not exist.", null)
                return@setMethodCallHandler
            }

            pendingSave = PendingSave(path, mimeType)
            pendingResult = result
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mimeType
                putExtra(Intent.EXTRA_TITLE, fileName)
            }
            startActivityForResult(intent, saveFileRequestCode)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != saveFileRequestCode) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val save = pendingSave
        val result = pendingResult
        pendingSave = null
        pendingResult = null

        if (result == null || save == null) {
            return
        }

        if (resultCode != Activity.RESULT_OK) {
            result.success(false)
            return
        }

        val uri: Uri? = data?.data
        if (uri == null) {
            result.success(false)
            return
        }

        try {
            contentResolver.openOutputStream(uri)?.use { output ->
                File(save.path).inputStream().use { input ->
                    input.copyTo(output)
                }
            }
            result.success(true)
        } catch (error: Exception) {
            result.error("save_failed", error.message, null)
        }
    }

    private data class PendingSave(val path: String, val mimeType: String)
}
