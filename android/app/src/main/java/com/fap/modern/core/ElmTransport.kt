package com.fap.modern.core

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID

/** How the adapter is reached. */
sealed interface TransportConfig {
    /** Classic Bluetooth SPP (RFCOMM) - what most ELM327 adapters expose. */
    data class Bluetooth(val address: String, val name: String) : TransportConfig

    /**
     * BLE GATT clones. [context] must be the application context: the config
     * outlives an activity.
     */
    data class Ble(
        val address: String,
        val name: String,
        val context: android.content.Context,
    ) : TransportConfig

    data class Wifi(val host: String, val port: Int) : TransportConfig
}

/** A raw byte pipe to an ELM327 adapter. Command framing lives in [ElmSession]. */
interface ElmTransport {
    fun open()
    fun input(): InputStream
    fun output(): OutputStream
    fun close()
}

class BluetoothTransport(private val config: TransportConfig.Bluetooth) : ElmTransport {

    private val sppUuid: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    private var socket: BluetoothSocket? = null

    @SuppressLint("MissingPermission") // caller must hold BLUETOOTH_CONNECT (checked in UI)
    override fun open() {
        val adapter = BluetoothAdapter.getDefaultAdapter()
            ?: throw IllegalStateException("No Bluetooth adapter on this device")
        if (!adapter.isEnabled) throw IllegalStateException("Bluetooth is turned off")
        val device: BluetoothDevice = adapter.getRemoteDevice(config.address)
        adapter.cancelDiscovery()
        val s = try {
            device.createRfcommSocketToServiceRecord(sppUuid)
        } catch (e: Exception) {
            throw IllegalStateException("Cannot create RFCOMM socket: ${e.message}")
        }
        try {
            s.connect()
        } catch (e: Exception) {
            // Fallback to the reflection channel-1 trick some clones need.
            try {
                @Suppress("DEPRECATION")
                val fallback = device.javaClass
                    .getMethod("createRfcommSocket", Int::class.javaPrimitiveType)
                    .invoke(device, 1) as BluetoothSocket
                fallback.connect()
                socket = fallback
                return
            } catch (e2: Exception) {
                try { s.close() } catch (_: Exception) {}
                throw IllegalStateException("Bluetooth connect failed: ${e.message}")
            }
        }
        socket = s
    }

    override fun input(): InputStream =
        socket?.inputStream ?: throw IllegalStateException("Bluetooth not open")

    override fun output(): OutputStream =
        socket?.outputStream ?: throw IllegalStateException("Bluetooth not open")

    override fun close() {
        try { socket?.close() } catch (_: Exception) {}
        socket = null
    }
}

class WifiTransport(private val config: TransportConfig.Wifi) : ElmTransport {

    private var socket: Socket? = null

    override fun open() {
        val s = Socket()
        s.connect(InetSocketAddress(config.host, config.port), 8000)
        s.tcpNoDelay = true
        socket = s
    }

    override fun input(): InputStream =
        socket?.getInputStream() ?: throw IllegalStateException("WiFi not open")

    override fun output(): OutputStream =
        socket?.getOutputStream() ?: throw IllegalStateException("WiFi not open")

    override fun close() {
        try { socket?.close() } catch (_: Exception) {}
        socket = null
    }
}
