package com.lightlylabs.lightly

import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lightlylabs.lightly.editor.AndroidEditorEnvironment
import com.lightlylabs.lightly.editor.EditorEnvironment
import com.lightlylabs.lightly.editor.EditorScreen
import com.lightlylabs.lightly.editor.EditorViewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val environment = AppGraph.editorEnvironment(this)
        setContent {
            MaterialTheme {
                Surface {
                    val editor: EditorViewModel = viewModel(factory = EditorViewModel.factory(environment))
                    EditorScreen(editor)
                }
            }
        }
    }
}

/**
 * Process-wide singletons (manual DI until Hilt). The environment, and with it the export
 * coordinator and the render thread, outlives Activity recreation, so a Save in progress survives
 * rotation along with the ViewModel.
 */
private object AppGraph {
    @Volatile private var environment: EditorEnvironment? = null

    fun editorEnvironment(context: Context): EditorEnvironment = environment ?: synchronized(this) {
        environment ?: run {
            val metrics = context.resources.displayMetrics
            AndroidEditorEnvironment.create(context, screenLongestPx = maxOf(metrics.widthPixels, metrics.heightPixels))
                .also { environment = it }
        }
    }
}
