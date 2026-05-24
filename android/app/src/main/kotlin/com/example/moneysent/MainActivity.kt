package com.example.moneysent

import android.content.Intent
import android.os.Bundle
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APP_LAUNCHER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "launchFirstInstalled" -> {
                    @Suppress("UNCHECKED_CAST")
                    val raw = call.arguments as? List<*> ?: emptyList<Any>()
                    val packages = raw.mapNotNull { it as? String }
                    for (pkg in packages) {
                        val launch = packageManager.getLaunchIntentForPackage(pkg)
                        if (launch != null) {
                            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(launch)
                            result.success(pkg)
                            return@setMethodCallHandler
                        }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        private const val APP_LAUNCHER_CHANNEL = "com.moneysent/app_launcher"
    }
}
