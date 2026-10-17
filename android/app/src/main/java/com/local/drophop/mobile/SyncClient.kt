package com.local.drophop.mobile

import android.app.Application
import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.UUID
import kotlin.coroutines.coroutineContext

sealed interface Status {
    object Unpaired : Status
    object Connecting : Status
    data class Online(val host: String) : Status
    object Offline : Status
}

class SyncClient(app: Application) : AndroidViewModel(app) {

    private val _status = MutableStateFlow<Status>(Status.Unpaired)
    private val _items = MutableStateFlow<List<RemoteItem>>(emptyList())
    private val _groups = MutableStateFlow<List<RemoteGroup>>(emptyList())
    private val _progress = MutableStateFlow<Map<String, Double>>(emptyMap())     // items being downloaded
    private val _failures = MutableStateFlow<Map<String, String>>(emptyMap())
    private val _local = MutableStateFlow<Map<String, LocalFile>>(emptyMap())     // item id → downloaded file
    private val _notice = MutableStateFlow<String?>(null)
    private val _upload = MutableStateFlow<UploadState?>(null)                    // files being sent to the computer

    val status: StateFlow<Status> = _status
    val items: StateFlow<List<RemoteItem>> = _items
    val groups: StateFlow<List<RemoteGroup>> = _groups
    val progress: StateFlow<Map<String, Double>> = _progress
    val failures: StateFlow<Map<String, String>> = _failures
    val local: StateFlow<Map<String, LocalFile>> = _local
    val notice: StateFlow<String?> = _notice
    val upload: StateFlow<UploadState?> = _upload

    private val context get() = getApplication<Application>()
    private val prefs = app.getSharedPreferences("drophop", android.content.Context.MODE_PRIVATE)
    private var token: String? = SecureStore.get(app, "token")
    private var computer: ComputerRef? = prefs.getString("computer", null)?.let { ComputerRef.fromJson(it) }
    private var baseUrl: String? = null

    init {
        loadLocal()
        _status.value = if (token != null && computer != null) Status.Connecting else Status.Unpaired
    }

    fun dismissNotice() { _notice.value = null }

    // ---------------------------------------------------------------- Pairing

    private fun deviceName(): String =
        Settings.Global.getString(context.contentResolver, "device_name")?.takeIf { it.isNotBlank() } ?: Build.MODEL

