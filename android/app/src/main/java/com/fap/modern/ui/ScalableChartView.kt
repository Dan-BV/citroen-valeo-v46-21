package com.fap.modern.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.util.AttributeSet
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import com.fap.modern.core.Point
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Self-contained time-series chart with pinch-to-zoom and pan.
 * No external chart dependency — pure Canvas so the project builds offline.
 *
 * - Auto-follow mode keeps the latest [autoWindowMs] of data in view.
 * - Any pinch/drag switches to manual viewport; double-tap returns to auto-follow.
 */
class ScalableChartView @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null, defStyle: Int = 0,
) : View(context, attrs, defStyle) {

    private var data: List<Point> = emptyList()
    private var unit: String = ""
    private var decimals: Int = 1
    private var fallbackMin = 0.0
    private var fallbackMax = 1.0

    // Data-space viewport (manual mode).
    private var vpXMin = 0.0
    private var vpXMax = 1.0
    private var vpYMin = 0.0
    private var vpYMax = 1.0
    private var autoMode = true
    private val autoWindowMs = 60_000.0

    private val axisColor = Color.parseColor("#44515F")
    private val gridColor = Color.parseColor("#22FFFFFF")
    private val lineColor = Color.parseColor("#3DDC97")
    private val textColor = Color.parseColor("#9BA8B6")
    private val dotColor = Color.parseColor("#FFFFFF")

    private val gridPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = gridColor; strokeWidth = dp(1f); style = Paint.Style.STROKE
    }
    private val axisPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = axisColor; strokeWidth = dp(1.5f); style = Paint.Style.STROKE
    }
    private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = lineColor; strokeWidth = dp(2f); style = Paint.Style.STROKE
        strokeJoin = Paint.Join.ROUND; strokeCap = Paint.Cap.ROUND
    }
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = (lineColor and 0x00FFFFFF) or 0x22000000; style = Paint.Style.FILL
    }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = textColor; textSize = sp(11f)
    }
    private val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = dotColor; style = Paint.Style.FILL
    }
    private val hintPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = textColor; textSize = sp(13f); textAlign = Paint.Align.CENTER
    }

    private val timeFmt = SimpleDateFormat("HH:mm:ss", Locale.US)
    private val path = Path()

    private val padL get() = dp(52f)
    private val padR get() = dp(12f)
    private val padT get() = dp(12f)
    private val padB get() = dp(26f)

    private val scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(d: ScaleGestureDetector): Boolean {
            if (data.isEmpty()) return true
            ensureManualViewport()
            val f = d.scaleFactor.coerceIn(0.5f, 2f)
            val fx = pxToDataX(d.focusX)
            val fy = pyToDataY(d.focusY)
            vpXMin = fx - (fx - vpXMin) / f
            vpXMax = fx + (vpXMax - fx) / f
            vpYMin = fy - (fy - vpYMin) / f
            vpYMax = fy + (vpYMax - fy) / f
            invalidate()
            return true
        }
    })

    private val gestureDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onScroll(e1: MotionEvent?, e2: MotionEvent, dx: Float, dy: Float): Boolean {
            if (data.isEmpty()) return true
            ensureManualViewport()
            val xr = (vpXMax - vpXMin) / plotW()
            val yr = (vpYMax - vpYMin) / plotH()
            vpXMin += dx * xr; vpXMax += dx * xr
            vpYMin -= dy * yr; vpYMax -= dy * yr
            invalidate()
            return true
        }

        override fun onDoubleTap(e: MotionEvent): Boolean {
            autoMode = true
            invalidate()
            return true
        }
    })

    fun bind(unit: String, decimals: Int, fallbackMin: Double, fallbackMax: Double) {
        this.unit = unit
        this.decimals = decimals
        this.fallbackMin = fallbackMin
        this.fallbackMax = fallbackMax
    }

    fun setData(points: List<Point>) {
        data = points
        invalidate()
    }

    fun resetView() {
        autoMode = true
        invalidate()
    }

    val isAutoFollow: Boolean get() = autoMode

    private fun ensureManualViewport() {
        if (autoMode) {
            computeAutoViewport()
            autoMode = false
        }
    }

    private fun computeAutoViewport() {
        if (data.isEmpty()) {
            vpXMin = 0.0; vpXMax = 1.0; vpYMin = fallbackMin; vpYMax = fallbackMax
            return
        }
        val last = data.last().tMs.toDouble()
        val first = data.first().tMs.toDouble()
        vpXMax = last
        vpXMin = max(first, last - autoWindowMs)
        if (vpXMax - vpXMin < 1000) vpXMin = vpXMax - 1000
        var lo = Double.MAX_VALUE; var hi = -Double.MAX_VALUE
        for (p in data) {
            if (p.tMs >= vpXMin) {
                lo = min(lo, p.value); hi = max(hi, p.value)
            }
        }
        if (lo == Double.MAX_VALUE) { lo = fallbackMin; hi = fallbackMax }
        if (abs(hi - lo) < 1e-6) { lo -= 1.0; hi += 1.0 }
        val pad = (hi - lo) * 0.12
        vpYMin = lo - pad; vpYMax = hi + pad
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        scaleDetector.onTouchEvent(event)
        gestureDetector.onTouchEvent(event)
        if (event.action == MotionEvent.ACTION_DOWN) parent?.requestDisallowInterceptTouchEvent(true)
        return true
    }

    private fun plotW() = (width - padL - padR).coerceAtLeast(1f)
    private fun plotH() = (height - padT - padB).coerceAtLeast(1f)

    private fun dataXToPx(t: Double) = padL + ((t - vpXMin) / (vpXMax - vpXMin)).toFloat() * plotW()
    private fun dataYToPy(v: Double) = padT + (1f - ((v - vpYMin) / (vpYMax - vpYMin)).toFloat()) * plotH()
    private fun pxToDataX(px: Float) = vpXMin + (px - padL) / plotW() * (vpXMax - vpXMin)
    private fun pyToDataY(py: Float) = vpYMin + (1f - (py - padT) / plotH()) * (vpYMax - vpYMin)

    override fun onDraw(canvas: Canvas) {
        if (autoMode) computeAutoViewport()

        val left = padL; val top = padT
        val right = width - padR; val bottom = height - padB

        // grid + Y labels
        val yTicks = 5
        for (i in 0..yTicks) {
            val frac = i / yTicks.toFloat()
            val y = top + frac * plotH()
            canvas.drawLine(left, y, right, y, gridPaint)
            val value = vpYMax - frac * (vpYMax - vpYMin)
            canvas.drawText(fmt(value), dp(4f), y + sp(4f), textPaint)
        }
        // X labels (time)
        val xTicks = 4
        for (i in 0..xTicks) {
            val frac = i / xTicks.toFloat()
            val x = left + frac * plotW()
            canvas.drawLine(x, top, x, bottom, gridPaint)
            val t = vpXMin + frac * (vpXMax - vpXMin)
            val label = timeFmt.format(Date(t.toLong()))
            val w = textPaint.measureText(label)
            canvas.drawText(label, (x - w / 2).coerceIn(0f, width - w), height - dp(8f), textPaint)
        }
        canvas.drawLine(left, top, left, bottom, axisPaint)
        canvas.drawLine(left, bottom, right, bottom, axisPaint)

        if (data.isEmpty()) {
            canvas.drawText("waiting for data…", width / 2f, height / 2f, hintPaint)
            return
        }

        // line + fill (only points inside viewport, plus one either side)
        path.reset()
        var started = false
        var firstX = 0f; var lastX = 0f
        for (p in data) {
            val px = dataXToPx(p.tMs.toDouble())
            val py = dataYToPy(p.value)
            if (!started) { path.moveTo(px, py); firstX = px; started = true }
            else path.lineTo(px, py)
            lastX = px
        }
        if (started) {
            // fill under curve
            val fill = Path(path)
            fill.lineTo(lastX, bottom)
            fill.lineTo(firstX, bottom)
            fill.close()
            canvas.save()
            canvas.clipRect(left, top, right, bottom)
            canvas.drawPath(fill, fillPaint)
            canvas.drawPath(path, linePaint)
            canvas.restore()

            // latest value marker + readout
            val lastP = data.last()
            val lx = dataXToPx(lastP.tMs.toDouble())
            val ly = dataYToPy(lastP.value)
            if (lx in left..right && ly in top..bottom) {
                canvas.drawCircle(lx, ly, dp(3.5f), dotPaint)
            }
            val readout = fmt(lastP.value) + (if (unit.isNotEmpty()) " $unit" else "")
            textPaint.textAlign = Paint.Align.RIGHT
            val old = textPaint.textSize
            textPaint.textSize = sp(13f)
            canvas.drawText(readout, right, top + sp(14f), textPaint)
            textPaint.textSize = old
            textPaint.textAlign = Paint.Align.LEFT
        }

        if (!autoMode) {
            hintPaint.textAlign = Paint.Align.LEFT
            canvas.drawText("manual · double-tap to reset", left + dp(4f), top + sp(14f), hintPaint)
            hintPaint.textAlign = Paint.Align.CENTER
        }
    }

    private fun fmt(v: Double): String = String.format(Locale.US, "%.${decimals}f", v)
    private fun dp(v: Float) = v * resources.displayMetrics.density
    private fun sp(v: Float) = v * resources.displayMetrics.scaledDensity
}
