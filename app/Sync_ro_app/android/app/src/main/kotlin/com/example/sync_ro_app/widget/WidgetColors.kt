package com.example.sync_ro_app.widget

import android.content.Context
import android.os.Build

/**
 * ContextCompat 없이 API 21부터 같은 색을 읽어요.
 * 위젯과 입력 창이 AndroidX 의존성을 따로 추가하지 않아도 되게 하려고요.
 */
@Suppress("DEPRECATION")
internal fun widgetColor(context: Context, colorRes: Int): Int =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
        context.getColor(colorRes)
    } else {
        context.resources.getColor(colorRes)
    }
