package com.example.bluetooth_order_printer

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter 插件 — GB2312 编码转换
 *
 * 用途：在 Flutter 侧直接调用 native 编码，用于验证和备用
 * 主要编码逻辑已在 MainActivity 的 BluetoothManager 中实现
 */
class BluetoothOrderPlugin : FlutterPlugin {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger,
            "com.example.bluetooth_order_printer/encoding")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "encodeGB2312" -> {
                    val text = call.argument<String>("text") ?: ""
                    val mgr = BluetoothManager()
                    val bytes = mgr.encodeToGB2312(text)
                    result.success(bytes.toList())
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}
