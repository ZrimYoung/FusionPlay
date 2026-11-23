package com.airplayreceiver.desktop.backend

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class CoreSourceTakeoverTest {
    @Test
    fun miplayOnlyNeedsNoCoreCommand() {
        sendCoreTakeoverToPeers(emptyList()) { throw AssertionError("Unexpected core command for $it") }
    }

    @Test
    fun fallsBackToTheOtherConfiguredProtocol() {
        val attempted = mutableListOf<String>()
        sendCoreTakeoverToPeers(listOf("airplay", "dlna")) { protocol ->
            attempted += protocol
            protocol == "dlna"
        }
        assertEquals(listOf("airplay", "dlna"), attempted)
    }

    @Test
    fun successfulFirstProtocolDoesNotSendTwice() {
        val attempted = mutableListOf<String>()
        sendCoreTakeoverToPeers(listOf("airplay", "dlna")) { protocol ->
            attempted += protocol
            true
        }
        assertEquals(listOf("airplay"), attempted)
    }

    @Test
    fun rejectionByAllConfiguredProtocolsStillFails() {
        val attempted = mutableListOf<String>()
        val failure = assertThrows(IllegalStateException::class.java) {
            sendCoreTakeoverToPeers(listOf("airplay", "dlna")) { protocol ->
                attempted += protocol
                false
            }
        }
        assertEquals(listOf("airplay", "dlna"), attempted)
        assertEquals("The requested receiver service is not running.", failure.message)
    }
}
