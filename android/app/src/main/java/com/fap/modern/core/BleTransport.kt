package com.fap.modern.core

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothProfile
import android.content.Context
import java.io.InputStream
import java.io.OutputStream
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * ELM327 clones that expose a BLE GATT service instead of classic SPP
 * (Konnwei, Vgate and friends).
 *
 * GATT is callback- and packet-based while the session wants byte streams, so
 * notifications are queued and handed out through an InputStream, and writes
 * are split into MTU-sized chunks. The characteristic pair is discovered
 * rather than hardcoded: these clones use several different service UUIDs, and
 * some advertise one characteristic for both directions.
 */
class BleTransport(private val config: TransportConfig.Ble) : ElmTransport {

    private var gatt: BluetoothGatt? = null
    private var writeChar: BluetoothGattCharacteristic? = null

    private val incoming = ArrayDeque<Byte>()
    private val lock = Object()

    private val connected = CountDownLatch(1)
    private val ready = CountDownLatch(1)
    @Volatile private var failure: String? = null

    private val cccd = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")

    @SuppressLint("MissingPermission")
    override fun open() {
        val adapter = BluetoothAdapter.getDefaultAdapter()
            ?: throw IllegalStateException("На устройстве нет Bluetooth")
        if (!adapter.isEnabled) throw IllegalStateException("Bluetooth выключен")
        val device = adapter.getRemoteDevice(config.address)

        gatt = device.connectGatt(config.context, false, callback, BluetoothDevice.TRANSPORT_LE)
        if (!connected.await(12, TimeUnit.SECONDS)) {
            close()
            throw IllegalStateException("BLE: устройство не отвечает")
        }
        if (!ready.await(12, TimeUnit.SECONDS)) {
            close()
            throw IllegalStateException(failure ?: "BLE: не найдены характеристики ELM")
        }
        failure?.let { close(); throw IllegalStateException(it) }
    }

    override fun input(): InputStream = object : InputStream() {
        override fun read(): Int = synchronized(lock) {
            if (incoming.isEmpty()) -1 else incoming.removeFirst().toInt() and 0xFF
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int = synchronized(lock) {
            var n = 0
            while (n < len && incoming.isNotEmpty()) {
                b[off + n] = incoming.removeFirst()
                n++
            }
            if (n == 0) -1 else n
        }

        override fun available(): Int = synchronized(lock) { incoming.size }
    }

    @SuppressLint("MissingPermission")
    override fun output(): OutputStream = object : OutputStream() {
        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

        override fun write(b: ByteArray, off: Int, len: Int) {
            val g = gatt ?: throw IllegalStateException("BLE не открыт")
            val ch = writeChar ?: throw IllegalStateException("BLE: нет характеристики записи")
            var i = off
            while (i < off + len) {
                val n = minOf(CHUNK, off + len - i)
                ch.value = b.copyOfRange(i, i + n)
                ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                g.writeCharacteristic(ch)
                i += n
                // These clones drop data if chunks arrive back to back.
                try { Thread.sleep(8) } catch (_: InterruptedException) { return }
            }
        }
    }

    @SuppressLint("MissingPermission")
    override fun close() {
        try { gatt?.disconnect() } catch (_: Exception) {}
        try { gatt?.close() } catch (_: Exception) {}
        gatt = null
        writeChar = null
        synchronized(lock) { incoming.clear() }
    }

    private val callback = object : BluetoothGattCallback() {

        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                connected.countDown()
                g.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                failure = failure ?: "BLE: соединение разорвано"
                connected.countDown()
                ready.countDown()
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            var notify: BluetoothGattCharacteristic? = null
            var write: BluetoothGattCharacteristic? = null
            for (service in g.services) {
                for (ch in service.characteristics) {
                    val p = ch.properties
                    val canNotify = p and (BluetoothGattCharacteristic.PROPERTY_NOTIFY or
                        BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0
                    val canWrite = p and (BluetoothGattCharacteristic.PROPERTY_WRITE or
                        BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0
                    if (canNotify && notify == null) notify = ch
                    if (canWrite && write == null) write = ch
                }
                if (notify != null && write != null) break
            }
            if (notify == null || write == null) {
                failure = "BLE: устройство не похоже на ELM327 (нет notify/write)"
                ready.countDown()
                return
            }
            writeChar = write
            g.setCharacteristicNotification(notify, true)
            val desc = notify.getDescriptor(cccd)
            if (desc != null) {
                desc.value = BluetoothGattDescriptorEnableNotify
                g.writeDescriptor(desc)
            }
            ready.countDown()
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            val data = ch.value ?: return
            synchronized(lock) { for (b in data) incoming.addLast(b) }
        }
    }

    private companion object {
        /** Conservative payload per notification: 23-byte default MTU minus ATT overhead. */
        const val CHUNK = 20
        val BluetoothGattDescriptorEnableNotify: ByteArray =
            android.bluetooth.BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
    }
}
