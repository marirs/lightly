package com.lightlylabs.lightly.editor

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Unit tests run against the debug variant only (AGP 9 default), so this checks the debug book; the
 * release book (src/release) is `LookBook(emptyList())`, whose behaviour the empty-book case covers.
 */
class BundledLookBookTest {

    @Test
    fun `the debug build's Looks are labelled provisional`() {
        val book = BundledLookBook.create()
        assertEquals(PlaceholderLookBook.PROVISIONAL_NOTICE, book.provisionalNotice)
        assertTrue(book.categories.isNotEmpty())
    }

    @Test
    fun `an empty book (release builds) has no categories, no stops and no notice`() {
        val book = LookBook(emptyList())
        assertTrue(book.categories.isEmpty())
        assertTrue(book.stops("Natural").isEmpty())
        assertEquals(0, book.stopIndexOf("Natural", null))
        assertNull(book.provisionalNotice)
    }
}
