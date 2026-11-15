package com.example.sync_ro_app.widget

import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import com.example.sync_ro_app.R

class MemoWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        MemoWidgetFactory(applicationContext)
}

private class MemoWidgetFactory(private val context: Context) :
    RemoteViewsService.RemoteViewsFactory {

    private var memos: List<Memo> = emptyList()

    override fun onCreate() = Unit

    override fun onDataSetChanged() {
        memos = MemoStore.sorted(MemoStore.load(context))
    }

    override fun onDestroy() {
        memos = emptyList()
    }

    override fun getCount(): Int = memos.size

    override fun getViewAt(position: Int): RemoteViews? {
        val memo = memos.getOrNull(position) ?: return null
        val views = RemoteViews(context.packageName, R.layout.widget_memo_item)

        // 같은 자리에 놓인 두 태그 중 하나만 보이게 해서 색을 바꿔요.
        views.setViewVisibility(
            R.id.item_tag_todo,
            if (memo.isSchedule) View.GONE else View.VISIBLE
        )
        views.setViewVisibility(
            R.id.item_tag_schedule,
            if (memo.isSchedule) View.VISIBLE else View.GONE
        )

        views.setTextViewText(R.id.item_text, memo.text)
        views.setTextColor(
            R.id.item_text,
            widgetColor(
                context,
                if (memo.done) R.color.widget_text_muted else R.color.widget_text_strong
            )
        )
        views.setImageViewResource(
            R.id.item_check,
            if (memo.done) R.drawable.ic_widget_check else R.drawable.ic_widget_uncheck
        )

        // 행 전체를 누르면 수정 창이 열려요 (ListView 템플릿 + 이 메모 id).
        views.setOnClickFillInIntent(
            R.id.item_root,
            Intent().putExtra(MemoQuickAddActivity.EXTRA_MEMO_ID, memo.id)
        )
        // 완료·삭제는 각각의 작은 버튼이 직접 처리해요.
        views.setOnClickPendingIntent(
            R.id.item_check,
            MemoWidgetProvider.actionPendingIntent(
                context,
                memo.id,
                MemoWidgetProvider.OP_TOGGLE
            )
        )
        views.setOnClickPendingIntent(
            R.id.item_delete,
            MemoWidgetProvider.actionPendingIntent(
                context,
                memo.id,
                MemoWidgetProvider.OP_DELETE
            )
        )
        return views
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long = memos[position].id

    override fun hasStableIds(): Boolean = true
}