    suspend fun pair(ref: ComputerRef, code: String) {
        val base = Resolver.baseUrl(context, ref)
        val reply = withContext(Dispatchers.IO) {
            val body = JSONObject().put("code", code).put("deviceName", deviceName()).toString()
            val conn = open("$base/v1/pair", "POST", null, 10_000).apply {
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
            try {
                conn.outputStream.use { it.write(body.toByteArray()) }
                val status = conn.responseCode
                val text = (if (status == 200) conn.inputStream else conn.errorStream)?.bufferedReader()?.readText().orEmpty()
                if (status != 200) {
                    val message = try { JSONObject(text).getString("error") } catch (e: Exception) { null }
                    throw SyncError.Server(message ?: "Pairing failed ($status).")
                }
                JSONObject(text)
            } catch (e: IOException) {
                throw SyncError.Unreachable
            } finally {
                conn.disconnect()
            }
        }

        val newToken = reply.getString("token")
        SecureStore.set(context, "token", newToken)
        prefs.edit().putString("computer", ref.toJson()).apply()
        token = newToken
        computer = ref
        baseUrl = base
        _status.value = Status.Connecting
        viewModelScope.launch { refresh() }
    }

    /** Forget the computer on this phone. (Downloaded files stay.) */
    fun unpair() {
        SecureStore.delete(context, "token")
        prefs.edit().remove("computer").apply()
        token = null
        computer = null
        baseUrl = null
        _items.value = emptyList()
        _groups.value = emptyList()
        _status.value = Status.Unpaired
    }

    // ---------------------------------------------------------------- Syncing

    suspend fun pollLoop() {
        while (coroutineContext.isActive) {
            refresh()
            pruneLocal()
            delay(3000)
        }
    }

    suspend fun refresh() {
        val ref = computer ?: return
        if (token == null) return
        try {
            if (baseUrl == null) {
                if (_status.value !is Status.Online) _status.value = Status.Connecting
                baseUrl = Resolver.baseUrl(context, ref)
            }
            val manifest = withContext(Dispatchers.IO) {
                val conn = authorized("v1/manifest", 8_000)
                try {
                    when (val code = conn.responseCode) {
                        401 -> throw SyncError.Unauthorized
                        200 -> parseManifest(conn.inputStream.bufferedReader().readText())
                        else -> throw SyncError.Http(code)
                    }
                } finally {
                    conn.disconnect()
                }
            }
            if (_items.value != manifest.items) _items.value = manifest.items
            if (_groups.value != manifest.groups) _groups.value = manifest.groups
            _status.value = Status.Online(manifest.host)
        } catch (e: CancellationException) {
            throw e
        } catch (e: SyncError.Unauthorized) {
            unpair()
            _notice.value = "That computer no longer recognises this phone. Pair again to continue."
        } catch (e: Exception) {
            baseUrl = null      // the computer's address may have changed; look it up again next time
            _status.value = Status.Offline
        }
    }

    private fun parseManifest(text: String): RemoteManifest {
        val o = JSONObject(text)
        val items = o.getJSONArray("items").let { a ->
            List(a.length()) { i ->
                val x = a.getJSONObject(i)
                RemoteItem(
                    id = x.getString("id"),
                    name = x.getString("name"),
                    size = x.getLong("size"),
                    groupId = if (x.isNull("groupID")) null else x.optString("groupID").ifEmpty { null },
                    isFolder = x.optBoolean("isFolder", false),
                )
            }
        }
        val groups = o.getJSONArray("groups").let { a ->
            List(a.length()) { i -> a.getJSONObject(i).let { RemoteGroup(it.getString("id"), it.getString("name")) } }
        }
        return RemoteManifest(o.getString("host"), items, groups)
    }

    private fun open(url: String, method: String, bearer: String?, timeoutMs: Int): HttpURLConnection {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = timeoutMs
        conn.readTimeout = timeoutMs
        conn.useCaches = false
        bearer?.let { conn.setRequestProperty("Authorization", "Bearer $it") }
        return conn
    }

    private fun authorized(path: String, timeoutMs: Int): HttpURLConnection {
        val base = baseUrl
        val t = token
        if (base == null || t == null) throw SyncError.Unreachable
        return open("$base/$path", "GET", t, timeoutMs)
    }

    // ---------------------------------------------------------------- Uploads (phone → computer)

    /** Sends the chosen files to the computer; they appear on its shelf straight away. */
    fun uploadAsync(uris: List<Uri>) {
        if (uris.isEmpty() || _upload.value?.active == true) return
        viewModelScope.launch {
            try {
                val ref = computer
                if (baseUrl == null && ref != null) baseUrl = Resolver.baseUrl(context, ref)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _upload.value = UploadState(0, uris.size, "", 0.0, error = (e as? SyncError)?.message ?: "Can't reach your computer.")
                return@launch
            }

            var failure: String? = null
            for ((i, uri) in uris.withIndex()) {
                val index = i + 1
                var name = "file"
                try {
                    val meta = withContext(Dispatchers.IO) { queryMeta(uri) }
                    name = meta.first
                    _upload.value = UploadState(index, uris.size, name, 0.0)
                    withContext(Dispatchers.IO) { sendFile(uri, name, meta.second, index, uris.size) }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: SyncError.Unauthorized) {
                    unpair()
                    _notice.value = "That computer no longer recognises this phone. Pair again to continue."
                    _upload.value = null
                    return@launch
                } catch (e: Exception) {
                    failure = name + ": " + ((e as? SyncError)?.message ?: e.localizedMessage ?: "Upload failed.")
                    break
                }
            }

            refresh()      // the file is on the computer's shelf now, so it shows up in our list too
            if (failure != null) {
                _upload.value = UploadState(0, uris.size, "", 0.0, error = failure)
            } else {
                _upload.value = UploadState(uris.size, uris.size, "", 1.0, done = true)
                delay(2500)
                if (_upload.value?.done == true) _upload.value = null
            }
        }
    }

    /** File name and size as the document provider reports them (size is -1 when unknown). */
    private fun queryMeta(uri: Uri): Pair<String, Long> {
        var name: String? = null
        var size = -1L
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val z = c.getColumnIndex(OpenableColumns.SIZE)
                if (n >= 0 && !c.isNull(n)) name = c.getString(n)
                if (z >= 0 && !c.isNull(z)) size = c.getLong(z)
            }
        }
        return (name ?: uri.lastPathSegment ?: "file") to size
    }

    private fun sendFile(uri: Uri, name: String, reportedSize: Long, index: Int, total: Int) {
        val base = baseUrl ?: throw SyncError.Unreachable
        val t = token ?: throw SyncError.Unreachable
        val resolver = context.contentResolver
        var staged: File? = null
        var size = reportedSize
        try {
            if (size < 0) {
                // The provider didn't say how big the file is, and the computer needs to know: copy it first.
                val tmp = File(context.cacheDir, "up-" + UUID.randomUUID())
                (resolver.openInputStream(uri) ?: throw IOException("Couldn't read that file.")).use { i ->
                    tmp.outputStream().use { o -> i.copyTo(o) }
                }
                staged = tmp
                size = tmp.length()
            }
            val input: InputStream = staged?.inputStream()
                ?: resolver.openInputStream(uri)
                ?: throw IOException("Couldn't read that file.")

            val encoded = URLEncoder.encode(name, "UTF-8").replace("+", "%20")
            val conn = open("$base/v1/upload?name=$encoded", "PUT", t, 60_000).apply {
                doOutput = true
                setFixedLengthStreamingMode(size)
                setRequestProperty("Content-Type", "application/octet-stream")
            }
            try {
                var done = 0L
                var lastReported = 0.0
                input.use { src ->
                    conn.outputStream.use { out ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            val n = src.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            done += n
                            if (size > 0) {
                                val p = done.toDouble() / size
                                if (p - lastReported >= 0.01) {
                                    lastReported = p
                                    _upload.value = UploadState(index, total, name, p)
                                }
                            }
                        }
                    }
                }
                when (val code = conn.responseCode) {
                    200 -> {}
                    401 -> throw SyncError.Unauthorized
                    else -> {
                        val text = conn.errorStream?.bufferedReader()?.readText().orEmpty()
                        val message = try { JSONObject(text).getString("error") } catch (e: Exception) { null }
                        throw SyncError.Server(message ?: "The computer replied with an error ($code).")
                    }
                }
            } catch (e: IOException) {
                throw SyncError.Unreachable
            } finally {
                conn.disconnect()
            }
        } finally {
            staged?.delete()
        }
    }

    // ---------------------------------------------------------------- Downloads

    fun downloadAsync(item: RemoteItem) {
        viewModelScope.launch { download(item) }
    }

    private suspend fun download(item: RemoteItem) {
        if (_progress.value.containsKey(item.id)) return
        setProgress(item.id, 0.0)
        _failures.update { it - item.id }
        try {
            val ref = computer
            if (baseUrl == null && ref != null) baseUrl = Resolver.baseUrl(context, ref)
            val staged = withContext(Dispatchers.IO) { fetchToCache(item) }
            val saved = withContext(Dispatchers.IO) { saveToDownloads(item.name, staged) }
            _local.update { it + (item.id to saved) }
            saveLocal()
        } catch (e: CancellationException) {
            throw e
        } catch (e: SyncError.Unauthorized) {
            unpair()
            _notice.value = "That computer no longer recognises this phone. Pair again to continue."
        } catch (e: Exception) {
            val message = (e as? SyncError)?.message ?: e.localizedMessage ?: "Download failed."
            _failures.update { it + (item.id to message) }
        } finally {
            _progress.update { it - item.id }
        }
    }

    private fun setProgress(id: String, value: Double) {
        _progress.update { if (it.containsKey(id) || value == 0.0) it + (id to value) else it }
    }

    private fun fetchToCache(item: RemoteItem): File {
        // a big folder can take a while to zip on the computer, hence the long timeout
        val conn = authorized("v1/files/${item.id}", 300_000)
        val tmp = File(context.cacheDir, "dl-" + UUID.randomUUID())
        try {
            when (val code = conn.responseCode) {
                200 -> {}
                401 -> throw SyncError.Unauthorized
                else -> throw SyncError.Http(code)
            }
            val total = conn.contentLengthLong
            var done = 0L
            var lastReported = 0.0
            conn.inputStream.use { input ->
                tmp.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        done += n
                        if (total > 0) {
                            val p = done.toDouble() / total
                            if (p - lastReported >= 0.01) { lastReported = p; setProgress(item.id, p) }
                        }
                    }
                }
            }
            return tmp
        } catch (e: Exception) {
            tmp.delete()
            throw if (e is IOException) SyncError.Unreachable else e
        } finally {
            conn.disconnect()
        }
    }

    /** Puts the file into Downloads/DropHop, where the Files app and other apps can see it. */
    private fun saveToDownloads(name: String, staged: File): LocalFile {
        val resolver = context.contentResolver
        val safe = name.substringAfterLast('/').substringAfterLast('\\')      // never let a name escape the folder
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, safe)
            put(MediaStore.Downloads.MIME_TYPE, mimeFor(safe))
            put(MediaStore.Downloads.RELATIVE_PATH, "Download/DropHop")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IOException("Couldn't create the file in Downloads.")
        try {
            resolver.openOutputStream(uri)!!.use { out -> staged.inputStream().use { it.copyTo(out) } }
            resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        } finally {
            staged.delete()
        }
        // Android renames duplicates ("name (1).pdf"); show the real name.
        val finalName = resolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: safe
        return LocalFile(finalName, uri.toString())
    }

    fun removeLocal(item: RemoteItem) {
        val file = _local.value[item.id] ?: return
        _local.update { it - item.id }
        saveLocal()
        viewModelScope.launch(Dispatchers.IO) {
            try { context.contentResolver.delete(android.net.Uri.parse(file.uri), null, null) } catch (e: Exception) { }
        }
    }

    /** Forget downloads the user deleted outside the app. */
    private suspend fun pruneLocal() {
        val current = _local.value
        if (current.isEmpty()) return
        val gone = withContext(Dispatchers.IO) {
            current.filter { (_, f) ->
                try {
                    context.contentResolver.query(android.net.Uri.parse(f.uri), arrayOf(MediaStore.Downloads._ID), null, null, null)
                        ?.use { it.count == 0 } ?: true
                } catch (e: SecurityException) {
                    false
                } catch (e: Exception) {
                    true
                }
            }.keys
        }
        if (gone.isNotEmpty()) {
            _local.update { it - gone }
            saveLocal()
        }
    }

    private fun saveLocal() {
        val o = JSONObject()
        _local.value.forEach { (id, f) -> o.put(id, JSONObject().put("name", f.name).put("uri", f.uri)) }
        prefs.edit().putString("local", o.toString()).apply()
    }

    private fun loadLocal() {
        val text = prefs.getString("local", null) ?: return
        try {
            val o = JSONObject(text)
            _local.value = o.keys().asSequence().associateWith { id ->
                o.getJSONObject(id).let { LocalFile(it.getString("name"), it.getString("uri")) }
            }
        } catch (e: Exception) { }
    }
}

fun mimeFor(name: String): String {
    val ext = name.substringAfterLast('.', "").lowercase()
    return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
}
