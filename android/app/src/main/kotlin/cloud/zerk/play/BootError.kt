package cloud.zerk.play

import android.app.Activity
import android.graphics.Color
import android.util.Log
import android.util.TypedValue
import android.view.ViewGroup
import android.widget.ScrollView
import android.widget.TextView
import java.io.File

/**
 * Last-resort reporter for a failure that happens before Flutter can draw.
 *
 * When the engine's library does not load, the process dies with nothing on
 * screen, which is indistinguishable from "the app just closes" on a TV with no
 * adb. Painting the stack trace (and dropping it in the app's external files
 * dir) turns that into something the user can photograph in one shot.
 */
object BootError {
    private const val TAG = "ZerkBoot"

    fun show(activity: Activity, stage: String, error: Throwable) {
        val text = buildString {
            append(stage)
            append("\n\n")
            append(Log.getStackTraceString(error))
            append("\n\n设备: Android ")
            append(android.os.Build.VERSION.RELEASE)
            append(" (API ")
            append(android.os.Build.VERSION.SDK_INT)
            append(") ")
            append(android.os.Build.MODEL)
        }
        Log.e(TAG, text)

        // getExternalFilesDir needs no permission on any release and is
        // reachable over USB, unlike the app's private storage.
        runCatching {
            val dir = activity.getExternalFilesDir(null) ?: activity.filesDir
            File(dir, "boot-error.txt").writeText(text)
        }

        runCatching {
            val view = TextView(activity).apply {
                this.text = text
                setTextColor(Color.WHITE)
                setBackgroundColor(Color.rgb(16, 16, 16))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                setPadding(64, 64, 64, 64)
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                )
            }
            activity.setContentView(ScrollView(activity).apply { addView(view) })
        }
    }
}
