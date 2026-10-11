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
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

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

    private val toastState = MutableStateFlow<String?>(null)
    private var toastJob: Job? = null

    /**
     * The toast on screens without a photo stage (Welcome, More): the theme cycle's "System theme" and the like. Kept here,
     * not in composition, because an Appearance change recreates the Activity on API 31+ and the toast must outlive it.
     */
    val toast: StateFlow<String?> = toastState.asStateFlow()

    fun showToast(text: String) {
        toastJob?.cancel()
        toastState.value = text
        toastJob = viewModelScope.launch {
            delay(TOAST_MILLIS)
            if (toastState.value == text) toastState.value = null
        }
    }

    var pendingCaptureUri: String?
        get() = savedState.get<String>(KEY_CAPTURE)
        set(value) {
            savedState[KEY_CAPTURE] = value
        }

    companion object {
        private const val KEY_NAV = "shell.nav"
        private const val KEY_CAPTURE = "shell.pendingCapture"

        /** As long as the editor's toast shows (EditorViewModel.TOAST_MILLIS). */
        const val TOAST_MILLIS = 1400L

        val factory: ViewModelProvider.Factory = viewModelFactory {
            initializer { AppViewModel(createSavedStateHandle()) }
        }
    }
}
