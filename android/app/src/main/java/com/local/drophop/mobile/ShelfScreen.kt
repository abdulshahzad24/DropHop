package com.local.drophop.mobile

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Sensors
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch

// MARK: - Shelf

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShelfScreen(client: SyncClient) {
    val shelfItems by client.items.collectAsStateWithLifecycle()
    val groups by client.groups.collectAsStateWithLifecycle()
    val status by client.status.collectAsStateWithLifecycle()
    val progress by client.progress.collectAsStateWithLifecycle()
    val failures by client.failures.collectAsStateWithLifecycle()
    val local by client.local.collectAsStateWithLifecycle()

    var filesOnly by rememberSaveable { mutableStateOf(false) }
    var confirmUnpair by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    // Poll while the app is on screen (the iPhone app does the same while "active").
    val lifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(lifecycleOwner) {
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { client.pollLoop() }
    }

    val visible = remember(shelfItems, groups, filesOnly) {
        val ordered = groups.flatMap { g -> shelfItems.filter { it.groupId == g.id } } +
            shelfItems.filter { item -> item.groupId == null || groups.none { it.id == item.groupId } }
        if (filesOnly) ordered.filter { !it.isFolder } else ordered
    }

    fun syncNow() = scope.launch { client.refresh() }

    Box(Modifier.fillMaxSize().background(Palette.ShelfGradient)) {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Header(count = visible.size, onSync = { syncNow() }, onUnpair = { confirmUnpair = true })
            FilterBar(filesOnly = filesOnly, status = status, onFilter = { filesOnly = it }, onRefresh = { syncNow() })

            Box(Modifier.weight(1f).fillMaxWidth()) {
                if (visible.isEmpty()) {
                    EmptyState()
                } else {
                    PullToRefreshBox(
                        isRefreshing = refreshing,
                        onRefresh = {
                            scope.launch {
                                refreshing = true
                                client.refresh()
                                refreshing = false
                            }
                        },
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        LazyColumn(
                            Modifier.fillMaxSize(),
                            contentPadding = PaddingValues(start = 18.dp, end = 18.dp, top = 14.dp, bottom = 24.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            items(visible, key = { it.id }) { item ->
                                ShelfItemCard(client, item, progress[item.id], failures[item.id], local[item.id])
                            }
                        }
                    }
                }
            }
            Footer()
        }
    }

    if (confirmUnpair) {
        AlertDialog(
            onDismissRequest = { confirmUnpair = false },
            title = { Text("Unpair this phone from your computer?") },
            text = {
                Text(
                    "Files you already downloaded stay on this phone. To also revoke access on the computer, " +
                        "choose “Pair iPhone…” (Mac) or “Pair phone…” (Windows) there and tap Unpair."
                )
            },
            confirmButton = {
                TextButton(onClick = { confirmUnpair = false; client.unpair() }) {
                    Text("Unpair", color = Palette.Error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmUnpair = false }) { Text("Cancel") } },
        )
    }
}

// MARK: - Header, filters, empty state, footer

@Composable
private fun Header(count: Int, onSync: () -> Unit, onUnpair: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(start = 22.dp, end = 22.dp, top = 16.dp, bottom = 18.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text("ON THE SHELF", style = mono(12, FontWeight.Bold, 2.1f, White(0.56f)))
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                Text("$count", fontSize = 42.sp, fontWeight = FontWeight.Light, color = Color.White, lineHeight = 46.sp)
                Text(
                    if (count == 1) "item" else "items",
                    fontSize = 17.sp, color = White(0.55f),
                    modifier = Modifier.padding(bottom = 6.dp),
                )
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .height(38.dp)
                    .clip(CircleShape)
                    .background(White(0.045f))
                    .border(1.dp, White(0.13f), CircleShape)
                    .clickable(onClick = onSync)
                    .padding(horizontal = 15.dp),
                contentAlignment = Alignment.Center,
            ) { Text("SYNC", style = mono(11, FontWeight.Bold, 1.4f, Color.White)) }
            RoundButton(38, onUnpair, "Unpair") {
                Icon(Icons.Outlined.Close, null, tint = White(0.82f), modifier = Modifier.size(17.dp))
            }
        }
    }
}

@Composable
private fun FilterBar(filesOnly: Boolean, status: Status, onFilter: (Boolean) -> Unit, onRefresh: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(start = 22.dp, end = 22.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        FilterPill("ALL", selected = !filesOnly) { onFilter(false) }
        FilterPill("FILES", selected = filesOnly) { onFilter(true) }
        RoundButton(39, onRefresh, "Refresh") {
            Icon(Icons.Outlined.Refresh, null, tint = White(0.82f), modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.weight(1f))
        StatusDot(status)
    }
}

@Composable
private fun FilterPill(title: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .height(39.dp)
            .clip(CircleShape)
            .background(if (selected) Palette.Cream else Color.Transparent)
            .then(if (selected) Modifier else Modifier.border(1.dp, White(0.14f), CircleShape))
            .clickable(onClick = onClick)
            .padding(horizontal = 18.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(title, style = mono(11, FontWeight.Bold, 1.7f, if (selected) Palette.CreamInk else White(0.65f)))
    }
}

@Composable
private fun StatusDot(status: Status) {
    val (color, text) = when (status) {
        is Status.Online -> Palette.Online to status.host
        Status.Connecting -> Color(0xFFFF9500) to "Connecting"
        Status.Offline -> White(0.3f) to "Offline"
        Status.Unpaired -> White(0.3f) to "Unpaired"
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(6.dp).clip(CircleShape).background(color))
        Text(
            text.uppercase(),
            style = mono(9, FontWeight.SemiBold, 1f, White(0.45f)),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.widthIn(max = 150.dp),
        )
    }
}

