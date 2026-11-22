package app.smallthingz.dict

import java.io.IOException
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class EntryReadDispatcherTest {
    @Test fun resolvedOriginAndEagerPresentationStayOffCallerThread() = runBlocking {
        val caller = Thread.currentThread()
        val hit = WordHit("source", "origin", "English", "language", 0, 4)
        val earlierOrigin = WordHit("earlier", "old", "English", "language", 0, 4)
        for (redirect in listOf(null, Redirect("origin", "body", "Meaning", false),
            Redirect("origin", "body", "Meaning", true))) {
            val traversals = ConcurrentLinkedQueue<Thread>()
            val section = Section(2, "Meaning", listOf(Block("definition", 0,
                listOf(Span("text", "meaning", explanation = "Expanded meaning")))))
            val sections = object : AbstractList<Section>() {
                override val size = 1
                override fun get(index: Int): Section {
                    if (index != 0) throw IndexOutOfBoundsException()
                    traversals.add(Thread.currentThread())
                    return section
                }
            }
            val resolved = Entry("body", emptyList(), "language", "English", "en", sections,
                emptyList(), redirect = redirect, edition = "enwiktionary-20260901",
                origin = earlierOrigin, navigationKind = "language", navigationLanguage = "English",
                contentDictionary = "body-owner")
            val expected = resolved.copy(origin = hit)
            traversals.clear()
            val resolverThread = AtomicReference<Thread>()
            val actual = readEntryOnIo(hit) {
                resolverThread.set(Thread.currentThread())
                resolved
            }
            // The resolver returns a prebuilt entry: these reads prove the real final copy
            // constructed its eager rows/abbreviations off the caller, not just the callback.
            val copyThreads = traversals.toList()
            assertNotSame(caller, resolverThread.get())
            assertTrue(copyThreads.isNotEmpty())
            assertTrue(copyThreads.all { it !== caller })
            assertSame(caller, Thread.currentThread())
            assertEquals(expected, actual)
            assertEquals(expected.readingRows, actual.readingRows)
            assertEquals(expected.abbreviations, actual.abbreviations)
            assertSame(hit, actual.origin)
            assertEquals(hit.key, actual.key)
            assertSame(sections, actual.sections)
            assertSame(earlierOrigin, resolved.origin)
            assertEquals("body-owner", actual.contentDictionary)
            assertEquals(redirect, actual.redirect)
        }
    }

    @Test fun cancelledResolutionSkipsCopyAndFailuresStayUnchanged() = runBlocking {
        val hit = WordHit("source", "origin", "English", "language", 0, 4)
        val traversals = AtomicInteger()
        val section = Section(2, "Meaning", listOf(Block("definition", 0, listOf(Span("text", "meaning")))))
        val sections = object : AbstractList<Section>() {
            override val size = 1
            override fun get(index: Int): Section {
                if (index != 0) throw IndexOutOfBoundsException()
                traversals.incrementAndGet()
                return section
            }
        }
        val resolved = Entry("body", emptyList(), "language", "English", "en", sections, emptyList())
        traversals.set(0)
        val task = async {
            val callerContext = currentCoroutineContext()
            readEntryOnIo(hit) {
                callerContext.cancel()
                resolved
            }
        }
        try {
            task.await()
            fail("Cancelled resolution must not publish an entry")
        } catch (_: CancellationException) {
            assertTrue(task.isCancelled)
        }
        assertEquals(0, traversals.get())
        val failure = IOException("fixture read failure")
        try {
            readEntryOnIo(hit) { throw failure }
            fail("Read failure must propagate")
        } catch (actual: IOException) {
            assertEquals(failure.javaClass, actual.javaClass)
            assertEquals(failure.message, actual.message)
            assertTrue(actual === failure || actual.cause === failure)
        }
        assertEquals(0, traversals.get())
    }
}
