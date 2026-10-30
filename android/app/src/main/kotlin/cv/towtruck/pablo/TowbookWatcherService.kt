package cv.towtruck.pablo

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.TextView

/**
 * Towbook's Navigate button hard-codes the Google Maps app, so Android never
 * offers Pablo. This service waits for Towbook's "Navigate to location" box,
 * reads its Destination line, and floats an OPEN IN PABLO button over it.
 * Tapping the button closes Towbook's box (so Maps never opens) and hands the
 * address to Pablo as a geo: link.
 */
class TowbookWatcherService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private var overlay: View? = null
    private var shownAddress: String? = null
    private val check = Runnable { runCheck() }
    private val autoHide = Runnable { hideButton() }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null || event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        if (event.packageName?.toString() == packageName) return
        // Let the window finish laying out before reading it.
        handler.removeCallbacks(check)
        handler.postDelayed(check, 150)
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        hideButton()
        super.onDestroy()
    }

    private fun runCheck() {
        val address = try {
            findDestination()
        } catch (e: Exception) {
            null
        }
        if (address != null) showButton(address) else hideButton()
    }

    private fun findDestination(): String? {
        val root = rootInActiveWindow ?: return null
        val hits = root.findAccessibilityNodeInfosByText("Navigate to location")
        if (hits.isNullOrEmpty()) return null
        val texts = ArrayList<String>()
        collectText(root, texts, 0)
        return parseDestination(texts)
    }

    private fun collectText(node: AccessibilityNodeInfo?, out: MutableList<String>, depth: Int) {
        if (node == null || depth > 40) return
        val t = node.text?.toString()
        if (!t.isNullOrBlank()) out.add(t)
        for (i in 0 until node.childCount) collectText(node.getChild(i), out, depth + 1)
    }

    private fun showButton(address: String) {
        handler.removeCallbacks(autoHide)
        handler.postDelayed(autoHide, 30_000)
        if (overlay != null && address == shownAddress) return
        hideButton()
        val dp = resources.displayMetrics.density
        val button = TextView(this).apply {
            text = "OPEN IN PABLO"
            setTextColor(Color.BLACK)
            textSize = 18f
            typeface = Typeface.DEFAULT_BOLD
            setPadding((28 * dp).toInt(), (16 * dp).toInt(), (28 * dp).toInt(), (16 * dp).toInt())
            background = GradientDrawable().apply {
                cornerRadius = 32 * dp
                setColor(Color.parseColor("#F5A623"))
            }
            elevation = 8 * dp
            setOnClickListener { openInPablo(address) }
        }
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            y = (110 * dp).toInt()
        }
        try {
            (getSystemService(WINDOW_SERVICE) as WindowManager).addView(button, lp)
            overlay = button
            shownAddress = address
        } catch (e: Exception) {
            overlay = null
            shownAddress = null
        }
    }

    private fun hideButton() {
        handler.removeCallbacks(autoHide)
        val v = overlay ?: return
        overlay = null
        shownAddress = null
        try {
            (getSystemService(WINDOW_SERVICE) as WindowManager).removeView(v)
        } catch (e: Exception) {
        }
    }

    private fun openInPablo(address: String) {
        hideButton()
        // Back = Cancel on Towbook's box, so Google Maps is never launched.
        performGlobalAction(GLOBAL_ACTION_BACK)
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=" + Uri.encode(address))).apply {
            setClass(this@TowbookWatcherService, MainActivity::class.java)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        handler.postDelayed({
            try {
                startActivity(intent)
            } catch (e: Exception) {
            }
        }, 150)
    }

    companion object {
        /** "Destination:" followed by the address, on the same line or the next. */
        fun parseDestination(texts: List<String>): String? {
            val lines = texts.flatMap { it.split('\n') }.map { it.trim() }.filter { it.isNotEmpty() }
            for (i in lines.indices) {
                if (!lines[i].startsWith("Destination", ignoreCase = true)) continue
                val rest = lines[i].substringAfter(':', "").trim()
                if (rest.isNotEmpty()) return rest
                if (i + 1 < lines.size) return lines[i + 1]
            }
            return null
        }
    }
}
