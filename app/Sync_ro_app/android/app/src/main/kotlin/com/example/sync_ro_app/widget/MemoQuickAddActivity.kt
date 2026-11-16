package com.example.sync_ro_app.widget

import android.app.Activity
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.EditText
import android.widget.TextView
import com.example.sync_ro_app.R

/**
 * 위젯에서 + 를 누르거나 메모를 누르면 뜨는 작은 입력 창.
 * Flutter 엔진을 띄우지 않고 네이티브 화면만 써서 빠르게 열려요.
 */
class MemoQuickAddActivity : Activity() {

    private lateinit var input: EditText
    private lateinit var title: TextView
    private lateinit var deleteButton: TextView
    private lateinit var todoChip: TextView
    private lateinit var scheduleChip: TextView

    private var editingId: Long = -1L
    private var type: String = Memo.TYPE_TODO

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_memo_quick_add)

        input = findViewById(R.id.quick_input)
        title = findViewById(R.id.quick_title)
        deleteButton = findViewById(R.id.quick_delete)
        todoChip = findViewById(R.id.quick_type_todo)
        scheduleChip = findViewById(R.id.quick_type_schedule)

        editingId = intent?.getLongExtra(EXTRA_MEMO_ID, -1L) ?: -1L
        if (editingId > 0) {
            val memo = MemoStore.find(this, editingId)
            if (memo != null) {
                input.setText(memo.text)
                input.setSelection(input.text.length)
                type = memo.type
                title.setText(R.string.quick_edit_title)
                deleteButton.visibility = View.VISIBLE
            } else {
                editingId = -1L
            }
        }

        renderType()

        todoChip.setOnClickListener {
            type = Memo.TYPE_TODO
            renderType()
        }
        scheduleChip.setOnClickListener {
            type = Memo.TYPE_SCHEDULE
            renderType()
        }
        findViewById<TextView>(R.id.quick_cancel).setOnClickListener { finish() }
        findViewById<TextView>(R.id.quick_save).setOnClickListener { saveMemo() }
        deleteButton.setOnClickListener { deleteMemo() }

        input.requestFocus()
        window?.setSoftInputMode(
            WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE or
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
        )
    }

    override fun onStart() {
        super.onStart()
        window?.setLayout(
            (resources.displayMetrics.widthPixels * 0.92f).toInt(),
            ViewGroup.LayoutParams.WRAP_CONTENT
        )
    }

    private fun renderType() {
        val selectedBg = R.drawable.quick_type_selected_bg
        val normalBg = R.drawable.quick_type_unselected_bg
        val todoSelected = type == Memo.TYPE_TODO

        todoChip.setBackgroundResource(if (todoSelected) selectedBg else normalBg)
        scheduleChip.setBackgroundResource(if (todoSelected) normalBg else selectedBg)
        todoChip.setTextColor(
            widgetColor(
                this,
                if (todoSelected) R.color.widget_primary else R.color.widget_text_muted
            )
        )
        scheduleChip.setTextColor(
            widgetColor(
                this,
                if (todoSelected) R.color.widget_text_muted else R.color.widget_primary
            )
        )
    }

    private fun saveMemo() {
        val text = input.text.toString().trim()
        if (text.isEmpty()) {
            input.error = getString(R.string.quick_add_empty)
            return
        }
        if (editingId > 0) {
            MemoStore.update(this, editingId, text, type)
        } else {
            MemoStore.add(this, text, type)
        }
        MemoWidgetProvider.refreshAll(this)
        setResult(RESULT_OK)
        finish()
    }

    private fun deleteMemo() {
        if (editingId > 0) {
            MemoStore.delete(this, editingId)
            MemoWidgetProvider.refreshAll(this)
            setResult(RESULT_OK)
        }
        finish()
    }

    companion object {
        const val EXTRA_MEMO_ID = "memo_id"
    }
}