@Composable
private fun EmptyState() {
    Column(
        Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Outlined.Inbox, null, tint = White(0.38f), modifier = Modifier.size(38.dp))
        Spacer(Modifier.height(12.dp))
        Text("Nothing on your shelf yet", fontSize = 17.sp, fontWeight = FontWeight.Medium, color = White(0.88f))
        Spacer(Modifier.height(12.dp))
        Text(
            "Drop a file onto the DropHop shelf on your computer and it will appear here.",
            fontSize = 13.sp, color = White(0.48f), textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 35.dp),
        )
    }
}

@Composable
private fun Footer() {
    Row(
        Modifier.fillMaxWidth().navigationBarsPadding().padding(start = 24.dp, end = 24.dp, top = 12.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        val style = mono(9, FontWeight.Medium, 2f, White(0.28f))
        Icon(Icons.Filled.Menu, null, tint = White(0.28f), modifier = Modifier.size(11.dp))
        Text("DROP HOP", style = style)
        Spacer(Modifier.weight(1f))
        Text("PULL DOWN TO SYNC", style = style.copy(letterSpacing = 1.2.sp))
        Icon(Icons.Outlined.ArrowDownward, null, tint = White(0.28f), modifier = Modifier.size(11.dp))
    }
}

@Composable
private fun RoundButton(size: Int, onClick: () -> Unit, description: String, content: @Composable () -> Unit) {
    Box(
        Modifier
            .size(size.dp)
            .clip(CircleShape)
            .background(White(0.035f))
            .border(1.dp, White(0.13f), CircleShape)
            .clickable(onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) { content() }
}

// MARK: - Shelf item card

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ShelfItemCard(
    client: SyncClient,
    item: RemoteItem,
    progress: Double?,
    failure: String?,
    local: LocalFile?,
) {
    val context = LocalContext.current
    var menu by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(27.dp)

    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(White(0.055f))
                .border(1.dp, White(0.10f), shape)
                .combinedClickable(
                    onClick = { if (local != null) openFile(context, local) else client.downloadAsync(item) },
                    onLongClick = { menu = true },
                )
                .padding(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(58.dp).clip(RoundedCornerShape(15.dp)).background(Palette.Tile),
                contentAlignment = Alignment.Center,
            ) {
                Icon(iconFor(item), null, tint = Palette.TileIcon, modifier = Modifier.size(24.dp))
            }
            Spacer(Modifier.width(13.dp))

            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    item.name, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = White(0.94f),
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                Text(sizeText(context, item), fontSize = 13.sp, fontWeight = FontWeight.Medium, color = White(0.47f))
                failure?.let { Text(it, fontSize = 12.sp, color = Palette.Error) }
            }
            Spacer(Modifier.width(4.dp))

            Trailing(client, item, progress, local)
        }

        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (local != null) {
                DropdownMenuItem(
                    text = { Text("Share") },
                    leadingIcon = { Icon(Icons.Outlined.Share, null) },
                    onClick = { menu = false; shareFile(context, local) },
                )
                DropdownMenuItem(
                    text = { Text("Remove download", color = Palette.Error) },
                    leadingIcon = { Icon(Icons.Outlined.Delete, null, tint = Palette.Error) },
                    onClick = { menu = false; client.removeLocal(item) },
                )
            } else {
                DropdownMenuItem(
                    text = { Text("Download") },
                    leadingIcon = { Icon(Icons.Outlined.Download, null) },
                    onClick = { menu = false; client.downloadAsync(item) },
                )
            }
        }
    }
}

@Composable
private fun Trailing(client: SyncClient, item: RemoteItem, progress: Double?, local: LocalFile?) {
    val context = LocalContext.current
    when {
        progress != null -> {
            if (progress <= 0.0) {
                CircularProgressIndicator(
                    Modifier.padding(end = 5.dp).size(28.dp), color = White(0.85f), strokeWidth = 2.5.dp,
                )
            } else {
                CircularProgressIndicator(
                    progress = { progress.toFloat() },
                    modifier = Modifier.padding(end = 5.dp).size(28.dp),
                    color = White(0.85f), trackColor = White(0.12f), strokeWidth = 2.5.dp,
                )
            }
        }
        local != null -> {
            Row(horizontalArrangement = Arrangement.spacedBy(13.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Sensors, null, tint = White(0.7f), modifier = Modifier.size(20.dp))
                Box(
                    Modifier.size(30.dp).clip(CircleShape).clickable { shareFile(context, local) }
                        .semantics { contentDescription = "Share" },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Outlined.Link, null, tint = Palette.Accent, modifier = Modifier.size(20.dp)) }
                RoundButton(30, { client.removeLocal(item) }, "Remove download") {
                    Icon(Icons.Outlined.Close, null, tint = White(0.68f), modifier = Modifier.size(14.dp))
                }
            }
        }
        else -> {
            Box(
                Modifier.size(36.dp).clip(CircleShape).clickable { client.downloadAsync(item) }
                    .semantics { contentDescription = "Download" },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Outlined.Download, null, tint = White(0.7f), modifier = Modifier.size(25.dp)) }
        }
    }
}
