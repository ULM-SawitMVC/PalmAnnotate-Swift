package dev.sawitulm.palmannotate.data.detection

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.runBlocking

object DetectorProbe {
    val confidences = mutableListOf<Float>()

    fun run(context: Context, emit: (String) -> Unit) {
        val detector = OnnxDetector(context)
        try {
            val photos = context.assets.list("photos").orEmpty().sorted()
            check(photos.isNotEmpty())
            for (name in photos) {
                val photo = context.cacheDir.resolve(name)
                context.assets.open("photos/$name").use { input ->
                    photo.outputStream().use { input.copyTo(it) }
                }
                confidences.clear()
                val boxes = try {
                    runBlocking { detector.detect(Uri.fromFile(photo)) }
                } finally {
                    photo.delete()
                }
                check(boxes.size == confidences.size)
                emit("PALM_DETECT_BEGIN $name")
                for ((i, box) in boxes.withIndex()) {
                    emit("PALM_DETECT_BOX " + listOf(
                        box.id, box.classId, confidences[i], box.x1, box.y1, box.x2, box.y2,
                    ).joinToString(","))
                }
                emit("PALM_DETECT_END")
            }
        } finally {
            detector.close()
        }
    }
}
