package dev.intmusic.intmusic_client

import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object IntMusicPlatformBridge {
    var channel: MethodChannel? = null

    fun invoke(method: String, arguments: Any? = null) {
        channel?.invokeMethod(method, arguments)
    }
}

class MainActivity : FlutterActivity() {
    private var mediaServiceStarted = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val platformChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.intmusic/platform")
        IntMusicPlatformBridge.channel = platformChannel
        platformChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> {
                    result.success(
                        mapOf(
                            "systemTray" to false,
                            "mediaSession" to true,
                            "nativeBackdrop" to true,
                            "backgroundPlayback" to true,
                        ),
                    )
                }

                "updatePlayback" -> {
                    val arguments = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                    val playbackState = arguments["state"]?.toString() ?: "stopped"
                    if (playbackState == "stopped" && !mediaServiceStarted) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val intent =
                        Intent(this, IntMusicMediaService::class.java)
                            .setAction(IntMusicMediaService.ACTION_UPDATE)
                            .putExtra("state", playbackState)
                            .putExtra("title", arguments["title"]?.toString() ?: "IntMusic")
                            .putExtra("artist", arguments["artist"]?.toString() ?: "")
                            .putExtra("album", arguments["album"]?.toString() ?: "")
                            .putExtra("durationMs", (arguments["durationMs"] as? Number)?.toLong() ?: 0L)
                            .putExtra("positionMs", (arguments["positionMs"] as? Number)?.toLong() ?: 0L)
                    ContextCompat.startForegroundService(this, intent)
                    mediaServiceStarted = playbackState != "stopped"
                    result.success(null)
                }

                "updateVolume" -> result.success(null)
                "moveToBackground" -> {
                    moveTaskToBack(true)
                    result.success(null)
                }

                "showWindow" -> {
                    startActivity(
                        Intent(this, MainActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    )
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        // Kept as a compatibility endpoint for older installed builds.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.intmusic/system")
            .setMethodCallHandler { call, result ->
                if (call.method == "moveToBackground") {
                    moveTaskToBack(true)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        IntMusicPlatformBridge.channel = null
        super.onDestroy()
    }
}
