package com.example.sync_ro_app.widget

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

data class Memo(
    val id: Long,
    val text: String,
    val type: String,
    val done: Boolean,
    val createdAt: Long
) {
    val isSchedule: Boolean get() = type == TYPE_SCHEDULE

    companion object {
        const val TYPE_TODO = "todo"
        const val TYPE_SCHEDULE = "schedule"
    }
}

/**
 * Flutter의 shared_preferences(legacy)와 같은 XML 파일을 직접 읽고 써요.
 * Flutter 쪽 키 'sync_ro_memos_v1' 은 파일 안에서 'flutter.' 접두사가 붙어요.
 */
object MemoStore {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val STORAGE_KEY = "flutter.sync_ro_memos_v1"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    @Synchronized
    fun load(context: Context): List<Memo> {
        val raw = prefs(context).getString(STORAGE_KEY, null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            val memos = ArrayList<Memo>(array.length())
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val text = item.optString("text", "").trim()
                if (text.isEmpty()) continue
                memos.add(
                    Memo(
                        id = item.optLong("id", 0L),
                        text = text,
                        type = normalizeType(item.optString("type", Memo.TYPE_TODO)),
                        done = item.optBoolean("done", false),
                        createdAt = item.optLong("created_at", 0L)
                    )
                )
            }
            memos
        } catch (_: Exception) {
            emptyList()
        }
    }

    @Synchronized
    fun save(context: Context, memos: List<Memo>) {
        val array = JSONArray()
        memos.forEach { memo ->
            array.put(
                JSONObject()
                    .put("id", memo.id)
                    .put("text", memo.text)
                    .put("type", memo.type)
                    .put("done", memo.done)
                    .put("created_at", memo.createdAt)
            )
        }
        // commit()으로 바로 저장해야 위젯이 새 내용을 읽을 수 있어요.
        prefs(context).edit().putString(STORAGE_KEY, array.toString()).commit()
    }

    fun add(context: Context, text: String, type: String): Memo {
        val now = System.currentTimeMillis()
        val memos = load(context).toMutableList()
        // 같은 밀리초에 두 개를 저장해도 ID가 겹치지 않게 해요.
        val id = maxOf(now, (memos.maxOfOrNull { it.id } ?: 0L) + 1L)
        val memo = Memo(
            id = id,
            text = text,
            type = normalizeType(type),
            done = false,
            createdAt = now
        )
        memos.add(0, memo)
        save(context, memos)
        return memo
    }

    fun find(context: Context, id: Long): Memo? =
        load(context).firstOrNull { it.id == id }

    fun update(context: Context, id: Long, text: String, type: String) {
        val memos = load(context).toMutableList()
        val index = memos.indexOfFirst { it.id == id }
        if (index < 0) return
        memos[index] = memos[index].copy(text = text, type = normalizeType(type))
        save(context, memos)
    }

    fun toggle(context: Context, id: Long) {
        val memos = load(context).toMutableList()
        val index = memos.indexOfFirst { it.id == id }
        if (index < 0) return
        memos[index] = memos[index].copy(done = !memos[index].done)
        save(context, memos)
    }

    fun delete(context: Context, id: Long) {
        save(context, load(context).filterNot { it.id == id })
    }

    fun sorted(memos: List<Memo>): List<Memo> =
        memos.sortedWith(compareBy<Memo>({ it.done }, { -it.createdAt }))

    private fun normalizeType(type: String): String =
        if (type == Memo.TYPE_SCHEDULE) Memo.TYPE_SCHEDULE else Memo.TYPE_TODO
}
