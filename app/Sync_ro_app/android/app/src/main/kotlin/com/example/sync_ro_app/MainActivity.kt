package com.example.sync_ro_app

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.os.Bundle
import com.example.sync_ro_app.widget.MemoWidgetProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var pendingTab: Int = -1
    private var pendingQuickCapture: Boolean = false
    private var channel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingTab = intent?.getIntExtra(EXTRA_OPEN_TAB, -1) ?: -1
        pendingQuickCapture =
            intent?.getBooleanExtra(EXTRA_QUICK_CAPTURE, false) ?: false
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                // 앱을 새로 켰을 때 위젯이 요청한 탭을 한 번만 돌려줘요.
                "consumeLaunchTab" -> {
                    val tab = pendingTab
                    pendingTab = -1
                    result.success(if (tab >= 0) tab else null)
                }
                "consumeQuickCapture" -> {
                    val quickCapture = pendingQuickCapture
                    pendingQuickCapture = false
                    result.success(quickCapture)
                }
                "refreshWidget" -> {
                    MemoWidgetProvider.refreshAll(this)
                    result.success(true)
                }
                "requestPinWidget" -> result.success(requestPinWidget())
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val tab = intent.getIntExtra(EXTRA_OPEN_TAB, -1)
        if (tab >= 0) {
            val current = channel
            if (current != null) {
                current.invokeMethod("openTab", tab)
            } else {
                pendingTab = tab
            }
        }
        val quickCapture = intent.getBooleanExtra(EXTRA_QUICK_CAPTURE, false)
        if (quickCapture) {
            val current = channel
            if (current != null) {
                current.invokeMethod("openQuickCapture", null)
            } else {
                pendingQuickCapture = true
            }
        }
    }

    /** 안드로이드 8.0(API 26)+ 에서만 '위젯 추가' 확인 창을 띄울 수 있어요. */
    private fun requestPinWidget(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val manager = AppWidgetManager.getInstance(this)
        if (!manager.isRequestPinAppWidgetSupported) return false
        val provider = ComponentName(this, MemoWidgetProvider::class.java)
        return manager.requestPinAppWidget(provider, null, null)
    }

    companion object {
        const val CHANNEL = "sync_ro/home_widget"
        const val EXTRA_OPEN_TAB = "open_tab"
        const val EXTRA_QUICK_CAPTURE = "quick_capture"
    }
}
