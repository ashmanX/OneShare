package com.example.droplan

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.WifiManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val controlChannel = "com.example.oneshare/nsd_control"
    private val eventChannel = "com.example.oneshare/nsd_events"
    private val pickerChannel = "com.example.oneshare/instant_picker"
    private val streamChannel = "com.example.oneshare/uri_stream"
    private val wifiControlChannel = "com.example.oneshare/wifi_control"
    private val wifiEventChannel = "com.example.oneshare/wifi_events"

    private lateinit var nsdHelper: NsdHelper
    private lateinit var instantPicker: InstantFilePicker
    private lateinit var uriStreamHandler: UriStreamHandler

    private var wifiEventSink: EventChannel.EventSink? = null
    private var wifiManager: WifiManager? = null
    private var wifiReceiver: BroadcastReceiver? = null
    private var isWifiReceiverRegistered = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        nsdHelper = NsdHelper(this)
        instantPicker = InstantFilePicker(this)
        uriStreamHandler = UriStreamHandler(this)

        setupWifiMonitoring(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, streamChannel)
            .setMethodCallHandler { call, result ->
                uriStreamHandler.handleMethodCall(call, result)
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pickerChannel)
            .setMethodCallHandler { call, result ->
                instantPicker.handleMethodCall(call, result)
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    nsdHelper.eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    nsdHelper.eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, controlChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startAdvertising" -> {
                        val name = call.argument<String>("deviceName") ?: "OneShare"
                        val port = call.argument<Int>("port") ?: 4040
                        nsdHelper.startAdvertising(name, port)
                        result.success(null)
                    }

                    "stopAdvertising" -> {
                        nsdHelper.stopAdvertising()
                        result.success(null)
                    }

                    "startDiscovery" -> {
                        nsdHelper.startDiscovery()
                        result.success(null)
                    }

                    "stopDiscovery" -> {
                        nsdHelper.stopDiscovery()
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun setupWifiMonitoring(flutterEngine: FlutterEngine) {
        wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, wifiControlChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "getWifiStatus") {
                    val status = isWifiEnabled()
                    Log.d("OneShare-WiFi", "Android getWifiStatus: $status")
                    result.success(status)
                } else {
                    result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, wifiEventChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    wifiEventSink = events
                    val status = isWifiEnabled()
                    Log.d("OneShare-WiFi", "Android onListen: emitting $status")
                    events?.success(status)
                }

                override fun onCancel(arguments: Any?) {
                    wifiEventSink = null
                }
            })

        wifiReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == WifiManager.WIFI_STATE_CHANGED_ACTION) {
                    val wifiState = intent.getIntExtra(WifiManager.EXTRA_WIFI_STATE, WifiManager.WIFI_STATE_UNKNOWN)
                    val isEnabled = when (wifiState) {
                        WifiManager.WIFI_STATE_ENABLED -> true
                        WifiManager.WIFI_STATE_DISABLED,
                        WifiManager.WIFI_STATE_DISABLING -> false
                        else -> isWifiEnabled()
                    }
                    Log.d("OneShare-WiFi", "Android WIFI_STATE_CHANGED_ACTION: state=$wifiState isEnabled=$isEnabled")
                    runOnUiThread {
                        wifiEventSink?.success(isEnabled)
                    }
                }
            }
        }

        try {
            val filter = IntentFilter(WifiManager.WIFI_STATE_CHANGED_ACTION)
            registerReceiver(wifiReceiver, filter)
            isWifiReceiverRegistered = true
            Log.d("OneShare-WiFi", "Android WifiReceiver registered")
        } catch (e: Exception) {
            Log.e("OneShare-WiFi", "Android failed to register WifiReceiver: ${e.message}")
        }
    }

    private fun isWifiEnabled(): Boolean {
        return try {
            wifiManager?.isWifiEnabled ?: false
        } catch (e: Exception) {
            false
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (::instantPicker.isInitialized) {
            instantPicker.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun onDestroy() {
        if (::nsdHelper.isInitialized) {
            nsdHelper.stopAdvertising()
            nsdHelper.stopDiscovery()
        }
        if (isWifiReceiverRegistered && wifiReceiver != null) {
            try {
                unregisterReceiver(wifiReceiver)
                isWifiReceiverRegistered = false
            } catch (e: Exception) {
                Log.e("OneShare-WiFi", "Failed to unregister WifiReceiver: ${e.message}")
            }
        }
        super.onDestroy()
    }
}
