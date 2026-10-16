package com.local.drophop.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

// MARK: - Pairing

@Composable
fun PairScreen(client: SyncClient) {
    val context = LocalContext.current
    val browser = remember { ComputerBrowser(context.applicationContext) }
    DisposableEffect(browser) {
        browser.start()
        onDispose { browser.stop() }
    }
    val computers by browser.computers.collectAsStateWithLifecycle()
    var selected by remember { mutableStateOf<DiscoveredComputer?>(null) }
    var manual by remember { mutableStateOf(false) }

    val card = RoundedRectangle(16)

    Column(
        Modifier
            .fillMaxSize()
            .background(androidx.compose.ui.graphics.Color(0.075f, 0.065f, 0.06f))
            .statusBarsPadding()
            .navigationBarsPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
    ) {
        Spacer(Modifier.height(56.dp))
        Text("Connect to your computer", fontSize = 32.sp, fontWeight = FontWeight.Bold, color = androidx.compose.ui.graphics.Color.White)
        Spacer(Modifier.height(28.dp))

        Text(
            "YOUR COMPUTERS",
            style = mono(11, FontWeight.Medium, 1.2f, White(0.5f)),
            modifier = Modifier.padding(start = 16.dp, bottom = 8.dp),
        )
        Column(Modifier.fillMaxWidth().background(White(0.07f), card)) {
            if (computers.isEmpty()) {
                Row(
                    Modifier.fillMaxWidth().padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = White(0.7f))
                    Text("Looking for DropHop on your Wi-Fi…", color = White(0.6f), fontSize = 16.sp)
                }
            }
            computers.forEachIndexed { index, computer ->
                if (index > 0) HorizontalDivider(color = White(0.08f))
                ComputerRow(computer.name) { selected = computer }
            }
            if (computers.isNotEmpty()) HorizontalDivider(color = White(0.08f))
            Row(
                Modifier.fillMaxWidth().clickable { manual = true }.padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Icon(Icons.Outlined.Edit, null, tint = White(0.6f), modifier = Modifier.size(22.dp))
                Text("Enter address manually", color = White(0.75f), fontSize = 16.sp)
            }
        }

        Text(
            "On your computer, click the DropHop icon (menu bar on a Mac, system tray on Windows) and choose " +
                "“Pair iPhone…” or “Pair phone…”. Then pick that computer here and type the code it shows.",
            color = White(0.5f),
            fontSize = 13.sp,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 32.dp),
        )
    }

    selected?.let { computer ->
        CodeEntrySheet(client, title = computer.name, ref = computer.ref, manual = false, onDismiss = { selected = null })
    }
    if (manual) {
        CodeEntrySheet(client, title = "your computer", ref = null, manual = true, onDismiss = { manual = false })
    }
}

@Composable
private fun ComputerRow(name: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Icon(Icons.Outlined.Computer, null, tint = Palette.Accent, modifier = Modifier.size(24.dp))
        Text(name, color = androidx.compose.ui.graphics.Color.White, fontSize = 16.sp)
    }
}

private fun RoundedRectangle(radius: Int) = RoundedCornerShape(radius.dp)

// MARK: - Code entry

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CodeEntrySheet(
    client: SyncClient,
    title: String,
    ref: ComputerRef?,
    manual: Boolean,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var address by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = androidx.compose.ui.graphics.Color(0.12f, 0.105f, 0.095f),
    ) {
        Column(
            Modifier.fillMaxWidth().imePadding().navigationBarsPadding().padding(horizontal = 24.dp).padding(bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                if (manual) "Pair with a computer" else "Pair with $title",
                fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = androidx.compose.ui.graphics.Color.White,
            )

            if (manual) {
                OutlinedTextField(
                    value = address,
                    onValueChange = { address = it.trim() },
                    label = { Text("Address, e.g. 192.168.1.20:51234") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    "The address is shown in the pairing window on your computer.",
                    color = White(0.5f), fontSize = 13.sp,
                )
            }

            OutlinedTextField(
                value = code,
                onValueChange = { new -> code = new.filter { it.isDigit() }.take(6) },
                label = { Text("6-digit code") },
                singleLine = true,
                textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 28.sp),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                modifier = Modifier.fillMaxWidth(),
            )
            if (!manual) {
                Text("The code is shown on $title.", color = White(0.5f), fontSize = 13.sp)
            }

            errorText?.let { Text(it, color = Palette.Error, fontSize = 14.sp) }

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onDismiss) { Text("Cancel", color = White(0.7f)) }
                if (busy) {
                    CircularProgressIndicator(Modifier.padding(horizontal = 16.dp).size(22.dp), strokeWidth = 2.dp)
                } else {
                    TextButton(
                        enabled = code.length == 6 && (!manual || address.isNotEmpty()),
                        onClick = {
                            scope.launch {
                                busy = true
                                errorText = null
                                try {
                                    val target = if (manual) parseAddress(address) else ref!!
                                    client.pair(target, code)
                                    onDismiss()
                                } catch (e: CancellationException) {
                                    throw e
                                } catch (e: Exception) {
                                    errorText = e.message ?: "Pairing failed."
                                    busy = false
                                }
                            }
                        },
                    ) { Text("Pair", fontWeight = FontWeight.SemiBold) }
                }
            }
        }
    }
}

private fun parseAddress(text: String): ComputerRef {
    val clean = text.removePrefix("http://").trimEnd('/')
    val host = clean.substringBefore(':')
    val port = clean.substringAfter(':', "").toIntOrNull()
    if (host.isEmpty() || port == null || port !in 1..65535)
        throw SyncError.Server("Type the address like 192.168.1.20:51234.")
    return ComputerRef(name = host, host = host, port = port)
}
