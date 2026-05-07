package com.taxijipijapa.taxi_jipijapa

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * Singleton bridge for PTT overlay communication.
 * Connects the native OverlayPttService with the Flutter engine via MethodChannel.
 */
object PttBridge {
    var methodChannel: MethodChannel? = null

    /** Callback from Flutter to native: update floating button visual state */
    var onUpdateButtonState: ((state: String) -> Unit)? = null

    /** Send PTT press event to Flutter */
    fun sendPttDown() {
        Handler(Looper.getMainLooper()).post {
            try {
                methodChannel?.invokeMethod("onPttDown", null)
            } catch (_: Exception) {}
        }
    }

    /** Send PTT release event to Flutter */
    fun sendPttUp() {
        Handler(Looper.getMainLooper()).post {
            try {
                methodChannel?.invokeMethod("onPttUp", null)
            } catch (_: Exception) {}
        }
    }

    /** Send overlay closed event to Flutter */
    fun sendOverlayClosed() {
        Handler(Looper.getMainLooper()).post {
            try {
                methodChannel?.invokeMethod("onOverlayClosed", null)
            } catch (_: Exception) {}
        }
    }
}
