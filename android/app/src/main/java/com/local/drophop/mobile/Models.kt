package com.local.drophop.mobile

import org.json.JSONObject

data class RemoteItem(
    val id: String,
    val name: String,
    val size: Long,
    val groupId: String?,
    val isFolder: Boolean,
)

data class RemoteGroup(val id: String, val name: String)

data class RemoteManifest(val host: String, val items: List<RemoteItem>, val groups: List<RemoteGroup>)

/**
 * A computer's identity. We store this (not an IP) so we can find it again even after its address
 * changes. Computers found over Wi-Fi are identified by their mDNS service name; a computer added by
 * hand keeps the address that was typed in.
 */
data class ComputerRef(val name: String, val host: String? = null, val port: Int = 0) {
    fun toJson(): String = JSONObject().apply {
        put("name", name)
        host?.let { put("host", it); put("port", port) }
    }.toString()

    companion object {
        fun fromJson(text: String): ComputerRef? = try {
            val o = JSONObject(text)
            ComputerRef(o.getString("name"), o.optString("host").ifEmpty { null }, o.optInt("port"))
        } catch (e: Exception) {
            null
        }
    }
}

data class DiscoveredComputer(val ref: ComputerRef) {
    val id: String get() = ref.name
    val name: String get() = ref.name
}

/** Progress of files being sent from this phone to the computer. */
data class UploadState(
    val index: Int,
    val total: Int,
    val name: String,
    val fraction: Double,
    val done: Boolean = false,
    val error: String? = null,
) {
    val active: Boolean get() = !done && error == null
}

/** A file that has been downloaded to the phone's Downloads/DropHop folder. */
data class LocalFile(val name: String, val uri: String)

sealed class SyncError(message: String) : Exception(message) {
    object Unreachable : SyncError("Can't reach your computer. Make sure DropHop is running and you're on the same Wi-Fi.")
    object Unauthorized : SyncError("This phone isn't paired with that computer any more.")
    class Http(code: Int) : SyncError("The computer replied with an error ($code).")
    class Server(message: String) : SyncError(message)
}
