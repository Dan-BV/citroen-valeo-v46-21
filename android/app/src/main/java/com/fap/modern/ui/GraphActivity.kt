package com.fap.modern.ui

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.fap.modern.core.AppState
import com.fap.modern.core.ParamDef
import com.fap.modern.core.V4621Profile
import com.fap.modern.databinding.ActivityGraphBinding
import kotlinx.coroutines.launch
import java.util.Locale

class GraphActivity : AppCompatActivity() {

    private lateinit var binding: ActivityGraphBinding
    private lateinit var def: ParamDef

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppState.init(this)
        binding = ActivityGraphBinding.inflate(layoutInflater)
        setContentView(binding.root)

        val key = intent.getStringExtra("key")
        val found = key?.let { V4621Profile.byKey(it) }
        if (found == null) { finish(); return }
        def = found

        binding.toolbar.title = def.label
        binding.toolbar.subtitle = "${def.page}  ·  ${def.unit}"
        binding.toolbar.setNavigationOnClickListener { finish() }

        if (def.desc.isNotBlank()) {
            binding.desc.text = def.desc
            binding.desc.visibility = android.view.View.VISIBLE
        }

        binding.chart.bind(def.unit, def.decimals, def.min, def.max)
        binding.chart.setData(session().historySnapshot(def.key))

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                session().values.collect { values ->
                    binding.chart.setData(session().historySnapshot(def.key))
                    val s = values[def.key]
                    binding.toolbar.subtitle = if (s != null && s.valid)
                        "${def.page}  ·  " + String.format(Locale.US, "%.${def.decimals}f %s", s.value, def.unit)
                    else "${def.page}  ·  ${def.unit}"
                }
            }
        }
    }

    private fun session() = AppState.session
}
