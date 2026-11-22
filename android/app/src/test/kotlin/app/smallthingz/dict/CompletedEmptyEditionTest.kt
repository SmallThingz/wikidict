package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.Base64
import java.security.MessageDigest

class CompletedEmptyEditionTest {
    private class Directory(override val name: String) : ReleaseDirectory {
        val documents = linkedMapOf<String, ReleaseDocument>()
        val bytes = mutableMapOf<String, ByteArray>()
        val folders = mutableMapOf<String, Directory>()
        var failListing = false
        var failRead = false
        var afterRead: (() -> Unit)? = null
        fun file(name: String, value: ByteArray) { documents[name] = ReleaseDocument("opaque:$name", name, false, value.size.toLong()); bytes[name] = value }
        fun folder(child: Directory) { documents[child.name] = ReleaseDocument("opaque:${child.name}", child.name, true); folders[child.name] = child }
        override fun children(): List<ReleaseDocument> {
            if (failListing) throw IOException("controlled provider listing failure")
            return documents.values.toList()
        }
        override fun directory(child: ReleaseDocument): ReleaseDirectory = requireNotNull(folders[child.name])
        override fun read(child: ReleaseDocument, limit: Int): ByteArray {
            if (failRead) throw IOException("controlled provider read failure")
            val value = requireNotNull(bytes[child.name]).copyOf()
            require(value.size <= limit)
            afterRead?.invoke()
            return value
        }
    }

    private fun marker() = Base64.getDecoder().decode(GENUINE_AFAR_COMPLETE_BASE64)
    private fun release(marker: ByteArray = marker(), name: String = "20261001") = Directory(name).apply {
        file("complete.json", marker)
        file("languages.tsv", "heading\n".toByteArray())
    }
    private fun tree(release: Directory = release()) = Directory("aawiktionary").apply { folder(release) }
    private fun decode(directory: ReleaseDirectory) = CompletedEmptyEdition.read(directory, "content://provider/tree/opaque-id")
    private fun altered(from: String, to: String): ByteArray {
        val text = marker().toString(Charsets.UTF_8)
        check(text.contains(from))
        return text.replace(from, to).toByteArray()
    }

