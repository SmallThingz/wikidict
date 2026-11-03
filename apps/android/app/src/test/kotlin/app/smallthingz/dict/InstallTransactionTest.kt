package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.IOException

class InstallTransactionTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun failedCommitRemovesOnlyConfirmedUnregisteredFileAfterTransactionEnd() {
        val file = temporary.newFile("dictionary.wikblb").apply { writeText("dictionary bytes") }
        val failure = IOException("commit failed")
        val events = mutableListOf<String>()
        val caught = assertThrows(IOException::class.java) {
            finishDictionaryInstall(null, file,
                endTransaction = { events += "end"; throw failure },
                registered = { events += "committed query"; assertTrue(file.exists()); false },
                refresh = { throw AssertionError("Failed commit has no registered dictionary") })
        }
        assertSame(failure, caught)
        assertEquals(listOf("end", "committed query"), events)
        assertFalse(file.exists())
    }

    @Test fun committedRegistrationKeepsBytesAndRefreshesWhenTransactionReleaseThrows() {
        val file = temporary.newFile("dictionary.wikblb").apply { writeText("committed bytes") }
        var registered = false
        var visible = false
        val failure = IOException("connection release failed after COMMIT")
        val caught = assertThrows(IOException::class.java) {
            finishDictionaryInstall(null, file,
                endTransaction = { registered = true; throw failure },
                registered = { registered },
                refresh = { assertEquals("committed bytes", file.readText()); visible = registered })
        }
        assertSame(failure, caught)
        assertTrue(visible)
        assertEquals("committed bytes", file.readText())
    }

    @Test fun unresolvedTransactionKeepsBytesWithoutClaimingRefresh() {
        val file = temporary.newFile("dictionary.wikblb").apply { writeText("unresolved bytes") }
        val failure = IOException("transaction still active")
        val caught = assertThrows(IOException::class.java) {
            finishDictionaryInstall(null, file, { throw failure }, { null },
                { throw AssertionError("Unresolved registration cannot claim refresh") })
        }
        assertSame(failure, caught)
        assertEquals("unresolved bytes", file.readText())
    }

    @Test fun failedRegistrationProofKeepsBytesAndOriginalError() {
        val file = temporary.newFile("dictionary.wikblb").apply { writeText("unresolved bytes") }
        val commitFailure = IOException("commit outcome unknown")
        val queryFailure = IOException("registration transaction unavailable")
        val caught = assertThrows(IOException::class.java) {
            finishDictionaryInstall(null, file, { throw commitFailure }, { throw queryFailure },
                { throw AssertionError("Failed proof cannot claim refresh") })
        }
        assertSame(commitFailure, caught)
        assertArrayEquals(arrayOf<Throwable>(queryFailure), caught.suppressed)
        assertEquals("unresolved bytes", file.readText())
    }

    @Test fun failedBodyRollsBackBeforeRemovingPlacedFileAndPreservesBothErrors() {
        val file = temporary.newFile("dictionary.wikblb").apply { writeText("uncommitted bytes") }
        val bodyFailure = IllegalArgumentException("alias collision")
        val endFailure = IOException("connection release failed after ROLLBACK")
        var registered = true
        var pending: Exception? = null
        val caught = assertThrows(IllegalArgumentException::class.java) {
            try { throw bodyFailure }
            catch (failure: Exception) { pending = failure; throw failure }
            finally {
                finishDictionaryInstall(pending, file,
                    endTransaction = { assertTrue(file.exists()); registered = false; throw endFailure },
                    registered = { registered },
                    refresh = { throw AssertionError("Rolled back dictionary must not be shown") })
            }
        }
        assertSame(bodyFailure, caught)
        assertArrayEquals(arrayOf<Throwable>(endFailure), caught.suppressed)
        assertFalse(file.exists())
    }

    @Test fun normalAndAlreadyInstalledTransactionsRefreshWithoutReconciliation() {
        val file = temporary.newFile("dictionary.wikblb").apply { writeText("committed bytes") }
        var ends = 0
        var refreshes = 0
        for (placed in listOf(file, null)) {
            finishDictionaryInstall(null, placed, { ends++ },
                { throw AssertionError("Successful transaction needs no reconciliation query") }, { refreshes++ })
        }
        assertEquals(2, ends)
        assertEquals(2, refreshes)
        assertEquals("committed bytes", file.readText())
    }

    @Test fun failureBeforePlacementNeverQueriesOrDeletesExistingFile() {
        val existing = temporary.newFile("dictionary.wikblb").apply { writeText("existing bytes") }
        val failure = IOException("transaction end failed")
        val caught = assertThrows(IOException::class.java) {
            finishDictionaryInstall(null, null, { throw failure },
                { throw AssertionError("No file was placed") }, { throw AssertionError("Failed transaction cannot claim refresh") })
        }
        assertSame(failure, caught)
        assertEquals("existing bytes", existing.readText())
    }

    @Test fun failedRefreshAfterCommittedRegistrationPreservesBytesAndBothErrors() {
        val file = temporary.newFile("dictionary.wikblb").apply { writeText("committed bytes") }
        val endFailure = IOException("connection release failed")
        val refreshFailure = IOException("refresh unavailable")
        val caught = assertThrows(IOException::class.java) {
            finishDictionaryInstall(null, file, { throw endFailure }, { true }, { throw refreshFailure })
        }
        assertSame(endFailure, caught)
        assertArrayEquals(arrayOf<Throwable>(refreshFailure), caught.suppressed)
        assertEquals("committed bytes", file.readText())
    }

    @Test fun fatalBodyFailureEndsTransactionWithoutQueryRefreshOrDeletion() {
        val file = temporary.newFile("dictionary.wikblb").apply { writeText("unresolved bytes") }
        val failure = AssertionError("fatal body failure")
        var ends = 0
        var pending: Throwable? = null
        val caught = assertThrows(AssertionError::class.java) {
            try { throw failure }
            catch (body: Throwable) { pending = body; throw body }
            finally {
                finishDictionaryInstall(pending, file, { ends++ },
                    { throw AssertionError("Fatal failure must not start reconciliation") },
                    { throw AssertionError("Fatal failure must not start refresh") })
            }
        }
        assertSame(failure, caught)
        assertEquals(1, ends)
        assertEquals("unresolved bytes", file.readText())
    }

    @Test fun committedRemovalRefreshesOwnershipWhenTransactionReleaseThrows() {
        val file = temporary.newFile("removed.wikblb").apply { writeText("dictionary bytes") }
        val releaseFailure = IOException("release failed after COMMIT")
        var registered = true
        var visible = true
        val events = mutableListOf<String>()
        val caught = assertThrows(IOException::class.java) {
            finishDictionaryRemoval(null,
                endTransaction = { events += "end"; registered = false; throw releaseFailure },
                registered = { events += "committed query"; registered },
                removeFile = { events += "delete"; assertTrue(file.delete()) },
                refresh = { events += "refresh"; visible = registered })
        }
        assertSame(releaseFailure, caught)
        assertEquals(listOf("end", "committed query", "delete", "refresh"), events)
        assertFalse(file.exists())
        assertFalse(visible)
    }

    @Test fun rolledBackRemovalPreservesPayloadAndVisibleOwnership() {
        val file = temporary.newFile("retained.wikblb").apply { writeText("retained bytes") }
        val bodyFailure = IOException("delete failed before COMMIT")
        val releaseFailure = IOException("release failed after ROLLBACK")
        var pending: Throwable? = null
        var visible = true
        val events = mutableListOf<String>()
        val caught = assertThrows(IOException::class.java) {
            try { throw bodyFailure }
            catch (error: Throwable) { pending = error; throw error }
            finally {
                finishDictionaryRemoval(pending,
                    endTransaction = { events += "end"; throw releaseFailure },
                    registered = { events += "committed query"; true },
                    removeFile = { throw AssertionError("Registered bytes must remain") },
                    refresh = { visible = false; throw AssertionError("Rolled back ownership remains") })
            }
        }
        assertSame(bodyFailure, caught)
        assertArrayEquals(arrayOf<Throwable>(releaseFailure), caught.suppressed)
        assertEquals(listOf("end", "committed query"), events)
        assertEquals("retained bytes", file.readText())
        assertTrue(visible)
    }

    @Test fun unresolvedRemovalKeepsPayloadAndOriginalFailure() {
        val file = temporary.newFile("uncertain.wikblb").apply { writeText("uncertain bytes") }
        val failure = IOException("transaction unresolved")
        val caught = assertThrows(IOException::class.java) {
            finishDictionaryRemoval(null, { throw failure }, { null },
                { throw AssertionError("Unknown registration must retain bytes") },
                { throw AssertionError("Unknown outcome cannot claim a new snapshot") })
        }
        assertSame(failure, caught)
        assertEquals("uncertain bytes", file.readText())
    }

    @Test fun committedRemovalRefreshesEvenWhenPayloadCleanupFails() {
        val file = temporary.newFile("orphan.wikblb").apply { writeText("preserved bytes") }
        val releaseFailure = IOException("release failed after COMMIT")
        val cleanupFailure = IOException("payload cleanup failed")
        var visible = true
        val caught = assertThrows(IOException::class.java) {
            finishDictionaryRemoval(null, { throw releaseFailure }, { false },
                { throw cleanupFailure }, { visible = false })
        }
        assertSame(releaseFailure, caught)
        assertArrayEquals(arrayOf<Throwable>(cleanupFailure), caught.suppressed)
        assertFalse(visible)
        assertEquals("preserved bytes", file.readText())
    }

}
