package com.taxijipijapa.taxi_jipijapa

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.PorterDuff
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.ImageView
import androidx.core.app.NotificationCompat

/**
 * Foreground service that shows a floating PTT (Push-to-Talk) button
 * on top of all other apps. Requires SYSTEM_ALERT_WINDOW permission.
 *
 * Touch handling:
 * - Touch down: starts PTT (after 100ms to allow drag detection)
 * - Touch move > threshold: cancels PTT, starts drag
 * - Touch up: stops PTT
 *
 * Visual states:
 * - connecting (amber): Agora engine initializing & joining channel
 * - idle (green): connected to channel, ready for instant PTT
 * - transmitting (red): user is speaking
 */
class OverlayPttService : Service() {

    companion object {
        const val CHANNEL_ID = "overlay_ptt_channel"
        const val NOTIFICATION_ID = 9998
        const val ACTION_STOP = "STOP_OVERLAY"
    }

    private var windowManager: WindowManager? = null
    private var overlayView: View? = null
    private var buttonView: ImageView? = null
    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null

    private var pttActivated = false
    private var isDragging = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()

        // Arrancamos con tipo MEDIA_PLAYBACK (idle): el mic queda libre
        // para que otras apps (WhatsApp, Zello, grabadora) puedan usarlo
        // mientras el overlay solo está visible. Solo conmutamos a
        // MICROPHONE cuando el usuario presiona el botón.
        applyForegroundType(microphoneActive = false)