    @Test fun genuineAfarCompletionKeepsProcessedPagesDistinctFromEntries() {
        val bytes = marker()
        assertEquals(8226, bytes.size)
        assertEquals("1156622048b62556b37001cdcb8b94a37785760954248d9e2f6efff986a1e845",
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
        val result = decode(tree())
        assertEquals("aawiktionary-20261001", result.edition)
        assertEquals(101L, result.sourcePages)
        assertEquals("content://provider/tree/opaque-id", result.sourceUri)
        assertEquals("ba252c3de087f11a0dc82b74ff54e838b8b0f49fbd219c6e16da8248c8025f89", result.catalogSha256)
    }

    @Test fun contradictoryCompletionMetadataCannotBecomeAnEmptyEdition() {
        val cases = listOf(
            altered("\"status\": \"empty\"", "\"status\": \"complete\""),
            altered("\"blobs\": 0", "\"blobs\": 1"),
            altered("\"blobs\": 0", "\"blobs\": \"0\""),
            altered("\"input_pages\": 101", "\"input_pages\": -1"),
            altered("\"input_pages\": 101", "\"input_pages\": 1.5"),
            altered("\"input_pages\": 101", "\"input_pages\": 9223372036854775808"),
            altered("\"input_pages\": 101", "\"input_pages\": null"),
            altered("\"edition\": \"aawiktionary\"", "\"edition\": \"enwiktionary\""),
            altered("\"date\": \"20261001\"", "\"date\": \"20260230\""),
            altered("\"date\": \"20261001\"", "\"date\": \"20261002\""),
            altered("\"status\": \"empty\"", "\"status\": \"empty\", \"status\": \"empty\""),
            "[]".toByteArray(), "{}".toByteArray(), marker() + " false".toByteArray(),
            byteArrayOf(0xff.toByte()),
        )
        for ((index, value) in cases.withIndex()) {
            val error = runCatching { decode(tree(release(value))) }.exceptionOrNull()
            assertNotNull("contradiction $index", error)
        }
    }

    @Test fun headingAndDirectoryContradictionsRemainDistinctFromCompletedEmpty() {
        val changes: List<(Directory) -> Unit> = listOf(
            { it.documents.remove("complete.json") },
            { it.documents.remove("languages.tsv") },
            { it.file("languages.tsv", byteArrayOf()) },
            { it.file("languages.tsv", "heading\nAfar\n".toByteArray()) },
            { it.file("languages.tsv", "heading\r\n".toByteArray()) },
            { it.file(".incomplete", byteArrayOf()) },
            { it.file("dict.wikblb", byteArrayOf()) },
            { it.file("dict.wikblb.xz", byteArrayOf()) },
            { it.file("languages", byteArrayOf()) },
            { it.folder(Directory("languages").apply { file("dict.wikblb", byteArrayOf()) }) },
            { it.folder(Directory("languages").apply { file("dict.wikblb.xz", byteArrayOf()) }) },
        )
        for ((index, change) in changes.withIndex()) {
            val release = release().also(change)
            assertNotNull("folder contradiction $index", runCatching { decode(tree(release)) }.exceptionOrNull())
        }
        assertEquals(101L, decode(tree(release().apply { folder(Directory("languages")) })).sourcePages)
        assertNotNull(runCatching { decode(Directory("aawiktionary")) }.exceptionOrNull())
    }

    @Test fun actualParentRelationshipIsRequiredAndDocumentIdsRemainOpaque() {
        assertNotNull(runCatching { decode(release()) }.exceptionOrNull())
        assertEquals("aawiktionary-20261001", decode(release(name = "aawiktionary-20261001")).edition)
        assertNotNull(runCatching { decode(Directory("enwiktionary").apply { folder(release()) }) }.exceptionOrNull())
        val provider = tree()
        provider.documents.replaceAll { _, doc -> doc.copy(id = "not-a-path/another-edition:arbitrary") }
        assertEquals(101L, decode(provider).sourcePages)
        assertNotNull(runCatching { decode(tree(release(altered("\"date\": \"20261001\"", "\"date\": \"00000101\""), "00000101"))) }.exceptionOrNull())
    }

    @Test fun newestDatedReleaseNeverSilentlyFallsBackToAnOlderEmptyRelease() {
        val edition = tree().apply { folder(Directory("20261101")) }
        assertNotNull(runCatching { decode(edition) }.exceptionOrNull())
        edition.folders.getValue("20261101").file(".incomplete", byteArrayOf())
        assertNotNull(runCatching { decode(edition) }.exceptionOrNull())
        val latest = release(altered("\"date\": \"20261001\"", "\"date\": \"20261101\""), "20261101")
        edition.folder(latest)
        assertEquals("aawiktionary-20261101", decode(edition).edition)
    }

    @Test fun ProviderFailuresAndChangingSnapshotsNeverInstallAnEmptySummary() {
        assertThrows(IOException::class.java) { decode(tree().apply { failListing = true }) }
        assertThrows(IOException::class.java) { decode(tree(release().apply { failRead = true })) }
        assertThrows(IOException::class.java) { decode(tree(release().apply { folder(Directory("languages").apply { failListing = true }) })) }
        val changing = release()
        changing.afterRead = { changing.file("late.wikblb", byteArrayOf()) }
        assertNotNull(runCatching { decode(tree(changing)) }.exceptionOrNull())
        val changingMarker = release()
        var reads = 0
        changingMarker.afterRead = { if (++reads == 2) changingMarker.file("complete.json", altered("\"input_pages\": 101", "\"input_pages\": 102")) }
        assertNotNull(runCatching { decode(tree(changingMarker)) }.exceptionOrNull())
    }

    @Test fun oversizedOrAmbiguousMetadataIsRefused() {
        assertNotNull(runCatching { decode(tree(release(ByteArray(4 * 1024 * 1024 + 1)))) }.exceptionOrNull())
        val duplicate = object : ReleaseDirectory {
            override val name = "aawiktionary"
            override fun children() = listOf(ReleaseDocument("one", "20261001", true), ReleaseDocument("two", "20261001", true))
            override fun directory(child: ReleaseDocument): ReleaseDirectory = error("ambiguous directory was opened")
            override fun read(child: ReleaseDocument, limit: Int): ByteArray = error("unexpected read")
        }
        assertThrows(IllegalArgumentException::class.java) { decode(duplicate) }
        val tooMany = object : ReleaseDirectory by duplicate {
            override fun children() = List(10_001) { ReleaseDocument("$it", "$it", false) }
        }
        assertThrows(IllegalArgumentException::class.java) { decode(tooMany) }
    }

    companion object {
        // Exact authenticated Afar publication complete.json; source pages are not lexical records.
        private const val GENUINE_AFAR_COMPLETE_BASE64 = "eyJlZGl0aW9uIjogImFhd2lrdGlvbmFyeSIsICJkYXRlIjogIjIwMjYxMDAxIiwgImR1bXBfc3RhZ2luZ192ZXJzaW9uIjogInBhZ2UtYWxpZ25lZC16c3RkLXBhcmFsbGVsLXYyIiwgImR1bXBfY29kZWMiOiAienN0ZCIsICJkdW1wX3N0cmVhbV9raW5kIjogIm11bHRpc3RyZWFtLXpzdGQiLCAic3RhdHVzIjogImVtcHR5IiwgImZhbGxiYWNrX3BhZ2VzIjogMCwgImZhbGxiYWNrX3JlcG9ydCI6ICJmYWxsYmFjay1wYWdlcy5qc29ubCIsICJjb21wcmVzc2lvbiI6ICJ4eiAtMDsgMSBNaUIgYmxvY2tzIiwgImJsb2JzIjogMCwgImlucHV0X3BhZ2VzIjogMTAxLCAicGFnZV9jb3ZlcmFnZV9yZXBvcnQiOiAicGFnZS1jb3ZlcmFnZS5qc29uIiwgIm5hbWVzcGFjZV9jb3ZlcmFnZV9yZXBvcnQiOiAibmFtZXNwYWNlLWNvdmVyYWdlLmpzb24iLCAibmFtZXNwYWNlX2NvdmVyYWdlX3RvdGFscyI6IHsiaW5wdXRfcm93cyI6IDEwMSwgImNvbXBpbGVfb25seV9yb3dzIjogOTksICJzb3VyY2VfdW5hdmFpbGFibGVfcm93cyI6IDAsICJkaXNwYXRjaGVkX3Jvd3MiOiAwLCAiZXhwYW5kZWRfcGFnZXMiOiAwLCAiZmFsbGJhY2tfcGFnZXMiOiAwLCAiZHVwbGljYXRlX3Jvd3MiOiAwLCAiYWxpYXNfcGFnZXMiOiAwLCAic2l0ZV9tZXRhZGF0YV9yb3dzIjogMn0sICJwdWJsaWNhdGlvbl9maWxlcyI6IHsiLmF1eGlsaWFyeS1zbmFwc2hvdHMuc2hhMjU2Lmpzb24iOiB7InNpemUiOiAxMjMzLCAic2hhMjU2IjogImQ0ZmYzNDIzMDIyOTM5NmM0MmQxMjQ3NTFjYTZlOTgyYTVmZWM2ZTIzMTQ5OWVkMGIyYjVlZmFkZTBiZmUyNTAifSwgIi5idWlsZC1pbnB1dHMuanNvbiI6IHsic2l6ZSI6IDQ5ODIsICJzaGEyNTYiOiAiYzAzNjRiZGIzNjVlOGJjYWUzZDU2YTc1OTU2ZWIyODI3MzU1OGNmOTQyMGVkN2E2MjNlY2IwNzExZGM5YWY5YSJ9LCAiLmJ1aWxkLW5vdy11bml4Lmpzb24iOiB7InNpemUiOiAxMSwgInNoYTI1NiI6ICI5OWFkN2VkOTNkNmY1Zjc5NTRiMWE1MmZjYjMzNDRhZjBhYjk3ZjE3NTNiNzU3NjdhYTJkMzgxODlmM2VmYzVlIn0sICIuaW50ZXJ3aWtpLW1hcC5zaGEyNTYiOiB7InNpemUiOiA2NSwgInNoYTI1NiI6ICJjMWE2NjhmZjQ1MTM0YTI1NWQ1NjI0MjkyZTdmOGY0NjhiMDE0MDFiZmEzZThlOGViNWZmMjhkNmJjOTYxNTdmIn0sICJjb21waWxlLXBsYW4udHN2IjogeyJzaXplIjogNjcsICJzaGEyNTYiOiAiMjc0MTZjMDEzNzdkODI5ZTgyODMxMGFmOTViMzNlNzA1NWE1YzNhZTkwMjRhNGVmYTg5ZWJlY2E3NjI3NGFjZSJ9LCAiZmFsbGJhY2stcGFnZXMuanNvbmwiOiB7InNpemUiOiAwLCAic2hhMjU2IjogImUzYjBjNDQyOThmYzFjMTQ5YWZiZjRjODk5NmZiOTI0MjdhZTQxZTQ2NDliOTM0Y2E0OTU5OTFiNzg1MmI4NTUifSwgImxhbmd1YWdlcy50c3YiOiB7InNpemUiOiA4LCAic2hhMjU2IjogImJhMjUyYzNkZTA4N2YxMWEwZGM4MmI3NGZmNTRlODM4YjhiMGY0OWZiZDIxOWM2ZTE2ZGE4MjQ4YzgwMjVmODkifSwgIm1vZHVsZS1jb21waWxlLXBsYW4udHN2IjogeyJzaXplIjogMTEwLCAic2hhMjU2IjogImE0NWNmNGRjZjBlNDgyYzQxNWQ1NjQ3NjNlYzcxMzdjZjcxMTNmMGZmOWJiODQzNTE2NTczZjMwNjZjZTg5ODAifSwgIm5hbWVzcGFjZS1jb3ZlcmFnZS5qc29uIjogeyJzaXplIjogMTc0NywgInNoYTI1NiI6ICI5YWY2ZjgwZTM0MzVkZTNkZDg1OWZmNGZmYzJkYWY1NmMyZDYxZjZiY2EyYWMyMTUzYjhkZjFkNWRiMDc3ODRmIn0sICJwYWdlLWNvdmVyYWdlLmpzb24iOiB7InNpemUiOiAyNjEsICJzaGEyNTYiOiAiODAwY2JhMDQ4NDU0MWEyZjcwYmNkZmRlOGFiYWRiZTc2ZTRhMzM4MGYyMDc1MWNlZjc2NjdkMDE3ZWViNTQzYyJ9fSwgImJ1aWxkX2lucHV0cyI6IHsidmVyc2lvbiI6IDEsICJzb3VyY2UiOiAiOWExNjkwM2RiY2U0MzFhNjNjZDVlNDUwNTMzMGFlMWFlOWMyY2RhYmY2YzgzMWVlNDc5ZmFmYjg4YWIxNGVmNSIsICJmaWxlcyI6IFtbImFhd2lrdGlvbmFyeSIsICIyMDI2MTAwMSIsICJhYXdpa3Rpb25hcnktMjAyNjEwMDEtY2F0ZWdvcnkuc3FsLmd6IiwgODY3LCAiYmEyOGVmNTY3Mzg2YjZmNDIzNGNkMjI1MDg2YjBiYTUyYjM0MTc4ZiJdLCBbImFhd2lrdGlvbmFyeSIsICIyMDI2MTAwMSIsICJhYXdpa3Rpb25hcnktMjAyNjEwMDEtY2F0ZWdvcnlsaW5rcy5zcWwuZ3oiLCAxMDIxLCAiNzkxYmU4MjI2NjQxZTYxMTU1OTQxOGYxNjZhZDJhZjVjYTNmNWU3MyJdLCBbImFhd2lrdGlvbmFyeSIsICIyMDI2MTAwMSIsICJhYXdpa3Rpb25hcnktMjAyNjEwMDEtbGlua3RhcmdldC5zcWwuZ3oiLCA2MjQ2LCAiZDI2YmJmMmYwOWZiNmNhZTg4YzRmZmExMTJiNTI2N2JjYjIxYmM0YSJdLCBbImFhd2lrdGlvbmFyeSIsICIyMDI2MTAwMSIsICJhYXdpa3Rpb25hcnktMjAyNjEwMDEtcGFnZS5zcWwuZ3oiLCA0MDIzLCAiZjc1ZWM3MGRkMzczZjE1MGMxM2FiMWRlYTViMzYxNGRmZDY1N2M5NCJdLCBbImFhd2lrdGlvbmFyeSIsICIyMDI2MTAwMSIsICJhYXdpa3Rpb25hcnktMjAyNjEwMDEtcGFnZV9wcm9wcy5zcWwuZ3oiLCAxMDU5LCAiMjNmOTQyYjA1NGY3MWQ2ODUxMDVjOTY4MDU3NWQ1ZjUzZjUzNWYzNCJdLCBbImFhd2lrdGlvbmFyeSIsICIyMDI2MTAwMSIsICJhYXdpa3Rpb25hcnktMjAyNjEwMDEtcGFnZXMtbWV0YS1jdXJyZW50LnhtbC5iejIiLCAzNzU4MywgIjI5OGUwMDJhNTMxZmQ0OTdjZTZhYTQwZWQ2ZTJjZjAzMjM5ZjUwM2IiXSwgWyJhYXdpa3Rpb25hcnkiLCAiMjAyNjEwMDEiLCAiYWF3aWt0aW9uYXJ5LTIwMjYxMDAxLXJlZGlyZWN0LnNxbC5neiIsIDEwNDcsICJjNTVlZGI2MWU0NjY0NDVjYjlmMjc1ZDRhN2E1MjQwMDY4NWM0ZDk3Il0sIFsiYWF3aWt0aW9uYXJ5IiwgIjIwMjYxMDAxIiwgImFhd2lrdGlvbmFyeS0yMDI2MTAwMS1zaXRlX3N0YXRzLnNxbC5neiIsIDg0MCwgIjZhMDgzZGVhYjFkMjNkNjRlZjQ5NWViZGZlYjg2MzJmMDI0ZjA2MjAiXV0sICJ6aWdfc2hhMjU2IjogIjdjNjE1MzlhZjE5ZmE0MDgyYzk0ODQ4ZjFjMmI1N2I4OWU3NmRjNmNmZDViZDRjNTc3NjRjM2NhZjhmODIyNzIiLCAiYXV4aWxpYXJ5X3NuYXBzaG90X3NoYTI1NiI6IHsiYmVoYXZpb3Itc3dpdGNoZXMiOiAiNTE3ZjFkNGQ4MDQ4ZDVlNmY3ZjY3OTI3NzcyMWRjYWJhNmExZmQ5MDRkNDI4MWNjZmI4MWJiMWZlMDRiMGViMSIsICJjYXRlZ29yeS1zdGF0aXN0aWNzLWZvcm1hdCI6ICIwMzNmMGU3MjdlMzIwNjU2YWRmMzE3ZWI0OTcwNzE5OThiMzA5ODU2NmNmZjg0N2Y0YzE3ZTA1ZjZkOTg4OTdlIiwgImNhdGVnb3J5LXN0YXRzIjogImFjMjU3ZDkxYWZlNmYxN2FkZDc3NGM1MTU2ODkxN2QxODdjMmYzMzEzYzk4YThhZjkxZGVlOGE4MTk3NTZkNDQiLCAiY2F0ZWdvcnktdHJlZSI6ICIwNmQ1MWZlYzkxYTYxYTU1OWRhZGYyNGE4OGFiYTYxZGY0NTA0ZDg4YTljYmU1YjE3NzIwNjA2OGViY2VmN2E1IiwgImRhdGUtbnVtYmVyaW5nIjogIjI4MjFlMjdjNTIxNDBjY2MyNzZmYTUyYWYwYmJmNGYwNmQzNThiYjM1ZGVjMTllZmQxOTVhMmJlYTJhMTJiOTYiLCAiaW1hZ2Utb3B0aW9ucyI6ICI1ZTU5NjM0NGNiZjM5MjUyNTdhNTJjMWMzYmIyNTNjYmRiNGI0MTM5MWQxYWEyNzllMWZmYzVmODI0NzEwYWRiIiwgImludGVyZmFjZS1tZXNzYWdlcyI6ICIwODBmYTllZmJiZWJmNmQxYTRmOTQxMzBkMDUyYzljYWQ0YjAxMTI5MjNhYWY3ZmEzMTQxN2QxOTcwMjIxMDMwIiwgImxhbmd1YWdlLWZhbGxiYWNrcyI6ICJhZmViZTcyNjVkODU5NjA2OTZmNTM1YTRhZTkzMDQ4YjUzNThiNTUwMWZhMTRlMjU0NjQ4NWQzODk1NGUxZGYyIiwgImxhbmd1YWdlLW5hbWVzIjogImRmMjg0YjY5NzAyZjM3OGQ2NzMxZjVhZTU3NTU4OGMyNjUwY2UwN2JlNDMxYTE3MmIyNWIzY2I4MWNiMjQwZjEiLCAibGFuZ3VhZ2UtcmVnaXN0cnkiOiAiMDZjODNhMTE4ZDQyYWFmMzg3YTM2YjM2ZGUzNzQ0MzBhOTYzZjM3YTJhMTZjYTI4YmQxYjk2ZTc1ZWY5NmJiNCIsICJtYWdpYy13b3JkcyI6ICI3YjlhYTc3OTc0NjRmZGQ1NDc5MmRkN2MzZjdlYjQyMzhjNDFlYjIwOWQ5Y2ViNzVhYzQ2MGY1YTE1N2Q0Yzg5IiwgIm5hbWVzcGFjZS1yZWdpc3RyeSI6ICI5OGQ4ZTU1ODBiMTVkNDBhNmM3OTkzM2EwZGJhY2MzZTM3OWUxN2M1MTdmZDZkZTZiODkxMmRhYTc0ZTg2OGJjIiwgInNpdGUtaW5mbyI6ICI0ZDY2NTlmYmQ4ZmI5M2JjMmRkNjFlODdjZTg3NTU1MjE0MGYxYjdmYmIzYzdmMTllNTI1ZGZhMGYyMGEzNmIyIiwgInNpdGUtc3RhdGlzdGljcy1mb3JtYXQiOiAiMzUzNzg0ZTIwM2Y4ZWMwN2U1Y2VkNWZhZWY2MGY1OGUzYmI2YzM2NGU3MWNlOTBmMjA0MmE3ZDdmYWM4ZTExNSJ9LCAiaW50ZXJ3aWtpX21hcF9zaGEyNTYiOiAiYTIzMWMxNzlmZjNjZjdkMDM4MmQzZGI4ZjRjOTM2YWNkNTY4YjJlMDBiMjk2OTcwMjJlODIxMDQ5NTNhZDBkNyIsICJleHBhbnNpb25fdGltZW91dF9tcyI6IDYwMDAwLCAiYXV4aWxpYXJ5X2NhcHR1cmVfc2hhMjU2IjogeyJiZWhhdmlvci1zd2l0Y2hlcyI6ICI2MWEyYTIyNjI1NGI0MjVlNDI2ODdiNWYxOTM1NTk0MDk5YzExNGNhODQ0OTQxODMyNzZlYzJmMzE3MGQzY2YxIiwgImNhdGVnb3J5LXN0YXRpc3RpY3MtZm9ybWF0IjogIjZmMDExZDI2ZjNiZTQ1ZGVlNDI1ZmI2N2I0ZmEzYzc1ZjFmZTFmMDdhMjExNTU3MGJmZjQ3M2RlMzk3YjY2ZGMiLCAiZGF0ZS1udW1iZXJpbmciOiAiMzdhOTA0NjY5MmUxMmMxNTJiMzAxNGE1Yjg5MWM4OGVjZjcyNTBkYTNlOGVkZjI2Y2Y1MjBlYWNiOWMwNmU3OCIsICJpbWFnZS1vcHRpb25zIjogIjI4ZmVkMGI3NzhlOWRiMjBmNTQ2MjRlNTc2YWFkNDFiYzMyNTRjMTgzNDNlN2I5ZjI1MjY1ZGU2MDNiMmQxZmQiLCAiaW50ZXJmYWNlLW1lc3NhZ2VzIjogIjRjNWJkNjA5ODY5ZWZmMDAzMjg1YTIzNmZiOWViOTAwMGM3ZTVjNDIyMDM2MTg4ODBhNzE1N2VjNjI0OGNhMzQiLCAibGFuZ3VhZ2UtZmFsbGJhY2tzIjogIjEzZDg5YTBlMzJjYTZkY2Y3ZTg2Y2FjODA3OGU0ZmMzMTE0OTExZWM4YWJlMDI0NWRhMzNiNjY2YTRmMDc2ZDIiLCAibGFuZ3VhZ2UtbmFtZXMiOiAiYzAyY2YwZTVjMmMzZmY5OTRmZTU1MWIxYjlmYjJjNTA2MjI2YzAxNzNlNTk3MzQ4NDk2NTlmODZkY2YxNDAyNyIsICJtYWdpYy13b3JkcyI6ICJmODEwYTU4ODJlOGEzOTI4ZTUxY2MxNWNjZjI3OWRhMGM5MTc4M2UzNWEwMjJiZDBlOTQxODg4NmJjYzc1Zjk0IiwgInNpdGUtaW5mbyI6ICI1OGUyMjY2ZWE3ZjdkNzYzNWQ0YjgwY2I3YjlmOTM5ODI2ZDZlMGI5YWY5MjBlNzFkYWIyN2YwOTkzYzliYzJlIiwgInNpdGUtc3RhdGlzdGljcy1mb3JtYXQiOiAiNjJiMDI0YTM3MjRmMDQzM2IyODJlZDY2OTAxYTdlZTA2NDdjYmRhNDJiNTA5NzY0MTNmY2M5M2I2MDBhMDBiMCJ9LCAiYXV4aWxpYXJ5X2NhcHR1cmVfYXJ0aWZhY3Rfc2hhMjU2IjogeyJiZWhhdmlvci1zd2l0Y2hlcyI6ICJmNjg5OTIzMGY5OWQ0NzI2NTA0YzI0MDgxMmVjMTE0ZWJlYmE3MmU4M2QzMzhhOGVlNDJiZDFjMTE2Y2I4MzA5IiwgImNhdGVnb3J5LXN0YXRpc3RpY3MtZm9ybWF0IjogIjg2YThlMWNhZmVjOGM4ZmYzMjFlODZjOGFiMTMyZDk2YjIyN2JmN2NkZThlNjhhZTllMGViYjA4MjUwYWIwMzgiLCAiZGF0ZS1udW1iZXJpbmciOiAiYjUzYzk3MzgwNTRmOTg4NTQ3ZjBjYmY3ZGUxYmNhNmFiN2FkNDkyNzM4OTAxMDNlMDNhMTQyNGI5Y2NmYTQxNCIsICJpbWFnZS1vcHRpb25zIjogIjlhOWFmYjE5NmJhNjFmMGNjN2YxNWU5YmQzMWUwYmE3YzI4NGVlMmU3MzFhMWJlOTFiYmMxOWFkYWQ1MGVhZGYiLCAiaW50ZXJmYWNlLW1lc3NhZ2VzIjogIjdkMjliOTQzMTlkZGM2OThmMDA0MGJjZjljODFjYzJiNzc1ZTk5ZTVhZGRiZGNkM2E0ZjFiYTkxNjZmOGMyMzgiLCAibGFuZ3VhZ2UtZmFsbGJhY2tzIjogIjdkMjliOTQzMTlkZGM2OThmMDA0MGJjZjljODFjYzJiNzc1ZTk5ZTVhZGRiZGNkM2E0ZjFiYTkxNjZmOGMyMzgiLCAibGFuZ3VhZ2UtbmFtZXMiOiAiZDJkODc4M2FkZDMxMWFlMmM2ZDgyN2JiYWI1ZDNhYWI1ZWJkZjUxNmUxZmViM2ZhNDE1ODJhYTdiMzMzNDg3MyIsICJtYWdpYy13b3JkcyI6ICJiYTM1MmI2MjViNDYwYzZhZGIwMzBkMWNjOWUzNDU0Njg5MGE5YTlkZDQxNjhjMzNkOGVkNWY0MmI4ODUwMWRmIiwgInNpdGUtaW5mbyI6ICI3ZWY0YWFiOGFiYjg2NDkzN2RhY2IxYjU0YmE0YjYyZGRhZTc0ODk0NDJkOTRiMjA2MmFkOWU2MTBkNTZhNjdkIiwgInNpdGUtc3RhdGlzdGljcy1mb3JtYXQiOiAiMmZhM2RhODNmYjQ4NWM1Y2MwNmVhNTU4MTBkNjdiZGEyOTZmYTlkNmMyYjQ3MzhjYjRjZmZiYTUzZjFlMzdhNCJ9LCAiZGVyaXZlZF9wYWdlX3JlZGlyZWN0cyI6IHsic2NoZW1hIjogIndpa2lkaWN0LXBhZ2UtcmVkaXJlY3RzLXYxIiwgInNvdXJjZSI6IHsid2lraSI6ICJhYXdpa3Rpb25hcnkiLCAiZGF0ZSI6ICIyMDI2MTAwMSIsICJuYW1lIjogImFhd2lrdGlvbmFyeS0yMDI2MTAwMS1yZWRpcmVjdC5zcWwuZ3oiLCAidXJsIjogImh0dHBzOi8vZHVtcHMud2lraW1lZGlhLm9yZy9hYXdpa3Rpb25hcnkvMjAyNjEwMDEvYWF3aWt0aW9uYXJ5LTIwMjYxMDAxLXJlZGlyZWN0LnNxbC5neiIsICJzaXplIjogMTA0NywgInNoYTEiOiAiYzU1ZWRiNjFlNDY2NDQ1Y2I5ZjI3NWQ0YTdhNTI0MDA2ODVjNGQ5NyJ9LCAic3FsX3NoYTI1NiI6ICI5MmQwMmMzNjZmOWQ1OTVmMTBhNTRjYjc4YjRiM2NhOTRhY2Q3MGNmZmY1MzdiNzY4ZWI5NWZmMGY0NmJmZjgxIiwgImdlbmVyYXRvcl9zaGEyNTYiOiAiZTEzNjM0YjMzZTY4NDQ0MTg1YTc2ZmFjNTQ5NTAzMmJiMWM5MWYwNTQwYjc1ZDJiNGJhYmIwNGViNzU0NzExOSIsICJwYXJzZXJfc2hhMjU2IjogIjc4MGFkMzVmMzJlYWFlYjI3NGYxZThiY2Y5MTZiMWFlMjMxMzVkZDg5NWY4ZWQ3ODdkNDZmYjhiYjQ5ZmNhZDQifX0sICJub3dfdW5peCI6IDE3OTE3MzE1NjAsICJpbnRlcndpa2lfbWFwX3NoYTI1NiI6ICJhMjMxYzE3OWZmM2NmN2QwMzgyZDNkYjhmNGM5MzZhY2Q1NjhiMmUwMGIyOTY5NzAyMmU4MjEwNDk1M2FkMGQ3IiwgImF1eGlsaWFyeV9zbmFwc2hvdF9zaGEyNTYiOiB7ImJlaGF2aW9yLXN3aXRjaGVzIjogIjUxN2YxZDRkODA0OGQ1ZTZmN2Y2NzkyNzc3MjFkY2FiYTZhMWZkOTA0ZDQyODFjY2ZiODFiYjFmZTA0YjBlYjEiLCAiY2F0ZWdvcnktc3RhdGlzdGljcy1mb3JtYXQiOiAiMDMzZjBlNzI3ZTMyMDY1NmFkZjMxN2ViNDk3MDcxOTk4YjMwOTg1NjZjZmY4NDdmNGMxN2UwNWY2ZDk4ODk3ZSIsICJjYXRlZ29yeS1zdGF0cyI6ICJhYzI1N2Q5MWFmZTZmMTdhZGQ3NzRjNTE1Njg5MTdkMTg3YzJmMzMxM2M5OGE4YWY5MWRlZThhODE5NzU2ZDQ0IiwgImNhdGVnb3J5LXRyZWUiOiAiMDZkNTFmZWM5MWE2MWE1NTlkYWRmMjRhODhhYmE2MWRmNDUwNGQ4OGE5Y2JlNWIxNzcyMDYwNjhlYmNlZjdhNSIsICJkYXRlLW51bWJlcmluZyI6ICIyODIxZTI3YzUyMTQwY2NjMjc2ZmE1MmFmMGJiZjRmMDZkMzU4YmIzNWRlYzE5ZWZkMTk1YTJiZWEyYTEyYjk2IiwgImltYWdlLW9wdGlvbnMiOiAiNWU1OTYzNDRjYmYzOTI1MjU3YTUyYzFjM2JiMjUzY2JkYjRiNDEzOTFkMWFhMjc5ZTFmZmM1ZjgyNDcxMGFkYiIsICJpbnRlcmZhY2UtbWVzc2FnZXMiOiAiMDgwZmE5ZWZiYmViZjZkMWE0Zjk0MTMwZDA1MmM5Y2FkNGIwMTEyOTIzYWFmN2ZhMzE0MTdkMTk3MDIyMTAzMCIsICJsYW5ndWFnZS1mYWxsYmFja3MiOiAiYWZlYmU3MjY1ZDg1OTYwNjk2ZjUzNWE0YWU5MzA0OGI1MzU4YjU1MDFmYTE0ZTI1NDY0ODVkMzg5NTRlMWRmMiIsICJsYW5ndWFnZS1uYW1lcyI6ICJkZjI4NGI2OTcwMmYzNzhkNjczMWY1YWU1NzU1ODhjMjY1MGNlMDdiZTQzMWExNzJiMjViM2NiODFjYjI0MGYxIiwgImxhbmd1YWdlLXJlZ2lzdHJ5IjogIjA2YzgzYTExOGQ0MmFhZjM4N2EzNmIzNmRlMzc0NDMwYTk2M2YzN2EyYTE2Y2EyOGJkMWI5NmU3NWVmOTZiYjQiLCAibWFnaWMtd29yZHMiOiAiN2I5YWE3Nzk3NDY0ZmRkNTQ3OTJkZDdjM2Y3ZWI0MjM4YzQxZWIyMDlkOWNlYjc1YWM0NjBmNWExNTdkNGM4OSIsICJuYW1lc3BhY2UtcmVnaXN0cnkiOiAiOThkOGU1NTgwYjE1ZDQwYTZjNzk5MzNhMGRiYWNjM2UzNzllMTdjNTE3ZmQ2ZGU2Yjg5MTJkYWE3NGU4NjhiYyIsICJzaXRlLWluZm8iOiAiNGQ2NjU5ZmJkOGZiOTNiYzJkZDYxZTg3Y2U4NzU1NTIxNDBmMWI3ZmJiM2M3ZjE5ZTUyNWRmYTBmMjBhMzZiMiIsICJzaXRlLXN0YXRpc3RpY3MtZm9ybWF0IjogIjM1Mzc4NGUyMDNmOGVjMDdlNWNlZDVmYWVmNjBmNThlM2JiNmMzNjRlNzFjZTkwZjIwNDJhN2Q3ZmFjOGUxMTUifX0K"
    }
}
