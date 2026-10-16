package com.local.drophop.mobile

import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle

class MainActivity : ComponentActivity() {
    private val client: SyncClient by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        setContent {
            DropHopTheme { RootScreen(client) }
        }
    }
}

@Composable
fun RootScreen(client: SyncClient) {
    val status by client.status.collectAsStateWithLifecycle()
    val notice by client.notice.collectAsStateWithLifecycle()

    if (status == Status.Unpaired) PairScreen(client) else ShelfScreen(client)

    notice?.let { message ->
        AlertDialog(
            onDismissRequest = { client.dismissNotice() },
            title = { Text("DropHop") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { client.dismissNotice() }) { Text("OK") } },
        )
    }
}
