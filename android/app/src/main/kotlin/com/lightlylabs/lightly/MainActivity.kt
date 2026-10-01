package com.lightlylabs.lightly

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lightlylabs.lightly.editor.EditorScreen
import com.lightlylabs.lightly.editor.EditorViewModel
import com.lightlylabs.lightly.model.BasisRegistry
import com.lightlylabs.lightly.model.RegistryAutoLutResolver

class MainActivity : ComponentActivity() {
    // No basis LUTs ship in M2: the only basis is the research (FiveK) one, which must not be bundled
    // (docs/m1/licensing.md). With an empty registry every Auto result reports "unavailable", which
    // is the honest state until the licensed model (U1) is packaged with its pinned sha256.
    private val autoResolver = RegistryAutoLutResolver(BasisRegistry(installed = emptyList()))

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface {
                    val editor: EditorViewModel = viewModel(factory = EditorViewModel.factory(autoResolver))
                    EditorScreen(editor)
                }
            }
        }
    }
}
