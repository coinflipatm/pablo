package cv.towtruck.pablo

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/**
 * Hands incoming navigation intents (geo:, google.navigation:, Maps links,
 * shared text) to Dart, and exposes the APK signing fingerprint so the
 * Routes API key can be restricted to this app.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "cv.towtruck.pablo/intent"
    private var channel: MethodChannel? = null
    private var pending: Map<String, String?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialIntent" -> {
                    val payload = pending ?: extract(intent)
                    pending = null
                    result.success(payload)
                }
                "getSigningSha1" -> result.success(signingSha1())
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val payload = extract(intent)
        val ch = channel
        if (ch != null) {
            ch.invokeMethod("onNewIntent", payload)
        } else {
            pending = payload
        }
    }

    private fun extract(intent: Intent?): Map<String, String?> {
        if (intent == null) return mapOf("action" to null, "data" to null, "text" to null)
        val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
            ?: intent.getStringExtra(Intent.EXTRA_TEXT)
        return mapOf(
            "action" to intent.action,
            "data" to intent.dataString,
            "text" to text,
        )
    }

    private fun signingSha1(): String? {
        return try {
            val pm = packageManager
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val info = pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                info.signingInfo?.apkContentsSigners
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES).signatures
            }
            val sig = signatures?.firstOrNull() ?: return null
            val digest = MessageDigest.getInstance("SHA-1").digest(sig.toByteArray())
            digest.joinToString(":") { "%02X".format(it) }
        } catch (e: Exception) {
            null
        }
    }
}
