package com.local.drophop.mobile

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

private const val SERVICE_TYPE = "_drophop._tcp"

/** Finds computers running DropHop on the local network (Mac or Windows). */
class ComputerBrowser(context: Context) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val _computers = MutableStateFlow<List<DiscoveredComputer>>(emptyList())
    val computers: StateFlow<List<DiscoveredComputer>> = _computers

    private var listener: NsdManager.DiscoveryListener? = null

    fun start() {
        stop()
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}

            override fun onServiceFound(info: NsdServiceInfo) {
                if (!info.serviceType.contains("_drophop")) return
                val found = DiscoveredComputer(ComputerRef(info.serviceName))
                _computers.value = (_computers.value + found).distinctBy { it.name }.sortedBy { it.name }
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                _computers.value = _computers.value.filterNot { it.name == info.serviceName }
            }
        }
        listener = l
        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: Exception) {
            listener = null
        }
    }

    fun stop() {
        listener?.let { try { nsd.stopServiceDiscovery(it) } catch (e: Exception) { } }
        listener = null
    }
}

/**
 * Turns a computer into a base URL such as http://192.168.1.20:51234.
 * HTTP clients can't talk to a service name directly, so (like the iPhone app) we look the service
 * up on the network, take the IPv4 address it resolved to, and use that.
 */
object Resolver {
    private val lock = Mutex()   // Android resolves one service at a time

    suspend fun baseUrl(context: Context, ref: ComputerRef, timeoutMs: Long = 8000): String {
        if (ref.host != null) return "http://${ref.host}:${ref.port}"
        val result = withTimeoutOrNull(timeoutMs) { lock.withLock { findAndResolve(context, ref.name) } }
        return result ?: throw SyncError.Unreachable
    }

    @Suppress("DEPRECATION")
    private suspend fun findAndResolve(context: Context, name: String): String? =
        suspendCancellableCoroutine { cont ->
            val nsd = context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
            val done = AtomicBoolean(false)
            var discovery: NsdManager.DiscoveryListener? = null

            fun finish(url: String?, error: Throwable? = null) {
                if (!done.compareAndSet(false, true)) return
                discovery?.let { try { nsd.stopServiceDiscovery(it) } catch (e: Exception) { } }
                if (error != null) cont.resumeWithException(error) else cont.resume(url)
            }

            val resolveListener = object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) = finish(null, SyncError.Unreachable)
                override fun onServiceResolved(info: NsdServiceInfo) {
                    val address: InetAddress? =
                        if (Build.VERSION.SDK_INT >= 34) {
                            info.hostAddresses.firstOrNull { it is Inet4Address } ?: info.hostAddresses.firstOrNull() ?: info.host
                        } else info.host
                    val ip = (address as? Inet4Address)?.hostAddress
                    finish(if (ip != null) "http://$ip:${info.port}" else null)
                }
            }

            val l = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) {}
                override fun onDiscoveryStopped(serviceType: String) {}
                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = finish(null, SyncError.Unreachable)
                override fun onServiceLost(info: NsdServiceInfo) {}
                override fun onServiceFound(info: NsdServiceInfo) {
                    if (info.serviceName != name || done.get()) return
                    try { nsd.resolveService(info, resolveListener) } catch (e: Exception) { finish(null, SyncError.Unreachable) }
                }
            }
            discovery = l
            cont.invokeOnCancellation {
                if (done.compareAndSet(false, true)) {
                    try { nsd.stopServiceDiscovery(l) } catch (e: Exception) { }
                }
            }
            try {
                nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                finish(null, SyncError.Unreachable)
            }
        }
}
