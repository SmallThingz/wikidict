package app.smallthingz.dict

import android.content.ContentResolver
import android.database.Cursor
import android.net.Uri
import android.os.CancellationSignal
import android.provider.DocumentsContract
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.InputStream

/** One import owns its provider queries and streams, including cancellation of a blocked read. */
internal class SafReleaseAccess(
    private val resolver: ContentResolver,
    private val tree: Uri,
    private val checkActive: () -> Unit,
) : Closeable {
    private val lock = Any()
    private var closed = false
    private val signals = mutableSetOf<CancellationSignal>()
    private val streams = mutableSetOf<InputStream>()

    fun open(): ReleaseDirectory {
        require(DocumentsContract.isTreeUri(tree)) { "Choose an edition folder." }
        val document = stat(DocumentsContract.getTreeDocumentId(tree))
        require(document.directory && !virtual(document)) { "Choose a readable edition folder." }
        return Directory(document)
    }

    private inner class Directory(private val document: ReleaseDocument) : ReleaseDirectory {
        override val name: String get() = document.name

        override fun children(): List<ReleaseDocument> {
            require(stat(document.id) == document) { "The release folder changed during import." }
            val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, document.id)
            return query(uri) { c -> buildList {
                while (c.moveToNext()) {
                    checkActive()
                    require(size < 10_000) { "The release folder has too many items." }
                    add(row(c))
                }
            } }
        }

        override fun directory(child: ReleaseDocument): ReleaseDirectory {
            require(child.directory && !virtual(child)) { "Cannot read the release folder." }
            return Directory(child)
        }

        override fun read(child: ReleaseDocument, limit: Int): ByteArray {
            checkActive()
            require(!child.directory && !virtual(child)) { "Release metadata is not a readable file." }
            require(child.size <= limit) { "Release metadata is too large." }
            val uri = DocumentsContract.buildDocumentUriUsingTree(tree, child.id)
            val source = withSignal { signal ->
                val descriptor = requireNotNull(resolver.openAssetFileDescriptor(uri, "r", signal)) { "Cannot open release metadata." }
                val input = try { descriptor.createInputStream() } catch (error: Throwable) { descriptor.close(); throw error }
                synchronized(lock) {
                    if (closed) { input.close(); error("Edition import was cancelled.") }
                    streams.add(input)
                }
                input
            }
            try {
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    checkActive()
                    val count = source.read(buffer, 0, minOf(buffer.size, limit + 1 - output.size()))
                    if (count < 0) break
                    require(count > 0) { "Cannot read release metadata." }
                    output.write(buffer, 0, count)
                    require(output.size() <= limit) { "Release metadata is too large." }
                }
                return output.toByteArray()
            } finally {
                try { source.close() } finally { synchronized(lock) { streams.remove(source) } }
            }
        }
    }

    private fun stat(id: String): ReleaseDocument = query(DocumentsContract.buildDocumentUriUsingTree(tree, id)) { c ->
        require(c.moveToFirst()) { "Cannot open the edition folder." }
        val value = row(c)
        require(!c.moveToNext()) { "The edition folder is ambiguous." }
        value
    }

    private fun <T> query(uri: Uri, action: (Cursor) -> T): T = withSignal { signal ->
        val cursor = requireNotNull(resolver.query(uri, columns, null, null, null, signal)) { "Cannot read the release folder." }
        cursor.use(action)
    }

    private fun <T> withSignal(action: (CancellationSignal) -> T): T {
        checkActive()
        val signal = CancellationSignal()
        synchronized(lock) {
            check(!closed) { "Edition import was cancelled." }
            signals.add(signal)
        }
        try { return action(signal) } finally { synchronized(lock) { signals.remove(signal) } }
    }

    override fun close() {
        val owned = synchronized(lock) {
            closed = true
            signals.toList() to streams.toList()
        }
        var failure: Throwable? = null
        for (signal in owned.first) try { signal.cancel() } catch (error: Throwable) {
            if (failure == null) failure = error else failure.addSuppressed(error)
        }
        for (stream in owned.second) try { stream.close() } catch (error: Throwable) {
            if (failure == null) failure = error else failure.addSuppressed(error)
        }
        failure?.let { throw it }
    }

    companion object {
        private val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_FLAGS,
        )
        private fun virtual(document: ReleaseDocument) = document.flags and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT.toLong() != 0L
        private fun row(cursor: Cursor): ReleaseDocument {
            fun text(index: Int) = requireNotNull(cursor.getString(index)) { "The release folder listing is invalid." }
            return ReleaseDocument(text(0), text(1), text(2) == DocumentsContract.Document.MIME_TYPE_DIR,
                if (cursor.isNull(3)) -1 else cursor.getLong(3),
                if (cursor.isNull(4)) 0 else cursor.getLong(4),
                if (cursor.isNull(5)) 0 else cursor.getLong(5))
        }
    }
}
