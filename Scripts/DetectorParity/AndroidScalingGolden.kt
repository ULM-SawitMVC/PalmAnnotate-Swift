package dev.sawitulm.palmannotate.scalinggolden

import android.app.Activity
import android.app.Instrumentation
import android.graphics.Bitmap
import android.os.Bundle

/**
 * Scales synthetic images with the same call the detector uses and prints an FNV-1a 64 hash of the
 * scaled RGB bytes. The images come from a 32-bit LCG, so no field data is involved.
 */
class AndroidScalingGolden : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        try {
            for ((width, height, size) in listOf(Triple(37, 23, 16), Triple(700, 500, 200), Triple(333, 611, 160), Triple(4624, 3468, 640))) {
                var state = (width * 65536 + height).toLong() and 0xFFFFFFFFL
                fun next(): Int {
                    state = (state * 1664525L + 1013904223L) and 0xFFFFFFFFL
                    return (state ushr 24).toInt()
                }
                val pixels = IntArray(width * height) { 0xFF000000.toInt() or (next() shl 16) or (next() shl 8) or next() }
                val original = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
                val scale = minOf(size.toFloat() / width, size.toFloat() / height)
                val newWidth = Math.round(width * scale)
                val newHeight = Math.round(height * scale)
                val scaled = Bitmap.createScaledBitmap(original, newWidth, newHeight, true)
                val out = IntArray(newWidth * newHeight)
                scaled.getPixels(out, 0, newWidth, 0, 0, newWidth, newHeight)
                var hash = -0x340d631b7bdddcdbL // FNV offset basis 0xcbf29ce484222325
                for (p in out) for (shift in intArrayOf(16, 8, 0)) {
                    hash = (hash xor ((p shr shift) and 0xFF).toLong()) * 0x100000001b3L
                }
                sendStatus(0, Bundle().apply {
                    putString("palm", "PALM_SCALE_GOLDEN $width $height $size $newWidth $newHeight ${java.lang.Long.toUnsignedString(hash, 16)}")
                })
            }
            finish(Activity.RESULT_OK, Bundle())
        } catch (error: Throwable) {
            finish(Activity.RESULT_CANCELED, Bundle().apply { putString("error", error.stackTraceToString()) })
        }
    }
}
