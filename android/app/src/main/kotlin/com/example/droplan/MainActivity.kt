package com.example.droplan

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val controlChannel = "com.example.droplan/nsd_control"
    private val eventChannel = "com.example.droplan/nsd_events"
    private val pickerChannel = "com.example.droplan/instant_picker"
    private val streamChannel = "com.example.droplan/uri_stream"

    private lateinit var nsdHelper: NsdHelper
    private lateinit var instantPicker: InstantFilePicker
    private lateinit var uriStreamHandler: UriStreamHandler

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        nsdHelper = NsdHelper(this)
        instantPicker = InstantFilePicker(this)
        uriStreamHandler = UriStreamHandler(this)

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
        super.onDestroy()
    }
}
