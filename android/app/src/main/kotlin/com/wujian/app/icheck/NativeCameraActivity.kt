package com.wujian.app.icheck

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.graphics.drawable.GradientDrawable
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.StreamConfigurationMap
import android.media.ImageReader
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Build
import android.util.Size
import android.util.Log
import android.view.Gravity
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class NativeCameraActivity : Activity() {
    companion object {
        const val EXTRA_CAPTURE_BOX = "capture_box"
        const val EXTRA_SINGLE_CAPTURE = "single_capture"
        const val EXTRA_CAPTURED_PATHS = "captured_paths"
        private const val permissionRequestCode = 2001
        private const val tag = "NativeCameraActivity"
        private const val maxCaptureDimension = 2560
        private const val maxPreviewDimension = 1920
        private const val captureTimeoutMillis = 8_000L
    }

    private lateinit var textureView: TextureView
    private lateinit var lensTitleView: TextView
    private lateinit var statusView: TextView
    private lateinit var boxView: TextView
    private lateinit var lensButtonBar: LinearLayout
    private lateinit var flashButton: TextView
    private lateinit var switchButton: ImageButton

    private val capturedPaths = arrayListOf<String>()
    private val isCapturing = AtomicBoolean(false)
    private val isOpeningCamera = AtomicBoolean(false)
    private val cameraGeneration = AtomicLong(0)

    private lateinit var cameraManager: CameraManager
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var previewRequestBuilder: CaptureRequest.Builder? = null
    private var imageReader: ImageReader? = null
    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null
    @Volatile private var captureTimeout: Runnable? = null

    private var backLenses: List<NativeLensOption> = emptyList()
    private var frontLens: NativeLensOption? = null
    private var currentLens: NativeLensOption? = null
    private var showingFront = false
    private var singleCapture = false
    private var currentPreviewSize: Size? = null
    private var currentSensorOrientation: Int = 90
    private var currentActiveArraySize: Rect? = null
    private var currentMaxDigitalZoom: Float = 1f
    private var pendingLensDiagnostics = true
    private var torchEnabled = false
    private var torchSupportedLensId: String? = null
    private var torchSupported: Boolean? = null
    @Volatile private var isActivityResumed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        singleCapture = intent.getBooleanExtra(EXTRA_SINGLE_CAPTURE, false)
        buildUi()
        loadLensOptions()
        updateUiForLens()
    }

    override fun onResume() {
        super.onResume()
        isActivityResumed = true
        startBackgroundThread()
        if (!hasCameraPermission()) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.CAMERA),
                permissionRequestCode,
            )
            return
        }
        if (textureView.isAvailable) {
            openCurrentCamera()
        } else {
            textureView.surfaceTextureListener = surfaceTextureListener
        }
    }

    override fun onPause() {
        isActivityResumed = false
        closeCamera()
        stopBackgroundThread()
        super.onPause()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != permissionRequestCode) {
            return
        }
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            openCurrentCamera()
        } else {
            finishWithResult()
        }
    }

    private fun buildUi() {
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }

        textureView = TextureView(this)
        textureView.surfaceTextureListener = surfaceTextureListener
        root.addView(
            textureView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        val closeButton = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            background = pillBackground(0x66000000, cornerRadiusDp = 16)
            setColorFilter(Color.WHITE)
            setOnClickListener { finishWithResult() }
        }
        root.addView(
            closeButton,
            FrameLayout.LayoutParams(dp(44), dp(44), Gravity.TOP or Gravity.START).apply {
                topMargin = dp(12)
                leftMargin = dp(12)
            },
        )

        switchButton = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_camera)
            background = pillBackground(0x66000000, cornerRadiusDp = 16)
            setColorFilter(Color.WHITE)
            setOnClickListener { toggleFrontBack() }
        }

        val topActionBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        flashButton =
            TextView(this).apply {
                textSize = 14f
                gravity = Gravity.CENTER
                setPadding(dp(14), dp(10), dp(14), dp(10))
                setOnClickListener { toggleTorch() }
            }
        topActionBar.addView(flashButton)
        topActionBar.addView(
            switchButton,
            LinearLayout.LayoutParams(dp(44), dp(44)).apply {
                leftMargin = dp(8)
            },
        )
        root.addView(
            topActionBar,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.END,
            ).apply {
                topMargin = dp(12)
                rightMargin = dp(12)
            },
        )

        boxView = badgeTextView()
        root.addView(
            boxView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.START,
            ).apply {
                topMargin = dp(72)
                leftMargin = dp(20)
            },
        )

        lensTitleView = badgeTextView()
        root.addView(
            lensTitleView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.START,
            ).apply {
                topMargin = dp(118)
                leftMargin = dp(20)
            },
        )

        val bottomPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }

        statusView = badgeTextView().apply { visibility = View.GONE }
        bottomPanel.addView(statusView)

        lensButtonBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        val lensBarContainer = FrameLayout(this).apply {
            background = pillBackground(0x7A000000, cornerRadiusDp = 22)
            addView(
                lensButtonBar,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                    Gravity.CENTER,
                ).apply {
                    leftMargin = dp(10)
                    rightMargin = dp(10)
                    topMargin = dp(8)
                    bottomMargin = dp(8)
                },
            )
        }
        bottomPanel.addView(lensBarContainer)

        val captureButton = FrameLayout(this).apply {
            background = ovalBackground(0x33000000, strokeColor = 0x55FFFFFF, strokeWidthDp = 2)
            setOnClickListener { captureStillImage() }
            addView(
                View(this@NativeCameraActivity).apply {
                    background = ovalBackground(Color.WHITE, strokeColor = 0x22000000, strokeWidthDp = 1)
                },
                FrameLayout.LayoutParams(dp(64), dp(64), Gravity.CENTER),
            )
        }
        bottomPanel.addView(
            captureButton,
            LinearLayout.LayoutParams(dp(84), dp(84)).apply {
                topMargin = dp(18)
            },
        )

        root.addView(
            bottomPanel,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM,
            ).apply {
                bottomMargin = dp(24)
                leftMargin = dp(20)
                rightMargin = dp(20)
            },
        )

        setContentView(root)
    }

    private fun loadLensOptions() {
        val options = mutableListOf<NativeLensOption>()
        for (cameraId in cameraManager.cameraIdList) {
            val characteristics = cameraManager.getCameraCharacteristics(cameraId)
            val facing = characteristics.get(CameraCharacteristics.LENS_FACING)
            val focalLength =
                characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                    ?.firstOrNull()
                    ?.toDouble()
            val capabilities =
                characteristics.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
                    ?.toSet()
                    ?: emptySet()
            val physicalCameraIds =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    characteristics.physicalCameraIds
                } else {
                    emptySet()
                }
            val option = NativeLensOption(
                cameraId = cameraId,
                facing = facing ?: CameraCharacteristics.LENS_FACING_BACK,
                focalLength = focalLength,
                physicalCameraIds = physicalCameraIds,
                isLogicalMultiCamera =
                    capabilities.contains(
                        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA,
                    ) || physicalCameraIds.isNotEmpty(),
            )
            options += option
        }

        val backCandidates =
            expandBackLensCandidates(options)
                .filter {
                    it.facing == CameraCharacteristics.LENS_FACING_BACK &&
                        it.focalLength != null
                }
                .distinctBy { "${it.cameraId}:${it.physicalCameraId ?: "-"}" }
                .sortedBy { it.focalLength ?: Double.MAX_VALUE }

        val selectedBackLenses =
            selectTargetLenses(
                backCandidates = backCandidates,
                targets = listOf(1.77, 3.23, 5.59),
            ).ifEmpty {
                backCandidates
            }

        backLenses = buildBackLensPresets(options, selectedBackLenses)

        logLensOptions(backLenses, "selectedBackLenses")
        frontLens = options.firstOrNull { it.facing == CameraCharacteristics.LENS_FACING_FRONT }?.copy(
            label = "前置",
        )
        currentLens = backLenses.firstOrNull() ?: frontLens
    }

    private fun updateUiForLens() {
        val captureBox = intent.getStringExtra(EXTRA_CAPTURE_BOX).orEmpty()
        boxView.visibility = if (captureBox.isBlank()) View.GONE else View.VISIBLE
        boxView.text = "当前箱子：$captureBox"

        val lens = currentLens
        lensTitleView.text = when {
            lens == null -> "当前镜头"
            lens.facing == CameraCharacteristics.LENS_FACING_FRONT -> "当前镜头：前置"
            else -> "当前镜头：后置 · ${lens.label}"
        }

        switchButton.visibility = if (frontLens != null) View.VISIBLE else View.GONE
        val isBackLens = lens?.facing == CameraCharacteristics.LENS_FACING_BACK
        if (!isBackLens) {
            torchEnabled = false
        }
        val canUseTorch = isBackLens && currentLensSupportsTorch()
        flashButton.visibility = if (canUseTorch) View.VISIBLE else View.GONE
        flashButton.text = if (torchEnabled) "闪光灯开" else "闪光灯关"
        flashButton.setTextColor(if (torchEnabled) Color.BLACK else Color.WHITE)
        flashButton.background =
            if (torchEnabled) {
                pillBackground(Color.WHITE, cornerRadiusDp = 18)
            } else {
                pillBackground(0x66000000, cornerRadiusDp = 18)
            }
        lensButtonBar.visibility =
            if (isBackLens && backLenses.size > 1) View.VISIBLE else View.GONE
        lensButtonBar.removeAllViews()
        if (isBackLens) {
            for (lensOption in backLenses) {
                lensButtonBar.addView(buildLensButton(lensOption))
            }
        }
    }

    private fun buildLensButton(lens: NativeLensOption): TextView {
        return TextView(this).apply {
            text = lens.label
            textSize = 15f
            gravity = Gravity.CENTER
            setTextColor(if (sameLens(lens, currentLens)) Color.BLACK else Color.WHITE)
            background =
                if (sameLens(lens, currentLens)) {
                    pillBackground(Color.WHITE, cornerRadiusDp = 18)
                } else {
                    pillBackground(0x22FFFFFF, cornerRadiusDp = 18)
                }
            setPadding(dp(16), dp(10), dp(16), dp(10))
            setOnClickListener { selectLens(lens) }
            val params = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
            params.leftMargin = dp(4)
            params.rightMargin = dp(4)
            layoutParams = params
        }
    }

    private fun selectLens(lens: NativeLensOption) {
        if (sameLens(lens, currentLens) || isCapturing.get()) {
            return
        }
        showingFront = false
        currentLens = lens
        pendingLensDiagnostics = true
        updateUiForLens()
        reopenCamera()
    }

    private fun toggleFrontBack() {
        val front = frontLens ?: return
        if (showingFront) {
            showingFront = false
            currentLens = backLenses.firstOrNull() ?: currentLens
        } else {
            showingFront = true
            currentLens = front
        }
        pendingLensDiagnostics = true
        updateUiForLens()
        reopenCamera()
    }

    private fun reopenCamera() {
        closeCamera()
        openCurrentCamera()
    }

    private fun openCurrentCamera() {
        val lens = currentLens ?: return
        if (
            !hasCameraPermission() ||
                !textureView.isAvailable ||
                !isActivityResumed ||
                cameraDevice != null ||
                !isOpeningCamera.compareAndSet(false, true)
        ) {
            return
        }
        val generation = cameraGeneration.incrementAndGet()
        try {
            val characteristics = cameraManager.getCameraCharacteristics(lens.cameraId)
            val configMap =
                characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                    ?: run {
                        isOpeningCamera.set(false)
                        return
                    }
            currentSensorOrientation =
                characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
            currentActiveArraySize =
                characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
            currentMaxDigitalZoom =
                characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f
            val previewSize = choosePreviewSize(configMap)
            currentPreviewSize = previewSize
            setupImageReader(configMap, generation)

            val texture =
                textureView.surfaceTexture
                    ?: run {
                        isOpeningCamera.set(false)
                        return
                    }
            texture.setDefaultBufferSize(previewSize.width, previewSize.height)
            applyPreviewTransform(previewSize)

            @Suppress("MissingPermission")
            cameraManager.openCamera(
                lens.cameraId,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(device: CameraDevice) {
                        if (
                            generation != cameraGeneration.get() ||
                                !isActivityResumed
                        ) {
                            device.close()
                            return
                        }
                        isOpeningCamera.set(false)
                        cameraDevice = device
                        try {
                            createPreviewSession(texture, generation)
                        } catch (error: Exception) {
                            Log.e(tag, "Failed to create preview session", error)
                            device.close()
                            if (generation == cameraGeneration.get()) {
                                cameraDevice = null
                                showCaptureError("相机预览启动失败，请退出后重试")
                            }
                        }
                    }

                    override fun onDisconnected(device: CameraDevice) {
                        device.close()
                        if (generation == cameraGeneration.get()) {
                            isOpeningCamera.set(false)
                            if (cameraDevice === device) {
                                cameraDevice = null
                            }
                        }
                    }

                    override fun onError(device: CameraDevice, error: Int) {
                        device.close()
                        if (generation == cameraGeneration.get()) {
                            isOpeningCamera.set(false)
                            if (cameraDevice === device) {
                                cameraDevice = null
                            }
                            showCaptureError("相机打开失败，请退出后重试")
                        }
                    }
                },
                backgroundHandler,
            )
        } catch (error: Exception) {
            isOpeningCamera.set(false)
            Log.e(tag, "Failed to open camera", error)
            showCaptureError("相机打开失败，请退出后重试")
        }
    }

    private fun createPreviewSession(
        texture: SurfaceTexture,
        generation: Long,
    ) {
        val device = cameraDevice ?: return
        val previewSurface = Surface(texture)
        val readerSurface = imageReader?.surface ?: return
        previewRequestBuilder =
            device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(previewSurface)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                applyTorchState(this)
                applyLensFraming(this, currentLens)
            }

        val callback =
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    if (
                        generation != cameraGeneration.get() ||
                            cameraDevice !== device ||
                            !isActivityResumed
                    ) {
                        session.close()
                        return
                    }
                    captureSession = session
                    runCatching {
                        session.setRepeatingRequest(
                            previewRequestBuilder!!.build(),
                            previewCaptureCallback,
                            backgroundHandler,
                        )
                    }.onFailure { error ->
                        Log.e(tag, "Failed to start camera preview", error)
                        showCaptureError("相机预览启动失败，请退出后重试")
                    }
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    session.close()
                    if (generation == cameraGeneration.get()) {
                        captureSession = null
                        showCaptureError("相机预览配置失败，请退出后重试")
                    }
                }
            }

        val physicalCameraId = currentLens?.physicalCameraId
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                physicalCameraId != null &&
                (currentLens?.zoomRatio ?: 1f) <= 1f
        ) {
            val outputConfigurations =
                listOf(previewSurface, readerSurface).map { surface ->
                    OutputConfiguration(surface).apply {
                        setPhysicalCameraId(physicalCameraId)
                    }
                }
            device.createCaptureSessionByOutputConfigurations(
                outputConfigurations,
                callback,
                backgroundHandler,
            )
        } else {
            device.createCaptureSession(
                listOf(previewSurface, readerSurface),
                callback,
                backgroundHandler,
            )
        }
    }

    private fun setupImageReader(
        configMap: StreamConfigurationMap,
        generation: Long,
    ) {
        imageReader?.close()
        val outputSize = chooseCaptureSize(configMap)
        imageReader = ImageReader.newInstance(
            outputSize.width,
            outputSize.height,
            android.graphics.ImageFormat.JPEG,
            2,
        ).apply {
            setOnImageAvailableListener({ reader ->
                var image: android.media.Image? = null
                var file: File? = null
                try {
                    image = reader.acquireLatestImage()
                    if (image == null) {
                        throw IllegalStateException("Camera returned no image")
                    }
                    if (generation != cameraGeneration.get()) {
                        return@setOnImageAvailableListener
                    }
                    val buffer = image.planes[0].buffer
                    val bytes = ByteArray(buffer.remaining())
                    buffer.get(bytes)
                    file = File(cacheDir, "capture-${System.nanoTime()}.jpg")
                    FileOutputStream(file).use { output ->
                        output.write(bytes)
                        output.fd.sync()
                    }
                    if (generation != cameraGeneration.get()) {
                        file.delete()
                        return@setOnImageAvailableListener
                    }
                    val capturedCount =
                        synchronized(capturedPaths) {
                            capturedPaths += file.absolutePath
                            capturedPaths.size
                        }
                    MainActivity.emitNativeCameraCapture(file.absolutePath)
                    runOnUiThread {
                        statusView.visibility = View.VISIBLE
                        statusView.text = "已加入 $capturedCount 张，后台识别中"
                        if (singleCapture) {
                            finishWithResult()
                        }
                    }
                } catch (error: Exception) {
                    file?.delete()
                    Log.e(tag, "Failed to persist captured image", error)
                    if (generation == cameraGeneration.get()) {
                        showCaptureError("照片保存失败，请检查存储空间后重试")
                    }
                } finally {
                    image?.close()
                    if (generation == cameraGeneration.get()) {
                        releaseCaptureLock()
                    }
                }
            }, backgroundHandler)
        }
    }

    private fun captureStillImage() {
        val device = cameraDevice ?: return
        val session = captureSession ?: return
        val readerSurface = imageReader?.surface ?: return
        if (!isCapturing.compareAndSet(false, true)) {
            return
        }
        try {
            armCaptureTimeout()
            val request =
                device.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                    addTarget(readerSurface)
                    set(
                        CaptureRequest.CONTROL_AF_MODE,
                        CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE,
                    )
                    set(CaptureRequest.JPEG_ORIENTATION, jpegOrientation())
                    applyTorchState(this)
                    applyLensFraming(this, currentLens)
                }
            session.capture(
                request.build(),
                object : CameraCaptureSession.CaptureCallback() {
                    override fun onCaptureCompleted(
                        session: CameraCaptureSession,
                        request: CaptureRequest,
                        result: TotalCaptureResult,
                    ) {
                        logCaptureResult("still", result)
                        previewRequestBuilder?.build()?.let {
                            session.setRepeatingRequest(it, previewCaptureCallback, backgroundHandler)
                        }
                    }

                    override fun onCaptureFailed(
                        session: CameraCaptureSession,
                        request: CaptureRequest,
                        failure: CaptureFailure,
                    ) {
                        releaseCaptureLock()
                        showCaptureError("拍摄失败，请重试")
                    }

                    override fun onCaptureSequenceAborted(
                        session: CameraCaptureSession,
                        sequenceId: Int,
                    ) {
                        releaseCaptureLock()
                        showCaptureError("拍摄已中断，请重试")
                    }
                },
                backgroundHandler,
            )
        } catch (error: Exception) {
            releaseCaptureLock()
            Log.e(tag, "Failed to submit capture request", error)
            showCaptureError("无法拍摄，请重新打开相机后重试")
        }
    }

    private fun chooseCaptureSize(configMap: StreamConfigurationMap): Size {
        val sizes =
            configMap.getOutputSizes(android.graphics.ImageFormat.JPEG)?.toList().orEmpty()
        return sizes
            .filter { maxOf(it.width, it.height) <= maxCaptureDimension }
            .maxByOrNull { it.width.toLong() * it.height.toLong() }
            ?: sizes.minByOrNull { it.width.toLong() * it.height.toLong() }
            ?: Size(1920, 1080)
    }

    private fun showCaptureError(message: String) {
        runOnUiThread {
            statusView.visibility = View.VISIBLE
            statusView.text = message
        }
    }

    private fun finishWithResult() {
        val resultPaths = synchronized(capturedPaths) { ArrayList(capturedPaths) }
        val intent = Intent().putStringArrayListExtra(EXTRA_CAPTURED_PATHS, resultPaths)
        setResult(RESULT_OK, intent)
        finish()
    }

    private fun closeCamera() {
        cameraGeneration.incrementAndGet()
        isOpeningCamera.set(false)
        releaseCaptureLock()
        captureSession?.close()
        captureSession = null
        cameraDevice?.close()
        cameraDevice = null
        imageReader?.close()
        imageReader = null
        currentActiveArraySize = null
        currentMaxDigitalZoom = 1f
    }

    private fun armCaptureTimeout() {
        val handler = backgroundHandler ?: return
        captureTimeout?.let(handler::removeCallbacks)
        val timeout =
            Runnable {
                captureTimeout = null
                if (isCapturing.compareAndSet(true, false)) {
                    runOnUiThread {
                        statusView.visibility = View.VISIBLE
                        statusView.text = "拍摄响应超时，正在重置相机"
                        if (isActivityResumed) {
                            reopenCamera()
                        }
                    }
                }
            }
        captureTimeout = timeout
        handler.postDelayed(timeout, captureTimeoutMillis)
    }

    private fun releaseCaptureLock() {
        val timeout = captureTimeout
        captureTimeout = null
        if (timeout != null) {
            backgroundHandler?.removeCallbacks(timeout)
        }
        isCapturing.set(false)
    }

    private fun startBackgroundThread() {
        backgroundThread = HandlerThread("NativeCameraThread").also { it.start() }
        backgroundHandler = Handler(backgroundThread!!.looper)
    }

    private fun stopBackgroundThread() {
        backgroundThread?.quitSafely()
        backgroundThread?.join()
        backgroundThread = null
        backgroundHandler = null
    }

    private fun hasCameraPermission(): Boolean {
        return ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun choosePreviewSize(configMap: StreamConfigurationMap): Size {
        val targetRatio = 4.0 / 3.0
        val sizes = configMap.getOutputSizes(SurfaceTexture::class.java)?.toList().orEmpty()
        val boundedSizes =
            sizes
                .filter { maxOf(it.width, it.height) <= maxPreviewDimension }
                .ifEmpty { sizes }
        return boundedSizes
            .minWithOrNull(
                compareBy<Size> { size ->
                    val ratio = size.width.toDouble() / size.height.toDouble()
                    kotlin.math.abs(ratio - targetRatio)
                }.thenByDescending { it.width.toLong() * it.height.toLong() },
            )
            ?: Size(1440, 1080)
    }

    private fun badgeTextView(): TextView {
        return TextView(this).apply {
            textSize = 14f
            setTextColor(Color.WHITE)
            background = pillBackground(0x66000000, cornerRadiusDp = 18)
            setPadding(dp(14), dp(9), dp(14), dp(9))
        }
    }

    private fun toggleTorch() {
        if (!currentLensSupportsTorch() || isCapturing.get()) {
            return
        }
        torchEnabled = !torchEnabled
        updateUiForLens()
        applyTorchToPreview()
    }

    private fun applyTorchToPreview() {
        val session = captureSession ?: return
        val builder = previewRequestBuilder ?: return
        applyTorchState(builder)
        runCatching {
            session.setRepeatingRequest(builder.build(), previewCaptureCallback, backgroundHandler)
        }
    }

    private fun applyTorchState(builder: CaptureRequest.Builder) {
        if (torchEnabled && currentLensSupportsTorch()) {
            builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_TORCH)
        } else {
            builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            builder.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF)
        }
    }

    private fun currentLensSupportsTorch(): Boolean {
        val lens = currentLens ?: return false
        if (torchSupportedLensId == lens.cameraId) {
            return torchSupported ?: false
        }
        torchSupportedLensId = lens.cameraId
        torchSupported = runCatching {
            val characteristics = cameraManager.getCameraCharacteristics(lens.cameraId)
            characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        }.getOrDefault(false)
        return torchSupported ?: false
    }

    private fun selectTargetLenses(
        backCandidates: List<NativeLensOption>,
        targets: List<Double>,
    ): List<NativeLensOption> {
        if (backCandidates.isEmpty()) {
            return emptyList()
        }

        val chosen = mutableListOf<NativeLensOption>()
        for (target in targets) {
            val match =
                backCandidates
                    .filterNot { picked -> chosen.any { sameLens(it, picked) } }
                    .minWithOrNull(
                        compareBy<NativeLensOption> {
                            kotlin.math.abs((it.focalLength ?: Double.MAX_VALUE) - target)
                        }.thenBy { !it.isPhysicalSelection }
                            .thenBy { it.isLogicalMultiCamera }
                            .thenBy { it.cameraId },
                    )
            if (match != null) {
                chosen += match
            }
        }

        return chosen
            .distinctBy { "${it.cameraId}:${it.physicalCameraId ?: "-"}" }
            .sortedBy { it.focalLength ?: Double.MAX_VALUE }
    }

    private fun sameLens(left: NativeLensOption?, right: NativeLensOption?): Boolean {
        if (left == null || right == null) {
            return false
        }
        return left.cameraId == right.cameraId &&
            left.physicalCameraId == right.physicalCameraId &&
            left.zoomRatio == right.zoomRatio
    }

    private fun buildBackLensPresets(
        options: List<NativeLensOption>,
        selectedBackLenses: List<NativeLensOption>,
    ): List<NativeLensOption> {
        val trimmed =
            selectedBackLenses.take(3).mapIndexed { index, option ->
                option.copy(
                    label = when {
                        selectedBackLenses.size >= 3 && index == 0 -> "广角"
                        selectedBackLenses.size >= 3 && index == 1 -> "1x"
                        selectedBackLenses.size >= 3 && index == 2 -> "2x"
                        selectedBackLenses.size == 2 && index == 0 -> "1x"
                        selectedBackLenses.size == 2 && index == 1 -> "2x"
                        else -> "1x"
                    },
                )
            }
        val logicalBack =
            options
                .filter { it.facing == CameraCharacteristics.LENS_FACING_BACK && it.isLogicalMultiCamera }
                .minByOrNull { kotlin.math.abs((it.focalLength ?: Double.MAX_VALUE) - 3.23) }
        val mainPreset = trimmed.firstOrNull { it.label == "1x" }
        if (logicalBack == null || mainPreset == null) {
            return trimmed
        }
        val mainFocal = mainPreset.focalLength ?: logicalBack.focalLength ?: 1.0
        return trimmed.map { option ->
            when (option.label) {
                "1x" ->
                    logicalBack.copy(
                        label = option.label,
                        focalLength = mainFocal,
                        physicalCameraId = null,
                        zoomRatio = 1f,
                    )
                "2x" -> {
                    val targetRatio =
                        ((option.focalLength ?: (mainFocal * 2.0)) / mainFocal)
                            .toFloat()
                            .coerceAtLeast(1.1f)
                    logicalBack.copy(
                        label = option.label,
                        focalLength = option.focalLength ?: (mainFocal * targetRatio),
                        physicalCameraId = null,
                        zoomRatio = targetRatio,
                    )
                }
                else -> option
            }
        }
    }

    private fun expandBackLensCandidates(options: List<NativeLensOption>): List<NativeLensOption> {
        val expanded = mutableListOf<NativeLensOption>()
        for (option in options) {
            if (option.facing != CameraCharacteristics.LENS_FACING_BACK) {
                expanded += option
                continue
            }
            expanded += option
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P || option.physicalCameraIds.isEmpty()) {
                continue
            }
            for (physicalId in option.physicalCameraIds.sorted()) {
                val physicalCharacteristics =
                    runCatching { cameraManager.getCameraCharacteristics(physicalId) }.getOrNull()
                        ?: continue
                val physicalFocal =
                    physicalCharacteristics
                        .get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                        ?.firstOrNull()
                        ?.toDouble()
                expanded +=
                    option.copy(
                        focalLength = physicalFocal ?: option.focalLength,
                        physicalCameraId = physicalId,
                    )
            }
        }
        logLensOptions(expanded, "expandedBackCandidates")
        return expanded
    }

    private fun logLensOptions(options: List<NativeLensOption>, stage: String) {
        for (option in options) {
            Log.d(
                tag,
                "[$stage] label=${option.label} cameraId=${option.cameraId} physical=${option.physicalCameraId ?: "-"} focal=${option.focalLength} zoom=${option.zoomRatio ?: 1f} logical=${option.isLogicalMultiCamera}",
            )
        }
    }

    private fun applyLensFraming(
        builder: CaptureRequest.Builder,
        lens: NativeLensOption?,
    ) {
        val zoomRatio = lens?.zoomRatio ?: 1f
        if (zoomRatio <= 1f) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                builder.set(CaptureRequest.SCALER_CROP_REGION, currentActiveArraySize)
            }
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.set(
                CaptureRequest.CONTROL_ZOOM_RATIO,
                zoomRatio.coerceAtMost(currentMaxDigitalZoom.coerceAtLeast(1f)),
            )
            return
        }

        val activeArray = currentActiveArraySize ?: return
        val clampedZoom = zoomRatio.coerceAtMost(currentMaxDigitalZoom.coerceAtLeast(1f))
        val cropWidth = (activeArray.width() / clampedZoom).toInt()
        val cropHeight = (activeArray.height() / clampedZoom).toInt()
        val left = activeArray.left + (activeArray.width() - cropWidth) / 2
        val top = activeArray.top + (activeArray.height() - cropHeight) / 2
        builder.set(
            CaptureRequest.SCALER_CROP_REGION,
            Rect(left, top, left + cropWidth, top + cropHeight),
        )
    }

    private val previewCaptureCallback =
        object : CameraCaptureSession.CaptureCallback() {
            override fun onCaptureCompleted(
                session: CameraCaptureSession,
                request: CaptureRequest,
                result: TotalCaptureResult,
            ) {
                if (!pendingLensDiagnostics) {
                    return
                }
                pendingLensDiagnostics = false
                logCaptureResult("preview", result)
            }
        }

    private fun logCaptureResult(stage: String, result: TotalCaptureResult) {
        val lens = currentLens
        val focal = result.get(CaptureResult.LENS_FOCAL_LENGTH)
        Log.d(
            tag,
            "[$stage-result] label=${lens?.label ?: "-"} cameraId=${lens?.cameraId ?: "-"} physical=${lens?.physicalCameraId ?: "-"} zoom=${lens?.zoomRatio ?: 1f} focal=$focal",
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            for ((physicalId, physicalResult) in result.physicalCameraResults) {
                Log.d(
                    tag,
                    "[$stage-physical-result] id=$physicalId focal=${physicalResult.get(CaptureResult.LENS_FOCAL_LENGTH)}",
                )
            }
        }
    }

    private fun pillBackground(
        fillColor: Int,
        cornerRadiusDp: Int,
        strokeColor: Int? = null,
        strokeWidthDp: Int = 0,
    ): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(cornerRadiusDp).toFloat()
            setColor(fillColor)
            if (strokeColor != null && strokeWidthDp > 0) {
                setStroke(dp(strokeWidthDp), strokeColor)
            }
        }
    }

    private fun ovalBackground(
        fillColor: Int,
        strokeColor: Int? = null,
        strokeWidthDp: Int = 0,
    ): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(fillColor)
            if (strokeColor != null && strokeWidthDp > 0) {
                setStroke(dp(strokeWidthDp), strokeColor)
            }
        }
    }

    private fun applyPreviewTransform(previewSize: Size) {
        val viewWidth = textureView.width.toFloat()
        val viewHeight = textureView.height.toFloat()
        if (viewWidth <= 0f || viewHeight <= 0f) {
            return
        }

        val centerX = viewWidth / 2f
        val centerY = viewHeight / 2f
        val matrix = Matrix()
        val previewAspect = previewSize.height.toFloat() / previewSize.width.toFloat()
        val viewAspect = viewWidth / viewHeight
        val scaleX: Float
        val scaleY: Float

        if (previewAspect > viewAspect) {
            scaleX = previewAspect / viewAspect
            scaleY = 1f
        } else {
            scaleX = 1f
            scaleY = viewAspect / previewAspect
        }

        matrix.setScale(scaleX, scaleY, centerX, centerY)
        textureView.setTransform(matrix)
    }

    private fun jpegOrientation(): Int {
        val surfaceRotation =
            when (display?.rotation ?: Surface.ROTATION_0) {
                Surface.ROTATION_90 -> 90
                Surface.ROTATION_180 -> 180
                Surface.ROTATION_270 -> 270
                else -> 0
            }
        return if (showingFront) {
            (currentSensorOrientation + surfaceRotation) % 360
        } else {
            (currentSensorOrientation - surfaceRotation + 360) % 360
        }
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    private val surfaceTextureListener =
        object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(
                surface: SurfaceTexture,
                width: Int,
                height: Int,
            ) {
                openCurrentCamera()
            }

            override fun onSurfaceTextureSizeChanged(
                surface: SurfaceTexture,
                width: Int,
                height: Int,
            ) {
                currentPreviewSize?.let(::applyPreviewTransform)
            }

            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean = true

            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
        }
}

data class NativeLensOption(
    val cameraId: String,
    val facing: Int,
    val focalLength: Double?,
    val physicalCameraIds: Set<String> = emptySet(),
    val physicalCameraId: String? = null,
    val zoomRatio: Float? = null,
    val isLogicalMultiCamera: Boolean = false,
    val label: String = "",
) {
    val isPhysicalSelection: Boolean
        get() = !physicalCameraId.isNullOrBlank()
}
