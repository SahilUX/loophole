package dev.loophole.app

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.BitmapFactory
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/** Home-screen widget. The Flutter side draws it (HomeWidgetView) and saves a PNG; this just shows it. */
class RingWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray, data: SharedPreferences) {
        val bitmap = data.getString("widget_image", null)?.let { BitmapFactory.decodeFile(it) }
        for (id in ids) {
            val v = RemoteViews(context.packageName, R.layout.ring_widget).apply {
                if (bitmap != null) setImageViewBitmap(R.id.widget_img, bitmap)
                setOnClickPendingIntent(
                    R.id.widget_root,
                    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
                )
            }
            manager.updateAppWidget(id, v)
        }
    }
}
