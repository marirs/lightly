package com.lightlylabs.lightly

import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.ui.geometry.Rect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker
import com.lightlylabs.lightly.editor.WindowHinge
import kotlinx.coroutines.flow.map
import com.lightlylabs.lightly.editor.AndroidEditorEnvironment
import com.lightlylabs.lightly.editor.EditorEnvironment
import com.lightlylabs.lightly.editor.EditorScreen
import com.lightlylabs.lightly.editor.EditorViewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val environment = AppGraph.editorEnvironment(this)
        // Folds and hinges (spec §6): book / tabletop posture must never put the photo across the hinge.
        val hinges = WindowInfoTracker.getOrCreate(this).windowLayoutInfo(this).map { info ->
            info.displayFeatures.filterIsInstance<FoldingFeature>().map { fold ->
                WindowHinge(
                    boundsInWindowPx = Rect(fold.bounds.left.toFloat(), fold.bounds.top.toFloat(), fold.bounds.right.toFloat(), fold.bounds.bottom.toFloat()),
                    isVertical = fold.orientation == FoldingFeature.Orientation.VERTICAL,
                    separatesContent = fold.isSeparating || fold.state == FoldingFeature.State.HALF_OPENED,
                )
            }
        }
        setContent {
            MaterialTheme {
                Surface {
                    val editor: EditorViewModel = viewModel(factory = EditorViewModel.factory(environment))
                    val currentHinges by hinges.collectAsStateWithLifecycle(initialValue = emptyList())
                    EditorScreen(editor, currentHinges)
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
