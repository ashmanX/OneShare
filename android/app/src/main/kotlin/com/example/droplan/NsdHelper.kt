package com.example.droplan

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import java.util.LinkedList

class NsdHelper(context: Context) {
    private val applicationContext: Context = context.applicationContext

    private val nsdManager: NsdManager =
        applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager

    private val mainHandler = Handler(Looper.getMainLooper())

    private var multicastLock: WifiManager.MulticastLock? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null

    private val resolveQueue = LinkedList<NsdServiceInfo>()
    private var isResolving = false

    var eventSink: EventChannel.EventSink? = null

    companion object {
        private const val SERVICE_TYPE = "_droplan._tcp"
    }

    private fun postToMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            action()
        } else {
            mainHandler.post(action)
        }
    }

    private fun sendEvent(eventData: Map<String, Any>) {
        postToMain {
            eventSink?.success(eventData)
        }
    }

    fun startAdvertising(serviceName: String, port: Int) {
        stopAdvertising()

        val serviceInfo = NsdServiceInfo().apply {
            this.serviceName = serviceName
            this.serviceType = SERVICE_TYPE
            this.port = port
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(NsdServiceInfo: NsdServiceInfo) {
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                postToMain { registrationListener = null }
            }

            override fun onServiceUnregistered(arg0: NsdServiceInfo) {
                postToMain { registrationListener = null }
            }

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                postToMain { registrationListener = null }
            }
        }

        registrationListener = listener
        try {
            nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (_: Exception) {
            registrationListener = null
        }
    }

    fun stopAdvertising() {
        val listener = registrationListener ?: return
        registrationListener = null
        try {
            nsdManager.unregisterService(listener)
        } catch (_: Exception) {
        }
    }

    fun startDiscovery() {
        acquireMulticastLock()
        stopDiscoveryInternal()

        val listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                postToMain { stopDiscovery() }
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                postToMain { stopDiscovery() }
            }

            override fun onDiscoveryStarted(serviceType: String) {
            }

            override fun onDiscoveryStopped(serviceType: String) {
                postToMain { discoveryListener = null }
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (serviceInfo.serviceType.contains(SERVICE_TYPE)) {
                    synchronized(resolveQueue) {
                        resolveQueue.add(serviceInfo)
                    }
                    postToMain { processNextResolve() }
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                val name = serviceInfo.serviceName
                if (name != null) {
                    sendEvent(
                        mapOf(
                            "event" to "lost",
                            "serviceName" to name
                        )
                    )
                }
            }
        }

        discoveryListener = listener
        try {
            nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (_: Exception) {
            stopDiscovery()
        }
    }

    fun stopDiscovery() {
        stopDiscoveryInternal()
        releaseMulticastLock()
    }

    private fun stopDiscoveryInternal() {
        val listener = discoveryListener ?: return
        discoveryListener = null
        try {
            nsdManager.stopServiceDiscovery(listener)
        } catch (_: Exception) {
        }
        synchronized(resolveQueue) {
            resolveQueue.clear()
            isResolving = false
        }
    }

    private fun processNextResolve() {
        val nextService: NsdServiceInfo
        synchronized(resolveQueue) {
            if (isResolving || resolveQueue.isEmpty()) {
                return
            }
            isResolving = true
            nextService = resolveQueue.removeFirst()
        }

        try {
            nsdManager.resolveService(nextService, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    synchronized(resolveQueue) {
                        isResolving = false
                    }
                    postToMain { processNextResolve() }
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    val host = serviceInfo.host?.hostAddress
                    val port = serviceInfo.port
                    val name = serviceInfo.serviceName

                    if (host != null && name != null) {
                        sendEvent(
                            mapOf(
                                "event" to "resolved",
                                "serviceName" to name,
                                "host" to host,
                                "port" to port
                            )
                        )
                    }

                    synchronized(resolveQueue) {
                        isResolving = false
                    }
                    postToMain { processNextResolve() }
                }
            })
        } catch (_: Exception) {
            synchronized(resolveQueue) {
                isResolving = false
            }
            postToMain { processNextResolve() }
        }
    }

    private fun acquireMulticastLock() {
        if (multicastLock == null) {
            try {
                val wifiManager =
                    applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                multicastLock = wifiManager.createMulticastLock("DropLanMulticastLock").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.let {
                if (it.isHeld) {
                    it.release()
                }
            }
        } catch (_: Exception) {
        }
        multicastLock = null
    }
}
