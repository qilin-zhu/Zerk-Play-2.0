package cloud.zerk.play

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private lateinit var videoLayer: FrameLayout
    private var player: ZerkPlayer? = null
    private var trailers: TrailerTextures? = null

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun getRenderMode(): RenderMode = RenderMode.surface

    override fun onCreate(savedInstanceState: Bundle?) {
        // On Android 6.0 the Flutter engine is out of its supported range, so
        // the first frame can fail for reasons the Dart side never sees (a
        // native symbol missing from bionic, for one). Showing it beats
        // closing silently.
        try {
            super.onCreate(savedInstanceState)
        } catch (t: Throwable) {
            BootError.show(this, "Flutter 引擎启动失败（super.onCreate）", t)
            return
        }
        try {
            boot()
        } catch (t: Throwable) {
            BootError.show(this, "播放器初始化失败", t)
        }
    }

    private fun boot() {
        val content = findViewById<FrameLayout>(android.R.id.content)
        videoLayer = FrameLayout(this).apply { visibility = android.view.View.GONE }
        content.addView(
            videoLayer, 0,
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
        )
        for (i in 0 until content.childCount) {
            if (Build.VERSION.SDK_INT >= 26) content.getChildAt(i).defaultFocusHighlightEnabled = false
        }
        player?.attach(videoLayer)
        val flutterView = (0 until content.childCount).map(content::getChildAt).filterIsInstance<FlutterView>().firstOrNull()
        val engine = flutterEngine
        if (flutterView != null && engine != null) ImeProxy.install(flutterView, engine.dartExecutor.binaryMessenger)
        if (engine != null) Updater.install(this, engine.dartExecutor.binaryMessenger)
        if (engine != null) TvHome.install(this, engine.dartExecutor.binaryMessenger)
        TvHome.onIntent(intent, running = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        TvHome.onIntent(intent, running = true)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        player = ZerkPlayer(this, flutterEngine.dartExecutor.binaryMessenger).also {
            if (::videoLayer.isInitialized) it.attach(videoLayer)
        }
        trailers = TrailerTextures(this, flutterEngine.dartExecutor.binaryMessenger, flutterEngine.renderer)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        player?.release()
        player = null
        trailers?.release()
        trailers = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onStop() {
        player?.pause()
        super.onStop()
    }
}
