package app.smallthingz.dict

import android.app.ActivityOptions
import android.os.Bundle
import android.view.Display
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.AndroidComposeTestRule
import androidx.compose.ui.test.junit4.v2.AndroidComposeTestRule as createV2AndroidComposeTestRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.platform.app.InstrumentationRegistry
import kotlin.coroutines.EmptyCoroutineContext
import org.junit.Assert.assertEquals
import org.junit.rules.TestRule
import org.junit.runner.Description
import org.junit.runners.model.Statement

internal fun physicalActivityLaunchOptions(): Bundle =
    ActivityOptions.makeBasic().setLaunchDisplayId(Display.DEFAULT_DISPLAY).toBundle()

internal fun assertPhysicalActivity(activity: ComponentActivity) {
    assertEquals(InstrumentationRegistry.getInstrumentation().targetContext.packageName, activity.packageName)
    assertEquals(Display.DEFAULT_DISPLAY, activity.windowManager.defaultDisplay.displayId)
    assertEquals(Display.DEFAULT_DISPLAY, checkNotNull(activity.window.decorView.display).displayId)
}

/** Launch only our validation activity on the physical display; never move a foreign task. */
open class PhysicalScenarioRule<A : ComponentActivity>(activityType: Class<A>) : TestRule {
    private val delegate = ActivityScenarioRule(
        activityType,
        physicalActivityLaunchOptions(),
    )

    val scenario: ActivityScenario<A> get() = delegate.scenario

    fun activity(): A {
        var current: A? = null
        scenario.onActivity { activity ->
            assertPhysicalActivity(activity)
            current = activity
        }
        return checkNotNull(current)
    }

    override fun apply(base: Statement, description: Description): Statement =
        delegate.apply(object : Statement() {
            override fun evaluate() {
                activity() // The scenario is resumed, before the test body or its first UI action.
                base.evaluate()
            }
        }, description)
}

class PhysicalActivityRule : PhysicalScenarioRule<MainActivity>(MainActivity::class.java)

// A reader-content fixture supplies its own EntryView and does not open the saved library.
internal fun createPhysicalContentRule() =
    createV2AndroidComposeTestRule(PhysicalScenarioRule(ComponentActivity::class.java), EmptyCoroutineContext) { it.activity() }

internal fun createPhysicalComposeRule(): AndroidComposeTestRule<PhysicalActivityRule, MainActivity> =
    createV2AndroidComposeTestRule(PhysicalActivityRule(), EmptyCoroutineContext) { it.activity() }

internal fun createLegacyPhysicalComposeRule(): AndroidComposeTestRule<PhysicalActivityRule, MainActivity> =
    AndroidComposeTestRule(PhysicalActivityRule(), EmptyCoroutineContext) { it.activity() }
