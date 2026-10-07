package com.lightlylabs.lightly.develop

import org.junit.Assert.assertEquals
import org.junit.Test

class Utf8TextTest {
    @Test
    fun `byte ranges decode to the same substrings as the UTF-16 positions`() {
        // 1-, 2-, 3- and 4-byte characters (é, 中, an emoji as a surrogate pair) around and inside the entries.
        val text = """[{"name":"Café 中"},{"name":"😀 Glow"},{"name":"plain"}]"""
        val starts = Regex("""\{""").findAll(text).map { it.range.first }.toList()
        val ends = Regex("""\}""").findAll(text).map { it.range.last + 1 }.toList()
        val utf8 = Utf8Text(text)
        for (i in starts.indices) {
            val start = utf8.byteOffset(starts[i])
            val end = utf8.byteOffset(ends[i])
            assertEquals(text.substring(starts[i], ends[i]), utf8.bytes.decode(start, end))
        }
    }

    @Test(expected = IllegalArgumentException::class)
    fun `positions must be asked for in increasing order`() {
        val utf8 = Utf8Text("""{"a":1}""")
        utf8.byteOffset(5)
        utf8.byteOffset(2)
    }
}
