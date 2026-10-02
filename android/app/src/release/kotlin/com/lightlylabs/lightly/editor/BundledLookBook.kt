package com.lightlylabs.lightly.editor

/**
 * The look-book this build ships (counterpart of iOS `LUTLookBook.bundled`, also empty).
 *
 * DEFERRED (core-looks, M3/M4): curated Look LUTs, converted and validated against Lightroom. Until
 * they exist a release build ships no Looks at all rather than unvalidated placeholders; the editor
 * hides the Look controls and still offers Auto (when available), Compare and Save copy.
 */
internal object BundledLookBook {
    fun create(): LookBook = LookBook(emptyList())
}
