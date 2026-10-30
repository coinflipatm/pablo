package cv.towtruck.pablo

import android.annotation.TargetApi
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/**
 * Hands incoming navigation intents (geo:, google.navigation:, Maps links,
 * shared text) to Dart, and exposes the APK signing fingerprint so the
 * Routes API key can be restricted to this app.
 *
 * Also drives picture-in-picture: while Dart reports an active route, leaving
 * the app shrinks it into a mini map instead of hiding it.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "cv.towtruck.pablo/intent"
    private var channel: MethodChannel? = null
    private var pending: Map<String, String?>? = null

    private val pipChannelName = "cv.towtruck.pablo/pip"
    private var pipChannel: MethodChannel? = null
    private var navigating = false

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

        val pip = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pipChannelName)
        pipChannel = pip
        pip.setMethodCallHandler { call, result ->
            when (call.method) {
                "setNavigating" -> {
                    navigating = call.arguments as? Boolean ?: false
                    updatePipParams()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasPip(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    @TargetApi(Build.VERSION_CODES.O)
    private fun buildPipParams(): PictureInPictureParams {
        val b = PictureInPictureParams.Builder().setAspectRatio(Rational(3, 4))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+: the system shrinks the app on Home/swipe by itself.
            b.setAutoEnterEnabled(navigating)
        }
        return b.build()
    }

    private fun updatePipParams() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && hasPip()) {
            try {
                setPictureInPictureParams(buildPipParams())
            } catch (e: Exception) {
            }
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 8-11 have no auto-enter, so enter manually when leaving mid-route.
        if (navigating && hasPip() &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S
        ) {
            try {
                enterPictureInPictureMode(buildPipParams())
            } catch (e: Exception) {
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("pipChanged", isInPictureInPictureMode)
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
