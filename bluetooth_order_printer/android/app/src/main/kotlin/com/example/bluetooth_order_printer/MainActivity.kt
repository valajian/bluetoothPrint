package com.example.bluetooth_order_printer

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.ContentValues
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: FlutterActivity() {

    private lateinit var channel: MethodChannel
    private val bluetoothMgr = BluetoothManager()
    private val SPP_UUID = "00001101-0000-1000-8000-00805F9B34FB"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 注册蓝牙打印插件
        flutterEngine.plugins.add(BluetoothOrderPlugin())

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "com.example.bluetooth_order_printer/bluetooth")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isConnected" -> result.success(bluetoothMgr.isConnected)
                "connect" -> {
                    val mac = call.argument<String>("mac") ?: ""
                    connectAndSave(mac, result)
                }
                "disconnect" -> {
                    bluetoothMgr.disconnect()
                    result.success(null)
                }
                "startScan" -> startScan(result)
                "stopScan" -> stopScan()
                "sendData" -> {
                    val data = call.argument<String>("data") ?: ""
                    sendData(data, result)
                }
                "sendBytes" -> {
                    val bytes = call.argument<ByteArray>("bytes") ?: byteArrayOf()
                    sendBytes(bytes, result)
                }
                "getPairedDevices" -> {
                    val devices = bluetoothMgr.scanPairedDevices()
                    result.success(devices)
                }
                "saveCsvFile" -> {
                    val name = call.argument<String>("name") ?: "export.csv"
                    val content = call.argument<String>("content") ?: ""
                    saveCsvFile(name, content, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 新设备发现广播接收器
     * ACTION_FOUND: 发现新设备 → 推送给 Flutter
     * ACTION_DISCOVERY_FINISHED: 扫描结束 → 通知 Flutter 停止 loading
     */
    private val discoveryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                BluetoothDevice.ACTION_FOUND -> {
                    val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33) {
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                    }
                    if (device != null) {
                        val info = mapOf(
                            "name" to safeDeviceName(device),
                            "address" to device.address,
                            "type" to "discovered"
                        )
                        Handler(Looper.getMainLooper()).post {
                            channel.invokeMethod("onDeviceFound", info)
                        }
                    }
                }
                BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                    try { unregisterReceiver(this) } catch (_: Exception) {}
                    Handler(Looper.getMainLooper()).post {
                        channel.invokeMethod("onScanFinished", null)
                    }
                }
            }
        }
    }

    /**
     * 读取设备名（Android 12+ 需要 BLUETOOTH_CONNECT 权限，缺失时返回占位名）
     */
    private fun safeDeviceName(device: BluetoothDevice): String {
        return try {
            device.name ?: "未知设备"
        } catch (_: SecurityException) {
            "未知设备"
        }
    }

    /**
     * 启动真实蓝牙发现（扫描未配对的新设备），结果通过广播推送给 Flutter
     */
    private fun startDiscovery() {
        val bt = bluetoothMgr.btAdapter ?: return
        try {
            if (bt.isDiscovering) bt.cancelDiscovery()
            val filter = IntentFilter(BluetoothDevice.ACTION_FOUND).apply {
                addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
            }
            ContextCompat.registerReceiver(this, discoveryReceiver, filter,
                ContextCompat.RECEIVER_NOT_EXPORTED)
            bt.startDiscovery()
            // 10 秒兜底：防止个别机型 discovery 不结束导致 Flutter 一直转圈
            Handler(Looper.getMainLooper()).postDelayed({
                if (bt.isDiscovering) bt.cancelDiscovery()
            }, 10000)
        } catch (_: Exception) {
            Handler(Looper.getMainLooper()).post {
                channel.invokeMethod("onScanFinished", null)
            }
        }
    }

    private fun connectAndSave(mac: String, result: MethodChannel.Result) {
        if (!checkPermissions()) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_CONNECT,
                    Manifest.permission.ACCESS_FINE_LOCATION
                ),
                REQUEST_BLUETOOTH_PERMISSIONS
            )
            result.success(false)
            return
        }
        bluetoothMgr.connect(mac, SPP_UUID) { connected ->
            if (connected) {
                val prefs = getSharedPreferences("app_prefs", Context.MODE_PRIVATE)
                prefs.edit().putString("last_mac", mac).apply()
                Handler(Looper.getMainLooper()).post { result.success(true) }
            } else {
                Handler(Looper.getMainLooper()).post { result.success(false) }
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_BLUETOOTH_PERMISSIONS) {
            val allGranted = grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            if (allGranted) {
                val prefs = getSharedPreferences("app_prefs", Context.MODE_PRIVATE)
                val mac = prefs.getString("last_mac", "") ?: ""
                if (mac.isNotEmpty()) {
                    bluetoothMgr.connect(mac, SPP_UUID) { connected ->
                        if (connected) {
                            Handler(Looper.getMainLooper()).post {
                                channel.invokeMethod("onConnected", null)
                            }
                        }
                    }
                }
            }
        } else if (requestCode == REQUEST_SCAN_PERMISSIONS) {
            val allGranted = grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            if (allGranted) {
                // 授权后自动重新扫描一次，无需用户再点一次按钮
                Handler(Looper.getMainLooper()).postDelayed({
                    val devices = bluetoothMgr.scanPairedDevices()
                    channel.invokeMethod("onScanResult", devices)
                    startDiscovery()
                }, 300)
            }
        }
    }

    private fun checkPermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val scanOk = ContextCompat.checkSelfPermission(this,
                Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
            val connectOk = ContextCompat.checkSelfPermission(this,
                Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
            scanOk && connectOk
        } else {
            ContextCompat.checkSelfPermission(this,
                Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun startScan(result: MethodChannel.Result) {
        if (!checkPermissions()) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_CONNECT,
                    Manifest.permission.ACCESS_FINE_LOCATION),
                REQUEST_SCAN_PERMISSIONS
            )
            // 权限未授予，先返回空列表；授予后原生会自动重扫并推送 onScanResult
            result.success(emptyList<Map<String, Any>>())
            return
        }
        val devices = bluetoothMgr.scanPairedDevices()
        result.success(devices)
        startDiscovery()
    }

    private fun stopScan() {
        bluetoothMgr.stopScan()
    }

    /**
     * 保存 CSV 统计文件到手机"下载"目录
     * Android 10+ (API 29+)：MediaStore.Downloads，无需任何权限
     * Android 9 及以下：保存到应用专属目录（无需权限）
     */
    private fun saveCsvFile(fileName: String, content: String, result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val resolver = contentResolver
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    put(MediaStore.MediaColumns.MIME_TYPE, "text/csv")
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: throw Exception("无法在下载目录创建文件")
                resolver.openOutputStream(uri)?.use { out ->
                    out.write(content.toByteArray(Charsets.UTF_8))
                } ?: throw Exception("无法写入文件")
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                Handler(Looper.getMainLooper()).post {
                    result.success("已保存到 下载/$fileName")
                }
            } else {
                val dir = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                val file = File(dir, fileName)
                file.writeText(content, Charsets.UTF_8)
                Handler(Looper.getMainLooper()).post {
                    result.success("已保存到 ${file.absolutePath}")
                }
            }
        } catch (e: Exception) {
            Handler(Looper.getMainLooper()).post {
                result.success("保存失败: ${e.message ?: e.javaClass.simpleName}")
            }
        }
    }

    private fun sendData(data: String, result: MethodChannel.Result) {
        // GB2312/GBK 编码转换：将 UTF-8 字符串转为 GBK 字节
        val gb2312Bytes = bluetoothMgr.encodeToGB2312(data)
        // 蓝牙写流可能阻塞（打印机处理慢或链路异常），放到子线程执行，避免卡住主线程
        Thread {
            val ok = bluetoothMgr.sendData(gb2312Bytes)
            Handler(Looper.getMainLooper()).post { result.success(ok) }
        }.start()
    }

    private fun sendBytes(bytes: ByteArray, result: MethodChannel.Result) {
        Thread {
            val ok = bluetoothMgr.sendData(bytes)
            Handler(Looper.getMainLooper()).post { result.success(ok) }
        }.start()
    }

    companion object {
        private const val REQUEST_BLUETOOTH_PERMISSIONS = 1001
        private const val REQUEST_SCAN_PERMISSIONS = 1002
    }
}

