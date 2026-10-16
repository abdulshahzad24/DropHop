package com.local.drophop.mobile

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.text.format.Formatter
import android.widget.Toast
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.FolderZip
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.InsertDriveFile
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.PictureAsPdf
import androidx.compose.ui.graphics.vector.ImageVector

fun iconFor(item: RemoteItem): ImageVector {
    if (item.isFolder) return Icons.Filled.Folder
    return when (item.name.substringAfterLast('.', "").lowercase()) {
        "pdf" -> Icons.Outlined.PictureAsPdf
        "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff" -> Icons.Outlined.Image
        "mov", "mp4", "m4v", "mkv", "webm" -> Icons.Outlined.Movie
        "mp3", "m4a", "wav", "aac", "flac" -> Icons.Outlined.GraphicEq
        "zip", "gz", "tar", "rar", "7z" -> Icons.Outlined.FolderZip
        "txt", "md", "rtf" -> Icons.Outlined.Description
        else -> Icons.Outlined.InsertDriveFile
    }
}

/** "1.2 MB" — decimal units, like the iPhone's ByteCountFormatter(.file). */
fun sizeText(context: Context, item: RemoteItem): String =
    Formatter.formatShortFileSize(context, item.size) + if (item.isFolder) " · folder (zip)" else ""

fun openFile(context: Context, file: LocalFile) {
    val uri = Uri.parse(file.uri)
    val intent = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(uri, mimeFor(file.name))
        clipData = ClipData.newRawUri("", uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    try {
        context.startActivity(intent)
    } catch (e: ActivityNotFoundException) {
        Toast.makeText(context, "No app on this phone can open that file.", Toast.LENGTH_SHORT).show()
    }
}

fun shareFile(context: Context, file: LocalFile) {
    val uri = Uri.parse(file.uri)
    val send = Intent(Intent.ACTION_SEND).apply {
        type = mimeFor(file.name)
        putExtra(Intent.EXTRA_STREAM, uri)
        clipData = ClipData.newRawUri("", uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(Intent.createChooser(send, null))
}
