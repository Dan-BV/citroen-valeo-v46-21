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
    private lateinit var param: Field

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppState.init(this)
        binding = ActivityGraphBinding.inflate(layoutInflater)
        setContentView(binding.root)

        val key = intent.getStringExtra("key")
        val found = AppState.profile.fields.firstOrNull { it.key == key }
        if (found == null) { finish(); return }
        param = found

        binding.toolbar.title = param.label
        binding.toolbar.subtitle = subtitle(null)
        binding.toolbar.setNavigationOnClickListener { finish() }

        binding.chart.bind(param.unit, param.decimals, param.min, param.max)
        binding.chart.setData(AppState.session.historySnapshot(param.key))

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                AppState.session.values.collect { values ->
                    binding.chart.setData(AppState.session.historySnapshot(param.key))
                    val s = values[param.key]
                    binding.toolbar.subtitle =
                        subtitle(if (s != null && s.valid) s.value else null)
                }
            }
        }
    }

    private fun subtitle(value: Double?): String {
        val where = "\$${param.pageId}"
        return if (value == null) "$where  ·  ${param.unit}"
        else "$where  ·  " +
            String.format(Locale.US, "%.${param.decimals}f %s", value, param.unit)
    }
}
