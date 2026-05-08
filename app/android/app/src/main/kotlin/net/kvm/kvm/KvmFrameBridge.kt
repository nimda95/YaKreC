package net.kvm.kvm

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * Process-wide singleton bridging the Flutter side (which owns the device
 * connection and the JPEG frame stream) and the Android Auto Screen (which
 * needs a Bitmap to blit onto its Surface). MainActivity registers the
 * MethodChannel here when the FlutterEngine boots; the AA Screen subscribes
 * via [onUpdate] for redraw signals.
 */
object KvmFrameBridge {
    /** Latest frame pushed from Flutter, decoded to a Bitmap. */
    @Volatile var latestFrame: Bitmap? = null
        private set

    /** AA Screen registers a callback here so it knows to redraw. */
    @Volatile var onUpdate: (() -> Unit)? = null

    private const val TAG = "KvmCar"

    private var channel: MethodChannel? = null
    private var pushCount = 0L

    /** Called by MainActivity once the FlutterEngine is configured. */
    fun attachChannel(channel: MethodChannel) {
        this.channel = channel
        Log.i(TAG, "MethodChannel attached")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pushFrame" -> {
                    val bytes = call.argument<ByteArray>("jpeg")
                    if (bytes == null) {
                        Log.w(TAG, "pushFrame: no bytes")
                    } else {
                        val bm = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                        if (bm == null) {
                            Log.w(TAG, "pushFrame: BitmapFactory returned null for ${bytes.size}B")
                        } else {
                            val old = latestFrame
                            latestFrame = bm
                            old?.recycle()
                            pushCount++
                            // Log every ~30th frame so we can confirm the pipe.
                            if (pushCount % 30L == 1L) {
                                Log.i(TAG, "pushFrame #$pushCount " +
                                        "(${bm.width}x${bm.height}, ${bytes.size}B), " +
                                        "screen-bound=${onUpdate != null}")
                            }
                            onUpdate?.invoke()
                        }
                    }
                    result.success(null)
                }
                "clearFrame" -> {
                    latestFrame?.recycle()
                    latestFrame = null
                    pushCount = 0
                    Log.i(TAG, "clearFrame")
                    onUpdate?.invoke()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun detachChannel() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    // ───── Native → Flutter (touch events from the AA host) ───────────────

    fun forwardClick(nx: Float, ny: Float) {
        channel?.invokeMethod("onClick", mapOf("x" to nx, "y" to ny))
    }

    fun forwardScroll(dx: Float, dy: Float) {
        channel?.invokeMethod("onScroll", mapOf("dx" to dx, "dy" to dy))
    }

    fun forwardReload() {
        channel?.invokeMethod("reload", null)
    }
}
