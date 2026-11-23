package com.airplayreceiver.desktop.backend

import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoWakeSettingsTest {
    @Test
    fun accessibilityFeaturesDefaultOffAndPreserveSavedOptIns() = runBlocking {
        val directory = Files.createTempDirectory("fusionplay-auto-wake-test-")
        val settingsPath = directory.resolve("settings.json")
        try {
            val store = SettingsStore(settingsPath)
            val fresh = store.load()
            assertFalse(fresh.startupEnabled)
            assertFalse(fresh.autoWakeEnabled)

            Files.write(settingsPath, """{"schemaVersion":8,"startupEnabled":true}""".toByteArray())
            val existing = store.load()
            assertTrue(existing.startupEnabled)
            assertFalse(existing.autoWakeEnabled)

            store.save(existing.copy(startupEnabled = false, autoWakeEnabled = true))
            val updated = store.load()
            assertFalse(updated.startupEnabled)
            assertTrue(updated.autoWakeEnabled)
        } finally {
            Files.deleteIfExists(settingsPath)
            Files.deleteIfExists(directory)
        }
    }
}
