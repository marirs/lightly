package com.lightlylabs.lightly.editor

/**
 * The look-book this build ships (counterpart of iOS `LUTLookBook.bundled`).
 *
 * Debug builds: the procedural [PlaceholderLookBook], labelled provisional in the UI, so the Look
 * flow can be demonstrated on an emulator. Release builds use an empty book (src/release).
 */
internal object BundledLookBook {
    fun create(): LookBook = PlaceholderLookBook.create()
}
