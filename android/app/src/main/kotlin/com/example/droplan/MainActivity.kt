package com.example.droplan

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val controlChannel = "com.example.droplan/nsd_control"
    private val eventChannel = "com.example.droplan/nsd_events"

    private lateinit var nsdHelper: NsdHelper

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        nsdHelper = NsdHelper(this)

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
                        val name = call.argument<String>("deviceName") ?: "DropLAN"
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

    override fun onDestroy() {
        if (::nsdHelper.isInitialized) {
            nsdHelper.stopAdvertising()
            nsdHelper.stopDiscovery()
        }
        super.onDestroy()
    }
}
