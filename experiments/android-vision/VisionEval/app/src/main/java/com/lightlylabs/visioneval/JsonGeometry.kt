package com.lightlylabs.visioneval

import android.graphics.PointF
import android.graphics.Rect
import android.graphics.RectF
import org.json.JSONArray
import kotlin.math.roundToInt

/** Helpers that convert SDK geometry into normalised JSON (4 decimals is ~0.2 px at 2048 px). */
object JsonGeometry {
    private fun round4(value: Float): Double = (value * 10000f).roundToInt() / 10000.0

    fun normalisedBox(rect: Rect, imageWidth: Int, imageHeight: Int): JSONArray = JSONArray()
        .put(round4(rect.left.toFloat() / imageWidth)).put(round4(rect.top.toFloat() / imageHeight))
        .put(round4(rect.width().toFloat() / imageWidth)).put(round4(rect.height().toFloat() / imageHeight))

    fun normalisedBox(rect: RectF, imageWidth: Int, imageHeight: Int): JSONArray = JSONArray()
        .put(round4(rect.left / imageWidth)).put(round4(rect.top / imageHeight))
        .put(round4(rect.width() / imageWidth)).put(round4(rect.height() / imageHeight))

    /** For APIs that already return normalised boxes (MediaPipe interactive results etc.). */
    fun box(left: Float, top: Float, width: Float, height: Float): JSONArray =
        JSONArray().put(round4(left)).put(round4(top)).put(round4(width)).put(round4(height))

    fun normalisedPoint(point: PointF, imageWidth: Int, imageHeight: Int): JSONArray =
        JSONArray().put(round4(point.x / imageWidth)).put(round4(point.y / imageHeight))

    fun point(x: Float, y: Float): JSONArray = JSONArray().put(round4(x)).put(round4(y))

    fun point3(x: Float, y: Float, z: Float): JSONArray = JSONArray().put(round4(x)).put(round4(y)).put(round4(z))
}
