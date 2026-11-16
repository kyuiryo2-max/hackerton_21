package com.example.sync_ro_app.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.RemoteViews
import com.example.sync_ro_app.MainActivity
import com.example.sync_ro_app.R

class MemoWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        appWidgetIds.forEach { appWidgetId ->
            updateWidget(context, appWidgetManager, appWidgetId)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_CLICK) {
            val id = intent.getLongExtra(EXTRA_ID, -1L)
            if (id > 0) {
                when (intent.getStringExtra(EXTRA_OP)) {
                    OP_TOGGLE -> MemoStore.toggle(context, id)
                    OP_DELETE -> MemoStore.delete(context, id)
                }
                refreshAll(context)
            }
            return
        }
        super.onReceive(context, intent)
    }

    companion object {
        const val ACTION_CLICK = "com.example.sync_ro_app.widget.CLICK"
        const val EXTRA_ID = "memo_id"
        const val EXTRA_OP = "memo_op"
        const val OP_TOGGLE = "toggle"
        const val OP_DELETE = "delete"
        const val EXTRA_OPEN_TAB = "open_tab"
        const val MEMO_TAB_INDEX = 3

        private fun pendingFlags(): Int =
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE
                } else {
                    0
                }

        /**
         * ListView 템플릿은 행마다 fill-in extra(메모 id)를 채워 넣어야 해서
         * Android 12+ 에서 FLAG_MUTABLE 이 필요해요.
         */
        private fun templateFlags(): Int =
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_MUTABLE
                } else {
                    0
                }

        /** 앱에서 메모를 저장했을 때, 또는 위젯에서 체크·삭제했을 때 다시 그려요. */
        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, MemoWidgetProvider::class.java)
            )
            if (ids.isEmpty()) return
            ids.forEach { appWidgetId ->
                updateWidget(context, manager, appWidgetId)
            }
            manager.notifyAppWidgetViewDataChanged(ids, R.id.widget_memo_list)
        }

        fun updateWidget(
            context: Context,
            manager: AppWidgetManager,
            appWidgetId: Int
        ) {
            val memos = MemoStore.load(context)
            val views = RemoteViews(context.packageName, R.layout.widget_memo)

            val todoCount = memos.count { !it.done && !it.isSchedule }
            val scheduleCount = memos.count { !it.done && it.isSchedule }
            val countText = when {
                memos.isEmpty() -> context.getString(R.string.widget_memo_count_empty)
                todoCount + scheduleCount == 0 ->
                    context.getString(R.string.widget_memo_count_done)
                else -> context.getString(R.string.widget_memo_count, todoCount, scheduleCount)
            }
            views.setTextViewText(R.id.widget_count, countText)

            val serviceIntent = Intent(context, MemoWidgetService::class.java).apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            }
            views.setRemoteAdapter(R.id.widget_memo_list, serviceIntent)
            views.setEmptyView(R.id.widget_memo_list, R.id.widget_empty)

            // 메모를 누르면 그 자리에서 고칠 수 있게 작은 입력 창을 열어요.
            // (ListView는 템플릿 하나 + 행마다 fill-in extra를 쓰는 방식)
            val editIntent = Intent(context, MemoQuickAddActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            views.setPendingIntentTemplate(
                R.id.widget_memo_list,
                PendingIntent.getActivity(context, appWidgetId + 10, editIntent, templateFlags())
            )

            // + : 새 메모
            val addIntent = Intent(context, MemoQuickAddActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            views.setOnClickPendingIntent(
                R.id.widget_add,
                PendingIntent.getActivity(context, appWidgetId, addIntent, pendingFlags())
            )

            // 하단 입력줄: AI가 일정/할일을 판단하는 빠른 메모 화면을 열어요.
            val quickCaptureIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(MainActivity.EXTRA_OPEN_TAB, MEMO_TAB_INDEX)
                putExtra(MainActivity.EXTRA_QUICK_CAPTURE, true)
            }
            views.setOnClickPendingIntent(
                R.id.widget_capture,
                PendingIntent.getActivity(
                    context,
                    appWidgetId + 30,
                    quickCaptureIntent,
                    pendingFlags()
                )
            )

            // 제목을 누르면 앱의 메모 탭이 열려요.
            val openAppIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(MainActivity.EXTRA_OPEN_TAB, MEMO_TAB_INDEX)
            }
            views.setOnClickPendingIntent(
                R.id.widget_header,
                PendingIntent.getActivity(context, appWidgetId + 20, openAppIntent, pendingFlags())
            )

            manager.updateAppWidget(appWidgetId, views)
        }

        /** 체크·삭제 버튼용. 메모 id마다 다른 requestCode를 써요. */
        fun actionPendingIntent(context: Context, memoId: Long, op: String): PendingIntent {
            val intent = Intent(context, MemoWidgetProvider::class.java).apply {
                action = ACTION_CLICK
                putExtra(EXTRA_ID, memoId)
                putExtra(EXTRA_OP, op)
            }
            // 메모 id의 하위 29비트와 동작 비트를 합쳐 requestCode를 만들어요.
            val opIndex = if (op == OP_DELETE) 1 else 0
            val requestCode = (((memoId and 0x1FFFFFFFL) * 2 + opIndex).toInt())
            return PendingIntent.getBroadcast(context, requestCode, intent, pendingFlags())
        }
    }
}