        // Wake lock parcial — mantiene el CPU activo mientras el overlay está
        // corriendo, evitando que Doze mode mate el isolate de Flutter (donde
        // vive Agora). Sin esto, en background después de unos minutos el
        // PTT puede dejar de transmitir aunque el botón siga visible.
        try {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "TaxiJipijapa::OverlayPttWakeLock"
            ).apply {
                setReferenceCounted(false)
                acquire(10 * 60 * 1000L) // 10 min, se renueva periódicamente
            }
        } catch (_: Exception) {}

        // Register for state updates from Flutter
        PttBridge.onUpdateButtonState = { state ->
            handler.post { updateButtonVisualState(state) }
        }

        showFloatingButton()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    /**
     * Aplica el tipo de foreground service.
     *
     * Cuando microphoneActive=true, Android marca la app como "en uso del
     * micrófono" y bloquea otras apps que intenten capturarlo (WhatsApp
     * no graba, Zello no transmite, etc.). Por eso solo lo activamos
     * mientras el usuario presiona el PTT — el resto del tiempo usamos
     * MEDIA_PLAYBACK que NO toma el mic.
     *
     * En API < 34 no existe el sistema de service types granular, así
     * que no hace nada (la declaración del manifest cubre el permiso).
     */
    private fun applyForegroundType(microphoneActive: Boolean) {
        val notification = createNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            val type = if (microphoneActive) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            }
            try {
                startForeground(NOTIFICATION_ID, notification, type)
            } catch (e: Exception) {
                // Puede fallar si la app perdió permisos; no bloqueamos.
            }
        } else {
            try {
                startForeground(NOTIFICATION_ID, notification)
            } catch (_: Exception) {}
        }
    }

    override fun onDestroy() {
        try {
            wakeLock?.takeIf { it.isHeld }?.release()
        } catch (_: Exception) {}
        wakeLock = null
        removeFloatingButton()
        PttBridge.onUpdateButtonState = null
        PttBridge.sendOverlayClosed()
        super.onDestroy()
    }

    // ─────────────────── Notification ───────────────────

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Radio PTT Flotante",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Botón PTT flotante del walkie-talkie"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        // Open app intent
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val openPending = PendingIntent.getActivity(
            this, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Stop overlay intent
        val stopIntent = Intent(this, OverlayPttService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPending = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("🎙️ Radio Taxi Jipijapa")
            .setContentText("Conectado al canal — mantén presionado el botón para hablar")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(openPending)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Cerrar PTT",
                stopPending
            )
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    // ─────────────────── Floating Button ───────────────────

    private fun showFloatingButton() {
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        val size = dpToPx(62)

        val button = ImageView(this).apply {
            setImageResource(android.R.drawable.ic_btn_speak_now)
            setColorFilter(Color.WHITE, PorterDuff.Mode.SRC_IN)
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(dpToPx(14), dpToPx(14), dpToPx(14), dpToPx(14))
            background = createButtonBackground("idle")
            elevation = dpToPx(8).toFloat()
        }

        @Suppress("DEPRECATION")
        val layoutType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            WindowManager.LayoutParams.TYPE_PHONE

        val params = WindowManager.LayoutParams(
            size, size,
            layoutType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dpToPx(8)
            y = dpToPx(300)
        }

        setupTouchListener(button, params)

        buttonView = button
        overlayView = button
        windowManager?.addView(button, params)
    }

    private fun setupTouchListener(view: View, params: WindowManager.LayoutParams) {
        var initialX = 0
        var initialY = 0
        var initialTouchX = 0f
        var initialTouchY = 0f
        val moveThreshold = dpToPx(12)

        // Delayed PTT activation (allows distinguishing tap vs drag)
        val pttStartRunnable = Runnable {
            if (!isDragging) {
                pttActivated = true
                // Reclamar el micrófono ANTES de que Agora intente capturar.
                applyForegroundType(microphoneActive = true)
                updateButtonVisualState("connecting")
                PttBridge.sendPttDown()
            }
        }

        view.setOnTouchListener { v, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    initialX = params.x
                    initialY = params.y
                    initialTouchX = event.rawX
                    initialTouchY = event.rawY
                    isDragging = false

                    // Start PTT after 100ms delay (so user can drag without triggering PTT)
                    handler.postDelayed(pttStartRunnable, 100)
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - initialTouchX).toInt()
                    val dy = (event.rawY - initialTouchY).toInt()

                    if (!isDragging && (Math.abs(dx) > moveThreshold || Math.abs(dy) > moveThreshold)) {
                        isDragging = true
                        handler.removeCallbacks(pttStartRunnable)

                        // Cancel PTT if it was already activated
                        if (pttActivated) {
                            pttActivated = false
                            updateButtonVisualState("idle")
                            PttBridge.sendPttUp()
                            // Liberar mic — el usuario movió fuera y canceló PTT.
                            applyForegroundType(microphoneActive = false)
                        }
                    }

                    if (isDragging) {
                        params.x = initialX + dx
                        params.y = initialY + dy
                        try {
                            windowManager?.updateViewLayout(v, params)
                        } catch (_: Exception) {}
                    }
                    true
                }

                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    handler.removeCallbacks(pttStartRunnable)

                    if (pttActivated) {
                        pttActivated = false
                        updateButtonVisualState("idle")
                        PttBridge.sendPttUp()
                        // Liberar el micrófono al sistema — otras apps
                        // podrán usarlo de inmediato.
                        applyForegroundType(microphoneActive = false)
                    }

                    isDragging = false
                    true
                }

                else -> false
            }
        }
    }

    // ─────────────────── Visual State ───────────────────

    private fun updateButtonVisualState(state: String) {
        buttonView?.background = createButtonBackground(state)
    }

    private fun createButtonBackground(state: String): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            when (state) {
                "idle" -> {
                    setColor(Color.parseColor("#1B5E20"))
                    setStroke(dpToPx(2), Color.parseColor("#4CAF50"))
                }
                "connecting" -> {
                    setColor(Color.parseColor("#E65100"))
                    setStroke(dpToPx(2), Color.parseColor("#FF9800"))
                }
                "transmitting" -> {
                    setColor(Color.parseColor("#B71C1C"))
                    setStroke(dpToPx(2), Color.parseColor("#F44336"))
                }
                "error" -> {
                    // Borde rojo intermitente visual: gris oscuro con borde rojo
                    // brillante. Se diferencia claramente de "transmitting".
                    setColor(Color.parseColor("#424242"))
                    setStroke(dpToPx(3), Color.parseColor("#FF1744"))
                }
                else -> {
                    setColor(Color.parseColor("#1B5E20"))
                    setStroke(dpToPx(2), Color.parseColor("#4CAF50"))
                }
            }
        }
    }

    // ─────────────────── Cleanup ───────────────────

    private fun removeFloatingButton() {
        overlayView?.let {
            try {
                windowManager?.removeView(it)
            } catch (_: Exception) {}
        }
        overlayView = null
        buttonView = null
    }

    private fun dpToPx(dp: Int): Int {
        return (dp * resources.displayMetrics.density).toInt()
    }
}
