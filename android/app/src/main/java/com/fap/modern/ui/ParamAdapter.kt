package com.fap.modern.ui

import android.graphics.PorterDuff
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.RecyclerView
import com.fap.modern.R
import com.fap.modern.core.ParamDef
import com.fap.modern.core.Sample
import com.fap.modern.core.ValueKind
import java.util.Locale

class ParamAdapter(
    private val params: List<ParamDef>,
    private val onClick: (ParamDef) -> Unit,
) : RecyclerView.Adapter<ParamAdapter.VH>() {

    private var values: Map<String, Sample> = emptyMap()

    fun submit(newValues: Map<String, Sample>) {
        values = newValues
        notifyItemRangeChanged(0, params.size, PAYLOAD)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val v = LayoutInflater.from(parent.context).inflate(R.layout.item_param, parent, false)
        return VH(v)
    }

    override fun getItemCount() = params.size

    override fun onBindViewHolder(holder: VH, position: Int) {
        val def = params[position]
        holder.label.text = def.label
        holder.key.text = "${def.key} • ${def.page}"
        holder.itemView.setOnClickListener {
            if (def.kind == ValueKind.NUMERIC) onClick(def)
        }
        bindValue(holder, def)
    }

    override fun onBindViewHolder(holder: VH, position: Int, payloads: MutableList<Any>) {
        if (payloads.contains(PAYLOAD)) bindValue(holder, params[position])
        else onBindViewHolder(holder, position)
    }

    private fun bindValue(holder: VH, def: ParamDef) {
        val s = values[def.key]
        val ctx = holder.itemView.context
        if (def.kind == ValueKind.BOOLEAN) {
            holder.chevron.visibility = View.GONE
            holder.boolDot.visibility = View.VISIBLE
            holder.unit.text = ""
            val on = s != null && s.valid && s.value >= 0.5
            holder.value.text = if (s == null || !s.valid) "--" else if (on) "ON" else "OFF"
            val color = ContextCompat.getColor(ctx, if (on) R.color.bool_on else R.color.bool_off)
            // mutate() so each row's dot keeps its own colour (drawables share constant state)
            holder.boolDot.background?.mutate()?.setColorFilter(color, PorterDuff.Mode.SRC_IN)
            holder.value.setTextColor(ContextCompat.getColor(ctx, R.color.on_surface))
        } else {
            holder.chevron.visibility = View.VISIBLE
            holder.boolDot.visibility = View.GONE
            holder.unit.text = def.unit
            holder.value.text = if (s == null || !s.valid) "--"
            else String.format(Locale.US, "%.${def.decimals}f", s.value)
            holder.value.setTextColor(ContextCompat.getColor(ctx, R.color.primary))
        }
    }

    class VH(v: View) : RecyclerView.ViewHolder(v) {
        val label: TextView = v.findViewById(R.id.label)
        val key: TextView = v.findViewById(R.id.key)
        val value: TextView = v.findViewById(R.id.value)
        val unit: TextView = v.findViewById(R.id.unit)
        val boolDot: View = v.findViewById(R.id.boolDot)
        val chevron: TextView = v.findViewById(R.id.chevron)
    }

    companion object {
        private val PAYLOAD = Any()
    }
}