/**
 * 经典蓝牙 SPP 管理器
 *
 * 核心功能：
 * 1. 扫描并列出已配对经典蓝牙设备
 * 2. 通过 RFCOMM SPP 连接到精臣B3打印机
 * 3. 将 TSPL 指令以 GB2312/GBK 编码发送给打印机
 *
 * 注意：flutter_blue_plus 仅支持 BLE，经典蓝牙必须通过 Android 原生 API 实现
 */
class BluetoothManager {
    private var adapter: BluetoothAdapter? = null
    private var mmSocket: BluetoothSocket? = null
    private var isConnectedFlag = false
    private var connectCallback: ((Boolean) -> Unit)? = null

    init {
        adapter = BluetoothAdapter.getDefaultAdapter()
    }

    val isConnected: Boolean get() = isConnectedFlag

    /**
     * 供 MainActivity 启动 discovery 使用
     */
    val btAdapter: BluetoothAdapter? get() = adapter

    /**
     * 扫描所有已配对（bonded）的经典蓝牙设备
     * 精臣B3 设备名一般以 "B3_" 开头
     *
     * 注意：很多打印机配对后 getType() 返回 UNKNOWN(0) 而不是 CLASSIC，
     * 因此只排除明确的纯 BLE 设备，UNKNOWN/CLASSIC/DUAL 全部保留。
     */
    fun scanPairedDevices(): List<Map<String, Any>> {
        val result = mutableListOf<Map<String, Any>>()
        val btAdapter = adapter
        if (btAdapter == null || !btAdapter.isEnabled) return result

        val devices = try {
            btAdapter.bondedDevices
        } catch (_: SecurityException) {
            // Android 12+ 缺少 BLUETOOTH_CONNECT 权限时抛 SecurityException
            return result
        }
        for (device in devices) {
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
                when (device.type) {
                    BluetoothDevice.DEVICE_TYPE_CLASSIC -> "classic"
                    BluetoothDevice.DEVICE_TYPE_DUAL -> "dual"
                    BluetoothDevice.DEVICE_TYPE_LE -> "ble"
                    else -> "unknown"
                }
            } else "classic"

            // 只排除明确的纯 BLE 设备（耳机/手环等）；unknown 类型可能是打印机，必须保留
            if (type != "ble") {
                val name = try {
                    device.name ?: "未知设备"
                } catch (_: SecurityException) {
                    "未知设备"
                }
                result.add(mapOf(
                    "name" to name,
                    "address" to device.address,
                    "type" to type
                ))
            }
        }
        return result
    }

    /**
     * 通过 RFCOMM SPP 连接到指定 MAC 地址的设备
     * UUID: 00001101-0000-1000-8000-00805F9B34FB
     */
    fun connect(mac: String, uuid: String, callback: (Boolean) -> Unit) {
        // 先关闭上一次可能残留的连接，否则旧 socket 占用 RFCOMM 通道会导致新连接失败
        disconnect()
        connectCallback = callback
        val device = adapter?.getRemoteDevice(mac)
        if (device == null) {
            callback(false)
            return
        }
        try {
            // 创建非验证的 RFCOMM SPP Socket（跳过配对认证）
            mmSocket = device.createInsecureRfcommSocketToServiceRecord(
                java.util.UUID.fromString(uuid))
            // 停止扫描避免干扰
            adapter?.cancelDiscovery()
            // 发起连接（阻塞，需要在新线程中执行）
            Thread {
                try {
                    mmSocket?.connect()
                    if (mmSocket?.isConnected == true) {
                        isConnectedFlag = true
                        callback(true)
                    } else {
                        callback(false)
                    }
                } catch (e: Exception) {
                    isConnectedFlag = false
                    callback(false)
                }
            }.start()
        } catch (e: Exception) {
            isConnectedFlag = false
            callback(false)
        }
    }

    fun disconnect() {
        try { mmSocket?.close() } catch (_: Exception) {}
        mmSocket = null
        isConnectedFlag = false
    }

    /**
     * 发送原始字节数据到 SPP 输出流
     * 返回值：true=成功；String=失败原因（透传给 Flutter 显示，便于排查）
     */
    fun sendData(bytes: ByteArray): Any {
        if (!isConnectedFlag || mmSocket == null) return "未连接（isConnected=false）"
        return try {
            val out = mmSocket?.outputStream ?: return "输出流为空"
            // 一次性写入：测试页（~150字节）验证 MPT-II 可直接接收完整数据包。
            // 此前 256 字节分块 + 10ms 间隔在本机上可能造成数据丢失（小票无输出）。
            out.write(bytes)
            out.flush()
            true
        } catch (e: Exception) {
            // 写入失败说明链路已断，清理 socket，避免残留连接影响后续重连
            isConnectedFlag = false
            try { mmSocket?.close() } catch (_: Exception) {}
            mmSocket = null
            "写入异常: ${e.message ?: e.javaClass.simpleName}"
        }
    }

    /**
     * 将 UTF-8 字符串转换为 GB2312/GBK 字节数组
     * 精臣B3 打印机只识别 GB2312 编码的中文字符
     * Java 的 "GBK" Charset 完全兼容 GB2312
     */
    fun encodeToGB2312(text: String): ByteArray {
        return try {
            // GBK 是 GB2312 的超集，兼容所有 GB2312 字符
            text.toByteArray(charset = java.nio.charset.Charset.forName("GBK"))
        } catch (e: Exception) {
            // 极端情况回退到 UTF-8（会乱码，但不会崩溃）
            text.toByteArray(charset = java.nio.charset.StandardCharsets.UTF_8)
        }
    }

    val pairedDevices: List<Map<String, Any>> get() = scanPairedDevices()

    fun stopScan() {
        adapter?.cancelDiscovery()
    }
}