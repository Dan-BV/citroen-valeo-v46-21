package com.fap.modern.ui

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.RecyclerView
import com.fap.modern.R
import com.fap.modern.core.Field
import com.fap.modern.core.Page
import com.fap.modern.core.Sample
import com.fap.modern.core.ValueKind
import java.util.Locale

/** A page heading or one parameter, in the order the ECU groups them. */
sealed interface Row {
    data class Header(val page: Page) : Row
    data class Param(val field: Field, val page: Page) : Row
}

class ParamAdapter(
    private val rows: List<Row>,
    private val onParam: (Field) -> Unit,
    private val onHeader: (Page) -> Unit,
) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {

    private var values: Map<String, Sample> = emptyMap()
    private var dead: Set<String> = emptySet()

    fun submit(newValues: Map<String, Sample>) {
        values = newValues
        notifyItemRangeChanged(0, rows.size, PAYLOAD)
    }

    /** Pages the ECU never answered, greyed out with a note. */
    fun submitDead(deadRequests: Set<String>) {
        dead = deadRequests
        notifyItemRangeChanged(0, rows.size)
    }

    override fun getItemCount() = rows.size

    override fun getItemViewType(position: Int) =
        if (rows[position] is Row.Header) TYPE_HEADER else TYPE_PARAM

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
        val inflater = LayoutInflater.from(parent.context)
        return if (viewType == TYPE_HEADER) {
            HeaderVH(inflater.inflate(R.layout.item_group, parent, false))
        } else {
            ParamVH(inflater.inflate(R.layout.item_param, parent, false))
        }
    }

    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
        when (val row = rows[position]) {
            is Row.Header -> bindHeader(holder as HeaderVH, row.page)
            is Row.Param -> {
                val h = holder as ParamVH
                h.label.text = row.field.label
                h.key.text = "\$${row.page.id} · b${row.field.offset + 1}"
                h.itemView.setOnClickListener {
                    if (row.field.kind == ValueKind.NUMERIC) onParam(row.field)
                }
                bindValue(h, row.field)
            }
        }
    }

    override fun onBindViewHolder(
        holder: RecyclerView.ViewHolder,
        position: Int,
        payloads: MutableList<Any>,
    ) {
        val row = rows[position]
        if (payloads.contains(PAYLOAD) && row is Row.Param) bindValue(holder as ParamVH, row.field)
        else onBindViewHolder(holder, position)
    }

    private fun bindHeader(h: HeaderVH, page: Page) {
        val silent = dead.contains(page.request)
        h.title.text = page.title
        h.page.text = "\$${page.id}" + if (silent) " · нет ответа" else ""
        h.itemView.alpha = if (silent) 0.5f else 1f
        h.itemView.setOnClickListener { onHeader(page) }
    }

    private fun bindValue(h: ParamVH, f: Field) {
        val s = values[f.key]
        val ctx = h.itemView.context
        if (f.kind == ValueKind.ENUM) {
            h.chevron.visibility = View.GONE
            h.boolDot.visibility = View.GONE
            h.unit.text = ""
            h.value.text = if (s == null || !s.valid) "--" else f.stateText(s.raw)
            h.value.textSize = 14f
            h.value.setTextColor(ContextCompat.getColor(ctx, R.color.on_surface))
        } else {
            h.chevron.visibility = View.VISIBLE
            h.boolDot.visibility = View.GONE
            h.unit.text = f.unit
            h.value.textSize = 22f
            h.value.text = if (s == null || !s.valid) "--"
            else String.format(Locale.US, "%.${f.decimals}f", s.value)
            h.value.setTextColor(ContextCompat.getColor(ctx, R.color.primary))
        }
    }

    class ParamVH(v: View) : RecyclerView.ViewHolder(v) {
        val label: TextView = v.findViewById(R.id.label)
        val key: TextView = v.findViewById(R.id.key)
        val value: TextView = v.findViewById(R.id.value)
        val unit: TextView = v.findViewById(R.id.unit)
        val boolDot: View = v.findViewById(R.id.boolDot)
        val chevron: TextView = v.findViewById(R.id.chevron)
    }

    class HeaderVH(v: View) : RecyclerView.ViewHolder(v) {
        val title: TextView = v.findViewById(R.id.groupTitle)
        val page: TextView = v.findViewById(R.id.groupPage)
    }

    companion object {
        private const val TYPE_HEADER = 0
        private const val TYPE_PARAM = 1
        private val PAYLOAD = Any()

        /** Flattens the profile into headings followed by their parameters. */
        fun rowsOf(pages: List<Page>): List<Row> = buildList {
            for (page in pages) {
                if (page.fields.isEmpty()) continue
                add(Row.Header(page))
                for (f in page.fields) add(Row.Param(f, page))
            }
        }
    }
}
