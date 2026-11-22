package app.smallthingz.dict

import com.google.gson.Strictness
import com.google.gson.stream.JsonReader
import com.google.gson.stream.JsonToken
import java.io.StringReader
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.time.LocalDate
import java.time.format.DateTimeFormatter

/** Publication metadata, never a synthetic dictionary or word record. */
data class EmptyEditionInfo(
    val edition: String,
    val sourcePages: Long,
    val sourceUri: String,
    val markerSha256: String,
    val catalogSha256: String,
)

internal data class ReleaseDocument(
    val id: String,
    val name: String,
    val directory: Boolean,
    val size: Long = -1,
    val modified: Long = 0,
    val flags: Long = 0,
)

/** IDs are opaque; only provider-reported names and actual child relationships identify an edition. */
internal interface ReleaseDirectory {
    val name: String
    fun children(): List<ReleaseDocument>
    fun directory(child: ReleaseDocument): ReleaseDirectory
    fun read(child: ReleaseDocument, limit: Int): ByteArray
}

internal object CompletedEmptyEdition {
    private val editionName = Regex("[a-z][a-z0-9_-]*wiktionary")
    private val dateName = Regex("[0-9]{8}")
    private const val markerLimit = 4 * 1024 * 1024

    fun read(tree: ReleaseDirectory, sourceUri: String): EmptyEditionInfo {
        val rootChildren = snapshot(tree)
        val direct = tree.name.substringBeforeLast('-', "") to tree.name.substringAfterLast('-', "")
        val selected: ReleaseDirectory
        val expected: String
        if (editionName.matches(direct.first) && validDate(direct.second)) {
            selected = tree
            expected = tree.name
        } else {
            require(editionName.matches(tree.name)) {
                "Choose the edition folder, such as aawiktionary, containing its dated release folders."
            }
            val newest = rootChildren.filter { it.directory && validDate(it.name) }.maxByOrNull { it.name }
            requireNotNull(newest) { "This edition folder has no dated release." }
            selected = tree.directory(newest)
            expected = "${tree.name}-${newest.name}"
        }
        val children = snapshot(selected)
        require(children.none { it.name == ".incomplete" }) { "This release is incomplete." }
        val marker = children.singleOrNull { it.name == "complete.json" }
        require(marker != null && !marker.directory) { "This folder has no completed-release metadata." }
        val markerBytes = selected.read(marker, markerLimit)
        val fields = try { parseMarker(markerBytes) } catch (error: Exception) {
            throw IllegalArgumentException("Completed-release metadata is invalid.", error)
        }
        require(fields.status == "empty") {
            "This release is not marked completed-empty. Import its dictionary files instead."
        }
        require(editionName.matches(fields.edition) && validDate(fields.date) && fields.pages >= 0 && fields.blobs == 0L) {
            "Completed-release metadata is invalid."
        }
        require("${fields.edition}-${fields.date}" == expected) { "Release metadata does not match its folder." }
        val catalog = children.singleOrNull { it.name == "languages.tsv" }
        require(catalog != null && !catalog.directory) { "Completed release is missing its language catalogue." }
        val catalogBytes = selected.read(catalog, 16)
        require(catalogBytes.contentEquals("heading\n".toByteArray(Charsets.UTF_8))) {
            "Completed-empty release has an invalid language catalogue."
        }
        require(children.none(::isBlob)) { "Completed-empty release contains dictionary files." }
        val languages = children.singleOrNull { it.name == "languages" }
        val languageDirectory = languages?.let {
            require(it.directory) { "The languages item is not a readable folder." }
            selected.directory(it)
        }
        val languageChildren = languageDirectory?.let(::snapshot)
        require(languageChildren?.none(::isBlob) != false) { "Completed-empty release contains dictionary files." }
        // Do not install a summary assembled from a changing provider snapshot.
        require(selected.read(marker, markerLimit).contentEquals(markerBytes) &&
            selected.read(catalog, 16).contentEquals(catalogBytes) && snapshot(selected) == children &&
            (languageDirectory == null || snapshot(languageDirectory) == languageChildren) && snapshot(tree) == rootChildren) {
            "The release changed during import. Try again after it has finished copying."
        }
        return EmptyEditionInfo(expected, fields.pages, sourceUri, sha256(markerBytes), sha256(catalogBytes))
    }

    private fun snapshot(directory: ReleaseDirectory): List<ReleaseDocument> {
        val children = directory.children()
        require(children.size <= 10_000 && children.map { it.name }.toSet().size == children.size &&
            children.map { it.id }.toSet().size == children.size) { "The release folder listing is invalid." }
        return children.sortedBy { it.id }
    }

    private fun isBlob(document: ReleaseDocument) =
        document.name.endsWith(".wikblb") || document.name.endsWith(".wikblb.xz")

    private fun validDate(value: String): Boolean = dateName.matches(value) && !value.startsWith("0000") && runCatching {
        LocalDate.parse(value, DateTimeFormatter.BASIC_ISO_DATE)
    }.isSuccess

    private data class Marker(val status: String, val edition: String, val date: String, val pages: Long, val blobs: Long)

    private fun parseMarker(bytes: ByteArray): Marker {
        require(bytes.size <= markerLimit) { "Completed-release metadata is too large." }
        val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
        JsonReader(StringReader(text)).use { reader ->
            reader.setStrictness(Strictness.STRICT)
            require(reader.peek() == JsonToken.BEGIN_OBJECT) { "Completed-release metadata must be an object." }
            reader.beginObject()
            val seen = HashSet<String>()
            var status: String? = null
            var edition: String? = null
            var date: String? = null
            var pages: Long? = null
            var blobs: Long? = null
            while (reader.hasNext()) {
                val key = reader.nextName()
                require(seen.add(key)) { "Completed-release metadata repeats a field." }
                when (key) {
                    "status" -> status = string(reader)
                    "edition" -> edition = string(reader)
                    "date" -> date = string(reader)
                    "input_pages" -> pages = integer(reader)
                    "blobs" -> blobs = integer(reader)
                    else -> reader.skipValue()
                }
            }
            reader.endObject()
            require(reader.peek() == JsonToken.END_DOCUMENT) { "Unexpected data after completed-release metadata." }
            return Marker(requireNotNull(status), requireNotNull(edition), requireNotNull(date), requireNotNull(pages), requireNotNull(blobs))
        }
    }

    private fun string(reader: JsonReader): String {
        require(reader.peek() == JsonToken.STRING) { "Completed-release text field is invalid." }
        return reader.nextString()
    }

    private fun integer(reader: JsonReader): Long {
        require(reader.peek() == JsonToken.NUMBER) { "Completed-release count is invalid." }
        return reader.nextString().toBigDecimal().longValueExact()
    }

    private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it) }
}
