package net.kvm.kvm

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.util.Log
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object { private const val TAG = "KvmPip" }

    private var pipChannel: MethodChannel? = null
    private var pipReady = false
    private var pipAspect = Rational(16, 9)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // AA frame bridge.
        val carChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "kvm.car.bridge",
        )
        KvmFrameBridge.attachChannel(carChannel)

        // Picture-in-Picture bridge.
        pipChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "kvm.pip.bridge",
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "setReady" -> {
                        pipReady = call.argument<Boolean>("ready") ?: false
                        result.success(null)
                    }
                    "setAspect" -> {
                        val w = call.argument<Int>("width") ?: 16
                        val h = call.argument<Int>("height") ?: 9
                        pipAspect = clampAspect(w, h)
                        result.success(null)
                    }
                    "enter" -> result.success(enterPipNow())
                    else -> result.notImplemented()
                }
            }
        }
    }

    /// Fires when the user backgrounds the activity (Home button, nav-up
    /// gesture, recents). If a KVM connection is active, drop into PiP.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipReady && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            enterPipNow()
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration?,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod(
            "modeChanged",
            mapOf("inPip" to isInPictureInPictureMode),
        )
    }

    private fun enterPipNow(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(pipAspect)
                .build()
            enterPictureInPictureMode(params)
        } catch (t: Throwable) {
            Log.e(TAG, "enterPictureInPictureMode failed", t)
            false
        }
    }

    /// Android's PiP aspect ratio is constrained to roughly 0.418..2.39.
    /// Anything outside that window throws — clamp to a sane default rather
    /// than crash. Most KVM hosts are 16:9 / 16:10 so this rarely fires.
    private fun clampAspect(w: Int, h: Int): Rational {
        if (w <= 0 || h <= 0) return Rational(16, 9)
        val r = w.toDouble() / h
        if (r < 0.42 || r > 2.39) return Rational(16, 9)
        return Rational(w, h)
    }
}
