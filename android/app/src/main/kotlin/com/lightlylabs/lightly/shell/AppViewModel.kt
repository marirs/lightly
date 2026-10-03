package com.lightlylabs.lightly.shell

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Shell state that must survive rotation, fold changes and process death: where the user is, and
 * the URI a camera capture is being written to while the camera app is in front (Lightly's process
 * can be killed while the camera runs; the result must still find its file).
 */
class AppViewModel(private val savedState: SavedStateHandle) : ViewModel() {

    private val navState = MutableStateFlow(AppNavigator.decode(savedState.get<String>(KEY_NAV)))
    val nav: StateFlow<AppNavState> = navState.asStateFlow()

    fun navigate(next: AppNavState) {
        navState.value = next
        savedState[KEY_NAV] = AppNavigator.encode(next)
    }

    /** System Back. Returns false when the app should let the system handle it (leave the app). */
    fun back(): Boolean {
        val previous = AppNavigator.back(navState.value) ?: return false
        navigate(previous)
        return true
    }

    var pendingCaptureUri: String?
        get() = savedState.get<String>(KEY_CAPTURE)
        set(value) {
            savedState[KEY_CAPTURE] = value
        }

    companion object {
        private const val KEY_NAV = "shell.nav"
        private const val KEY_CAPTURE = "shell.pendingCapture"

        val factory: ViewModelProvider.Factory = viewModelFactory {
            initializer { AppViewModel(createSavedStateHandle()) }
        }
    }
}
