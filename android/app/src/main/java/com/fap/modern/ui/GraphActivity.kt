package com.fap.modern.ui

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.fap.modern.core.AppState
import com.fap.modern.core.Field
import com.fap.modern.databinding.ActivityGraphBinding
import kotlinx.coroutines.launch
import java.util.Locale

class GraphActivity : AppCompatActivity() {

    private lateinit var binding: ActivityGraphBinding
    private lateinit var field: Field

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppState.init(this)
        binding = ActivityGraphBinding.inflate(layoutInflater)
        setContentView(binding.root)

        val key = intent.getStringExtra("key")
        val found = AppState.profile.fields.firstOrNull { it.key == key }
        if (found == null) { finish(); return }
        field = found

        binding.toolbar.title = field.label
        binding.toolbar.subtitle = subtitle(null)
        binding.toolbar.setNavigationOnClickListener { finish() }

        binding.chart.bind(field.unit, field.decimals, field.min, field.max)
        binding.chart.setData(AppState.session.historySnapshot(field.key))

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                AppState.session.values.collect { values ->
                    binding.chart.setData(AppState.session.historySnapshot(field.key))
                    val s = values[field.key]
                    binding.toolbar.subtitle =
                        subtitle(if (s != null && s.valid) s.value else null)
                }
            }
        }
    }

    private fun subtitle(value: Double?): String {
        val where = "\$${field.pageId}"
        return if (value == null) "$where  ·  ${field.unit}"
        else "$where  ·  " +
            String.format(Locale.US, "%.${field.decimals}f %s", value, field.unit)
    }
}
