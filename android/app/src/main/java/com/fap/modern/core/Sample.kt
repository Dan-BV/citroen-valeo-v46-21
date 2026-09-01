package com.fap.modern.core

/** One live reading of a parameter. */
data class Sample(
    val value: Double,
    /** The untouched reading, which enumerated fields need for their label. */
    val raw: Int,
    val tMs: Long,
    val valid: Boolean,
)

/** A single point in a parameter's time-series history. */
data class Point(val tMs: Long, val value: Double)
