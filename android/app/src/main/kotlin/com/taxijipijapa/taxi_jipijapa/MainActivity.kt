package com.taxijipijapa.taxi_jipijapa

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val OVERLAY_CHANNEL = "com.taxijipijapa/overlay"

    // NOTA: la "Parte B" (FlutterEngine cacheado + shouldDestroyEngineWithHost
    // = false) se revirtió porque desacoplar el engine de la actividad rompía
    // el PlatformView de Google Maps (el mapa quedaba en blanco). El engine
    // vuelve a estar atado a la actividad (comportamiento estándar de Flutter).
    // El overlay flotante sigue funcionando mientras la app está en background
    // (el FGS mantiene vivo el proceso); con la app totalmente cerrada el
    // botón flotante deja de transmitir hasta reabrir — paridad Zello pendiente
    // de una solución que no dependa de cachear el engine.

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            OVERLAY_CHANNEL
        )
        // Almacenar referencia para que OverlayPttService pueda enviar eventos a Flutter
        PttBridge.methodChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startOverlay" -> {
                    startOverlayService()
                    result.success(true)
                }
                "stopOverlay" -> {
                    stopOverlayService()
                    result.success(true)
                }
                "checkOverlayPermission" -> {
                    result.success(hasOverlayPermission())
                }
                "requestOverlayPermission" -> {
                    requestOverlayPermission()
                    result.success(true)
                }
                "updateButtonState" -> {
                    val state = call.argument<String>("state") ?: "idle"
                    PttBridge.onUpdateButtonState?.invoke(state)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // El canal del overlay se ata al engine de la actividad; al destruirse
        // la actividad limpiamos la referencia para no dejar un MethodChannel
        // colgando de un engine muerto.
        PttBridge.methodChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun hasOverlayPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(this)
        } else true
    }

    private fun requestOverlayPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName")
            )
            startActivityForResult(intent, 1234)
        }
    }

    private fun startOverlayService() {
        val intent = Intent(this, OverlayPttService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopOverlayService() {
        val intent = Intent(this, OverlayPttService::class.java)
        stopService(intent)
    }
}
