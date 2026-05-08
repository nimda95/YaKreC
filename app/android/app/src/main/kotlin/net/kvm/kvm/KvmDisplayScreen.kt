package net.kvm.kvm

import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import androidx.car.app.AppManager
import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.SurfaceCallback
import androidx.car.app.SurfaceContainer
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.model.Template
import androidx.car.app.navigation.model.NavigationTemplate
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner

/**
 * The single screen the AA host shows for our app. Renders a placeholder
 * until the Flutter side starts pushing frames; then blits each frame onto
 * the SurfaceContainer the host hands us.
 *
 * Touch events are forwarded back to Flutter via [KvmFrameBridge]; Flutter
 * does the actual HID send.
 */
class KvmDisplayScreen(carContext: CarContext) : Screen(carContext), SurfaceCallback {

    private companion object { const val TAG = "KvmCar" }

    private var surface: Surface? = null
    private var surfaceWidth = 0
    private var surfaceHeight = 0
    private val main = Handler(Looper.getMainLooper())

    init {
        // Register through the lifecycle so AppManager calls land after the
        // Screen reaches CREATED. Setting the surface callback in init{}
        // directly can throw on some hosts.
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onCreate(owner: LifecycleOwner) {
                try {
                    carContext.getCarService(AppManager::class.java)
                        .setSurfaceCallback(this@KvmDisplayScreen)
                    KvmFrameBridge.onUpdate = { main.post(::draw) }
                } catch (t: Throwable) {
                    Log.e(TAG, "setSurfaceCallback failed", t)
                }
            }

            override fun onDestroy(owner: LifecycleOwner) {
                KvmFrameBridge.onUpdate = null
                try {
                    carContext.getCarService(AppManager::class.java)
                        .setSurfaceCallback(null)
                } catch (_: Throwable) {}
            }
        })
    }

    override fun onGetTemplate(): Template {
        return try {
            NavigationTemplate.Builder()
                .setActionStrip(
                    ActionStrip.Builder()
                        .addAction(
                            Action.Builder()
                                .setTitle("Reload")
                                .setOnClickListener { KvmFrameBridge.forwardReload() }
                                .build()
                        )
                        .build()
                )
                .build()
        } catch (t: Throwable) {
            Log.e(TAG, "onGetTemplate failed", t)
            throw t
        }
    }

    // ───── SurfaceCallback ───────────────────────────────────────────────

    override fun onSurfaceAvailable(container: SurfaceContainer) {
        surface = container.surface
        surfaceWidth = container.width
        surfaceHeight = container.height
        Log.i(TAG, "onSurfaceAvailable ${surfaceWidth}x${surfaceHeight} valid=${surface?.isValid}")
        draw()
    }

    override fun onSurfaceDestroyed(container: SurfaceContainer) {
        Log.i(TAG, "onSurfaceDestroyed")
        surface = null
    }

    override fun onVisibleAreaChanged(visibleArea: Rect) {}
    override fun onStableAreaChanged(stableArea: Rect) {}

    override fun onClick(x: Float, y: Float) {
        val bm = KvmFrameBridge.latestFrame ?: return
        val mapped = mapToVideo(x, y, bm.width, bm.height) ?: return
        KvmFrameBridge.forwardClick(mapped.first, mapped.second)
    }

    override fun onScroll(distanceX: Float, distanceY: Float) {
        // SurfaceCallback delivers scroll deltas with the same sign convention
        // as a touchpad — invert to match cursor expectation.
        KvmFrameBridge.forwardScroll(-distanceX, -distanceY)
    }

    override fun onScale(focusX: Float, focusY: Float, scaleFactor: Float) {}
    override fun onFling(velocityX: Float, velocityY: Float) {}

    // ───── Rendering ─────────────────────────────────────────────────────

    private fun draw() {
        val s = surface ?: return
        if (!s.isValid) return
        val canvas = try {
            s.lockCanvas(null)
        } catch (_: Throwable) {
            return
        }
        try {
            canvas.drawColor(Color.BLACK)
            val bm = KvmFrameBridge.latestFrame
            if (bm != null && !bm.isRecycled) {
                val (dst, _) = letterbox(surfaceWidth, surfaceHeight, bm.width, bm.height)
                canvas.drawBitmap(bm, null, dst, null)
            } else {
                drawPlaceholder(canvas)
            }
        } finally {
            try { s.unlockCanvasAndPost(canvas) } catch (_: Throwable) {}
        }
    }

    private fun drawPlaceholder(canvas: android.graphics.Canvas) {
        val title = Paint().apply {
            color = Color.WHITE
            textSize = 64f
            textAlign = Paint.Align.CENTER
            isAntiAlias = true
            isFakeBoldText = true
        }
        val sub = Paint().apply {
            color = Color.LTGRAY
            textSize = 36f
            textAlign = Paint.Align.CENTER
            isAntiAlias = true
        }
        val cx = surfaceWidth / 2f
        val cy = surfaceHeight / 2f
        canvas.drawText("KVM", cx, cy - 20, title)
        canvas.drawText(
            "Connect a device on your phone (MJPEG profile)",
            cx, cy + 40, sub,
        )
    }

    /**
     * BoxFit.contain: pick the largest inner rect that preserves [vw]:[vh],
     * centred inside the [sw]×[sh] surface.
     */
    private fun letterbox(sw: Int, sh: Int, vw: Int, vh: Int): Pair<Rect, Rect> {
        val sAspect = sw.toFloat() / sh.coerceAtLeast(1)
        val vAspect = vw.toFloat() / vh.coerceAtLeast(1)
        val fitW: Int; val fitH: Int; val ox: Int; val oy: Int
        if (sAspect > vAspect) {
            fitH = sh; fitW = (fitH * vAspect).toInt()
            ox = (sw - fitW) / 2; oy = 0
        } else {
            fitW = sw; fitH = (fitW / vAspect).toInt()
            ox = 0; oy = (sh - fitH) / 2
        }
        return Pair(Rect(ox, oy, ox + fitW, oy + fitH), Rect(0, 0, vw, vh))
    }

    private fun mapToVideo(x: Float, y: Float, vw: Int, vh: Int): Pair<Float, Float>? {
        if (surfaceWidth == 0 || surfaceHeight == 0) return null
        val (dst, _) = letterbox(surfaceWidth, surfaceHeight, vw, vh)
        val nx = (x - dst.left) / dst.width().coerceAtLeast(1)
        val ny = (y - dst.top) / dst.height().coerceAtLeast(1)
        if (nx < 0f || nx > 1f || ny < 0f || ny > 1f) return null
        return Pair(nx, ny)
    }
}
