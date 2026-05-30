package com.wujian.app.icheck

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "com.wujian.app.icheck/file_saver"
    private val saveFileRequestCode = 9327
    private val nativeCameraRequestCode = 9328
    private var pendingSave: PendingSave? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingCameraResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFile" -> handleSaveFile(call, result)
                "getCameraMetadata" -> result.success(readCameraMetadata())
                "openNativeCamera" -> handleOpenNativeCamera(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun handleSaveFile(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "Another file save is already in progress.", null)
            return
        }

        val path = call.argument<String>("path")
        val fileName = call.argument<String>("fileName")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        if (path.isNullOrBlank() || fileName.isNullOrBlank()) {
            result.error("invalid_args", "Missing file path or file name.", null)
            return
        }

        val file = File(path)
        if (!file.exists()) {
            result.error("missing_file", "File does not exist.", null)
            return
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

    private fun readCameraMetadata(): List<Map<String, Any?>> {
        val cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        return cameraManager.cameraIdList.map { cameraId ->
            val characteristics = cameraManager.getCameraCharacteristics(cameraId)
            val facing = when (characteristics.get(CameraCharacteristics.LENS_FACING)) {
                CameraCharacteristics.LENS_FACING_FRONT -> "front"
                CameraCharacteristics.LENS_FACING_BACK -> "back"
                CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
                else -> "unknown"
            }
            val focalLengths =
                characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                    ?.map { it.toDouble() }
                    ?: emptyList()
            mapOf(
                "cameraId" to cameraId,
                "facing" to facing,
                "focalLengths" to focalLengths,
            )
        }
    }

    private fun handleOpenNativeCamera(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        if (pendingCameraResult != null) {
            result.error("busy", "Another native camera session is already in progress.", null)
            return
        }

        pendingCameraResult = result
        val captureBox = call.argument<String>("captureBox")
        val singleCapture = call.argument<Boolean>("singleCapture") ?: false
        val intent = Intent(this, NativeCameraActivity::class.java).apply {
            putExtra(NativeCameraActivity.EXTRA_SINGLE_CAPTURE, singleCapture)
            putExtra(NativeCameraActivity.EXTRA_CAPTURE_BOX, captureBox)
        }
        startActivityForResult(intent, nativeCameraRequestCode)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == nativeCameraRequestCode) {
            val result = pendingCameraResult
            pendingCameraResult = null
            if (result == null) {
                return
            }
            val capturedPaths =
                if (resultCode == Activity.RESULT_OK) {
                    data?.getStringArrayListExtra(NativeCameraActivity.EXTRA_CAPTURED_PATHS)
                        ?: arrayListOf()
                } else {
                    arrayListOf()
                }
            result.success(capturedPaths)
            return
        }

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
